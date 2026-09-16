//
//  EnsembleUncertaintyCard.swift
//  ZhishengWeather（主 App target）
//
//  主屏「集合预报」不确定性区块（本特性核心 UI）：把「降水概率」还原为**集合证据**
//  ——「N 个成员中 M 个认为有雨」+ 成员分歧（离散度），而非一个裸百分比。
//
//  诚实边界（数据纪律）：
//   - 明确标注为**集合预报（多成员概率）**，且**非实况观测**；
//   - 成员数 N **来自数据**（`evidence.memberCount`），**绝不硬编码 30**（随模式 1/30/40/50…）；
//   - 无可用集合（`evidence == nil`）→ 由 ContentView 整块不渲染，不留空槽。
//
//  视觉（两把独立标尺，注释写明以免误读）：
//   - 左条（青）：某小时**成员中有雨的比例**（0…1 → 0…maxBarHeight）。
//   - 右条（绿）：某小时**成员分歧幅度**（降水 p25…p75 的跨度，mm），按窗口内最大 p75
//     归一化到 0…maxBarHeight —— **与左条不同尺度**，故分开并列、不叠放。
//
//  注：布局常量用 `private static let`（**静态**属性不参与合成逐成员初始化器，
//  故不降低 `init(evidence:timeZone:)` 的可见性）。
//
//  @MainActor：与项目内其他 View 一致（SwiftUI 仅对 body 推断主 actor；且时间渲染经
//  @MainActor 的 `WeatherTimeFormatter`）。
//

import SwiftUI

/// 主屏集合预报不确定性卡。
@MainActor
struct EnsembleUncertaintyCard: View {

    /// 集合证据（逐小时 + 窗口聚合）。由 `EnsembleProbabilityEngine` 纯函数推导。
    let evidence: EnsembleEvidence
    /// 时间渲染时区（D-4：透传选中城市时区；缺省设备时区）。
    var timeZone: TimeZone = .current

    /// 条形区最大高度（pt）。
    private static let maxBarHeight: CGFloat = 56
    /// 最多展示的小时数（横向可滚动，超出部分裁掉）。
    private static let displayedHours = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(headlineText)
                .font(.system(size: Theme.FontSize.metric, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            strip
            Text("左条＝成员中有雨比例；右条＝成员分歧（p25–p75 幅度）")
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.secondaryText)
            if let peak = evidence.peakHour {
                Text(peakText(peak))
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(footnoteText)
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 子视图

    /// 标题行：区块名 + 「非实况观测」徽标。
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("集合预报")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 8)
            Text("多成员概率 · 非实况观测")
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    /// 逐小时条（横向可滚动，避免窄屏溢出）。
    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(displayed.enumerated()), id: \.offset) { index, hour in
                    column(hour, index: index)
                }
            }
            .frame(height: Self.maxBarHeight + 16, alignment: .bottom)
            .padding(.horizontal, 2)
        }
    }

    /// 单小时列：左（成员比例）+ 右（分歧幅度）+ 小时标签（每 6 小时一格）。
    private func column(_ hour: EnsembleHourEvidence, index: Int) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                bar(width: 7,
                    color: Theme.accentSecondary,
                    height: fractionHeight(hour))
                bar(width: 3,
                    color: Theme.accent,
                    height: spreadHeight(hour))
            }
            .frame(height: Self.maxBarHeight, alignment: .bottom)

            Text(hourLabel(hour.time, index: index))
                .font(.system(size: 9))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .frame(width: 14)
        }
    }

    /// 单根柱：底槽 + 实心填充（底部对齐）。
    private func bar(width: CGFloat, color: Color, height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Capsule()
                .fill(Theme.divider.opacity(0.30))
                .frame(width: width, height: Self.maxBarHeight)
            Capsule()
                .fill(color)
                .frame(width: width, height: height)
        }
        .frame(width: width, height: Self.maxBarHeight, alignment: .bottom)
    }

    // MARK: - 派生

    /// 实际展示的小时（最多 `displayedHours`）。
    private var displayed: [EnsembleHourEvidence] {
        Array(evidence.hourly.prefix(Self.displayedHours))
    }

    /// 窗口内最大 p75（用于把分歧幅度归一化到同一尺度）；无数据 → 0。
    private var windowMaxP75: Double {
        displayed.map { $0.p75 }.max() ?? 0
    }

    /// 成员比例条高度：fraction(0…1) → 0…maxBarHeight（保底 2pt 以示存在）。
    private func fractionHeight(_ hour: EnsembleHourEvidence) -> CGFloat {
        max(2, Self.maxBarHeight * CGFloat(hour.fraction))
    }

    /// 分歧幅度条高度：降水 p25…p75 跨度 / 窗口最大 p75 → 0…maxBarHeight。
    private func spreadHeight(_ hour: EnsembleHourEvidence) -> CGFloat {
        guard windowMaxP75 > 0 else { return 2 }
        let ratio = (hour.p75 - hour.p25) / windowMaxP75
        return max(2, Self.maxBarHeight * CGFloat(ratio))
    }

    /// 小时标签：每 6 小时显示一次（"0"/"6"/"12"/"18"），其余留空以保持紧凑。
    /// 时刻按传入时区渲染（D-4）。
    private func hourLabel(_ date: Date, index: Int) -> String {
        guard index % 6 == 0 else { return "" }
        return WeatherTimeFormatter.string(from: date, format: "H", timeZone: timeZone)
    }

    // MARK: - 文案

    /// 标题句（「N 个成员中 M 个认为…」；N 来自数据）。
    private var headlineText: String {
        let days = max(1, evidence.hourly.count / 24)
        return "\(evidence.memberCount) 个集合成员中 \(evidence.wetMemberCount) 个认为未来 \(days) 天内有降水"
    }

    /// 峰值时段明细：比例最高时段的成员比例 + 降水离散度（p25–p75）。
    private func peakText(_ peak: EnsembleHourEvidence) -> String {
        let time = WeatherTimeFormatter.string(from: peak.time, format: "M月d日 H时", timeZone: timeZone)
        let low = String(format: "%.1f", peak.p25)
        let high = String(format: "%.1f", peak.p75)
        return "最可能时段 \(time)：\(peak.wetCount)/\(peak.memberCount) 成员，"
            + "降水 p25–p75 \(low)–\(high) mm"
    }

    /// 脚注：阈值 + 「集合预报（非观测）」定性。
    private var footnoteText: String {
        let threshold = String(format: "%.1f", evidence.threshold)
        return "阈值 ≥ \(threshold) mm/h · 集合预报（非观测）"
    }
}

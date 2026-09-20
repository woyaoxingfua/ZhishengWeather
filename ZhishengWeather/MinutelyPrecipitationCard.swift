//
//  MinutelyPrecipitationCard.swift
//  ZhishengWeather（主 App target）
//
//  B1-2 短时降水卡：未来约 2 小时的 15 分钟粒度降水柱状序列 + 开始/停止时序 + 峰值。
//
//  纪律：
//  - **粒度诚实**（AC-B1-7，事实更正·已实测验证）：中国等非原生覆盖区的 minutely_15
//    为**逐小时插值到 15 分钟网格**，**非实况外推**。文案须显式标注
//    「未来 2 小时 · 15 分钟粒度 · 由逐小时插值，非实况外推」，**禁止**任何
//    "逐分钟 / 分钟级 / 雷达临近 / nowcast"措辞；不夸大精度。
//    ⚠️ 数组长度**无法**区分原生与插值（柏林与杭州同为 96 条），绝不可据此推断质量。
//  - **干窗 / 无数据整卡隐藏**（AC-B1-8/B1-9）：隐藏判定由调用方经
//    `MinutelyPrecipitationEngine.hasPrecipitation` 完成，本视图假定调用时确有降水，
//    但仍在 `body` 内做一次防御性校验（干窗 → EmptyView），避免误用。
//  - 时刻按**选中城市时区**渲染（D-4 一致，复用 `WeatherTimeFormatter` 的格式器缓存）。
//  - 无新网络请求：数据来自既有单次 forecast 请求（B1-2）。
//
//  P2 修订（AC-A4 / AC-A5）：补渲染**逐柱降水概率**（`MinutelyPrecipitationPoint.probability`
//  此前取到却全屏无落点）：
//   - 有值 → 该柱下方显示 `X%`；
//   - nil（服务端未返回 / 元素 null / 旧载荷）→ 该柱**不标概率**，**绝不显示 0%**
//     冒充"无雨可能"（`0%` 是合法读数，与 nil 必须区分）；
//   - 全部概率皆 nil → 该行整行不渲染（不留空槽）；
//   - AC-B1-7 的**粒度诚实文案原样保留**（「15 分钟粒度 · 由逐小时插值，非实况外推」）——
//     这是事实性标注，不得删改或弱化。
//

import SwiftUI

/// 短时降水卡（@MainActor：辅助成员需主 actor 隔离才能合法调用 `WeatherTimeFormatter`）。
@MainActor
struct MinutelyPrecipitationCard: View {

    /// 短时降水序列（已按"当前 15 分钟窗起 ≤ 2 小时"截窗）。
    let points: [MinutelyPrecipitationPoint]
    /// 时刻渲染时区（D-4）。默认设备时区；由 ContentView 透传 `viewModel.selectedTimeZone`。
    var timeZone: TimeZone = .current

    /// 柱状区高度（pt）。
    private let barAreaHeight: CGFloat = 40

    @ViewBuilder
    var body: some View {
        // 防御性：干窗 → 整卡不渲染（正常路径已由调用方拦截）。
        if MinutelyPrecipitationEngine.hasPrecipitation(points) {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            bars
            probabilityRow
            axis
            footer
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(Theme.divider, lineWidth: 0.5)
        )
    }

    // MARK: - 标题（粒度诚实标注）

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "cloud.rain.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accentSecondary)
                Text("短时降水")
                    .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
            }
            // AC-B1-7（事实更正·已实测验证）：中国等非原生覆盖区的 minutely_15 为
            // **逐小时插值到 15 分钟网格**，**非实况外推 / nowcast**。
            // 文案必须明示来源与免责，**禁止**「分钟级」措辞；
            // ⚠️ 数组长度无法区分原生/插值，绝不可据此推断数据质量。
            Text("未来 2 小时 · 15 分钟粒度 · 由逐小时插值，非实况外推")
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    // MARK: - 柱状序列

    private var bars: some View {
        let peak = barScalePeak
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(points) { point in
                bar(for: point, peak: peak)
            }
        }
        .frame(height: barAreaHeight, alignment: .bottom)
    }

    /// 单柱：高度按峰值归一到 [0, barAreaHeight]；有降水至少 6pt 保证可见，干窗留 2pt 基线。
    private func bar(for point: MinutelyPrecipitationPoint, peak: Double) -> some View {
        let isWet = point.precipitation > MinutelyPrecipitationEngine.precipitationThreshold
        let ratio = min(max(point.precipitation / peak, 0), 1)
        let height = isWet ? max(barAreaHeight * CGFloat(ratio), 6) : 2
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isWet ? Theme.accentSecondary : Theme.divider)
                .frame(height: height)
        }
        .frame(maxWidth: .infinity)
        .frame(height: barAreaHeight, alignment: .bottom)
    }

    /// 归一化基准峰值（下限取阈值，避免除零 / 比例爆炸）。
    private var barScalePeak: Double {
        max(MinutelyPrecipitationEngine.peakPrecipitation(points) ?? 0,
            MinutelyPrecipitationEngine.precipitationThreshold)
    }

    // MARK: - 逐柱降水概率（AC-A4 / AC-A5）

    /// 每根柱下方的「概率 X%」（AC-A4）。
    ///
    /// 落点选择（AC-A4 允许"每根柱下方**或**峰值行"）：本卡窗口固定 8×15min
    /// （`OpenMeteoMapper.maxMinutelyCount`），375pt 窄屏下单槽约 36pt，
    /// 字号 9 的 `100%` 约占 22pt —— 一行放得下，故取"每根柱下方"，
    /// 不做峰值行单点标注（那会丢掉逐柱的概率轮廓）。
    ///
    /// 与柱状区 / 时间轴共用同一套等宽槽位，故三行天然对齐。
    /// 全部概率皆 nil → 整行不渲染（不留空槽）。
    @ViewBuilder
    private var probabilityRow: some View {
        if points.contains(where: { $0.probability != nil }) {
            HStack(spacing: 6) {
                ForEach(points) { point in
                    Text(Self.probabilityLabel(point.probability))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// 概率文案（AC-A5）。
    ///
    /// - nil（服务端未返回 / 元素 null）→ 空串：**该柱不标概率**，绝不冒充 `0%`；
    /// - `0` → `0%`：`0%` 是合法读数，必须与 nil 区分（两者都显示 0% 就是把"未知"说成"确定无雨"）。
    ///
    /// `nonisolated`：纯格式化、无共享状态，脱离类型级 `@MainActor` 以便直接单测
    /// （沿用 `WeatherTimeFormatter.resolveTimeZone` 的既有做法）。
    nonisolated static func probabilityLabel(_ probability: Double?) -> String {
        guard let probability else { return "" }
        return "\(Int(probability.rounded()))%"
    }

    // MARK: - 时间刻度（每 30 分钟一个，即隔点标注）

    private var axis: some View {
        HStack(spacing: 6) {
            ForEach(Array(points.enumerated()), id: \.element.id) { item in
                Text(axisLabel(index: item.offset, point: item.element))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func axisLabel(index: Int, point: MinutelyPrecipitationPoint) -> String {
        guard index % 2 == 0 else { return "" }
        if index == 0 { return "现在" }
        return timeText(point.time)
    }

    // MARK: - 页脚（开始/停止时序 + 峰值）

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let timingText {
                Text(timingText)
                    .font(.system(size: Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            if let peak = MinutelyPrecipitationEngine.peakPrecipitation(points),
               peak > MinutelyPrecipitationEngine.precipitationThreshold {
                Text("峰值约 \(String(format: "%.1f", peak)) mm/15min")
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    /// 「正在下雨，约 HH:mm 前后转小或停止」等；无法派生 → nil（该行隐藏）。
    private var timingText: String? {
        guard let timing = MinutelyPrecipitationEngine.timing(points) else { return nil }
        if timing.isRainingNow {
            if let stop = timing.stop {
                return "正在下雨，约 \(timeText(stop)) 前后转小或停止"
            }
            return "正在下雨，未来 2 小时持续"
        }
        guard let start = timing.start else { return nil }
        if let stop = timing.stop {
            return "约 \(timeText(start)) 开始，\(timeText(stop)) 前后停止"
        }
        return "约 \(timeText(start)) 开始，持续到窗口末"
    }

    /// 「HH:mm」——按选中城市时区渲染（`WeatherTimeFormatter` 内缓存格式器，不逐次新建）。
    private func timeText(_ date: Date) -> String {
        WeatherTimeFormatter.string(from: date, format: "HH:mm", timeZone: timeZone)
    }
}

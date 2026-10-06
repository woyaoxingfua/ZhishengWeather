//
//  OfficialWarningCard.swift
//  ZhishengWeather（主 App target）
//
//  **官方气象预警卡**（第六源 · 中国气象局 NMC）。
//
//  ═══════════════════════════════════════════════════════════════════════
//  四态（**缺一不可**，且 `.none` 与 `.stale` 语义严格对立）
//  ═══════════════════════════════════════════════════════════════════════
//  · `.none`（无预警）→ **整卡隐藏**，不留空白。
//  · `.active`（有预警）→ 按颜色**红 > 橙 > 黄 > 蓝**排序（由 Core 的
//    `OfficialWarningState.sorted` 负责，**本文件不重算**），
//    最多展示 **3 条** + 「还有 N 条」。
//  · `.stale`（**取数失败** 或 **数据超过 6 小时**）→ **显式显示**
//    「预警数据获取失败」/ 「预警数据已过期」，**绝不静默消失**。
//  · `.unavailable`（该源未启用）→ 显式说明。
//
//  ── 为什么 `.stale` 必须显式说出来（本文件存在的全部理由）──────────────
//  若把「取不到」画成「无预警」，用户会在**真正有红色预警时**看到一片平静。
//  灾害天气里这是**内容错误**，代价远高于"多显示一行提示"。
//  故本卡的四种状态都有**可见输出**，唯一会「消失」的是 `.none`
//  —— 而它只在**取数成功且上游确实为空**时出现（契约见
//  `NmcAlarmProviding` 文件头）。
//
//  ── 排序与「还有 N 条」的口径 ─────────────────────────────────────────
//  排序由 Core 的 `OfficialWarningState.sorted` 单点给出（本文件不重算，
//  口径两处漂移比没有文案更糟）。「还有 N 条」= 总数 − 展示数，**如实算**，
//  不用"等"字含糊过去。
//
//  ── 配色：复用 AQI 六档语义色，**不新造一套** ─────────────────────────
//  `color(for:)` 直接映射到 `AirQualityCard.color(for:)` 的既有档：
//  红 → `.medium`（红）、橙 → `.light`（橙）、黄 → `.moderate`（黄）、
//  蓝 → `.good`（绿？**不** —— 见下）。⚠️ 蓝**不复用** `.good`（绿）：
//  预警的「蓝」是最低档但**仍是预警**，用绿色会读成"一切正常"。
//  故蓝用 `Theme.accentSecondary`（与 UV 低档同源的强调色），与既有卡片
//  同源但**语义不冲突**。
//
//  ── 时钟 ─────────────────────────────────────────────────────────────
//  本文件**不调用 `Date()`**：`now` 由调用方注入（ContentView 传
//  `viewModel.lastUpdatedDate` 或 `TimelineView` 的 `context.date`）。
//  发布时刻按**选中城市时区**渲染（D-4 纪律）。
//

import SwiftUI

/// 官方预警卡（四态自持）。
struct OfficialWarningCard: View {

    /// 四态（由 `WeatherViewModel` / Core 的 `resolve` 派生）。
    let state: OfficialWarningState

    /// 判定 / 渲染用的「当前时刻」（**注入**，本文件不读系统时钟）。
    var now: Date

    /// 城市时区（D-4；由 `ContentView` 透传 `viewModel.selectedTimeZone`）。
    var timeZone: TimeZone = .current

    /// 最多展示的条数（其余折叠为「还有 N 条」）。
    var maxVisible: Int = 3

    var body: some View {
        // `.none` → 整卡隐藏（不留空白）；其余三态都有可见输出。
        if case .none = state {
            EmptyView()
        } else {
            card
        }
    }

    // MARK: - 布局

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch state {
            case .none:
                // **不可达**：`body` 已在此之前返回 `EmptyView`。
                // 这里保留分支只为让 `switch` 在类型上完备（编译器要求），
                // **不会**渲染出内容。
                EmptyView()
            case .active(let items):
                activeBody(items)
            case .stale(let reason):
                staleBody(reason)
            case .unavailable:
                noticeBody(icon: "bell.slash",
                           title: "未接入官方预警源",
                           detail: "当前构建未启用中国气象局预警链路。")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(headerColor)
            Text("官方预警")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 8)
            headerBadge
        }
    }

    /// 右上角徽标：显示**最高档颜色名**（`.active`）或状态词（其余两态）。
    @ViewBuilder
    private var headerBadge: some View {
        switch state {
        case .active(let items):
            if let top = items.first {
                Text("\(top.color.displayName)预警")
                    .font(.system(size: Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Self.color(for: top.color))
            }
        case .stale:
            Text("数据不可信")
                .font(.system(size: Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
        case .unavailable:
            Text("未启用")
                .font(.system(size: Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
        case .none:
            EmptyView()
        }
    }

    private var headerColor: Color {
        switch state {
        case .active(let items):
            return items.first.map { Self.color(for: $0.color) } ?? Theme.secondaryText
        case .stale, .unavailable, .none:
            return Theme.secondaryText
        }
    }

    /// `.active`：最多 `maxVisible` 条 + 「还有 N 条」。
    @ViewBuilder
    private func activeBody(_ items: [OfficialWarningItem]) -> some View {
        let visible = Array(items.prefix(maxVisible))
        let hidden = items.count - visible.count
        VStack(alignment: .leading, spacing: 8) {
            ForEach(visible) { item in
                row(item)
            }
            if hidden > 0 {
                Text("还有 \(hidden) 条预警")
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    /// 单条预警行：颜色圆点 + 类型 + 地点 + 发布时间。
    private func row(_ item: OfficialWarningItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Self.color(for: item.color))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(item.kind)预警")
                    .font(.system(size: Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Self.color(for: item.color))
                // ⚠️ 地点缺失（标题没解析出行政区划）→ **不显示地点行**，
                // 绝不显示空白或"未知地点"（原文已在 kind 里带了信息）。
                if let region = item.region, !region.isEmpty {
                    Text(region)
                        .font(.system(size: Theme.FontSize.footnote))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer(minLength: 8)
            // ⚠️ 发布时间缺失 → **不显示时刻**（绝不拿 `now` 编一个出来）。
            if let issuedAt = item.issuedAt {
                Text(Self.issueTimeText(issuedAt, now: now, timeZone: timeZone))
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    /// `.stale`：**显式说明**，并区分两种成因（用户看到的文案不同）。
    @ViewBuilder
    private func staleBody(_ reason: OfficialWarningState.StaleReason) -> some View {
        switch reason {
        case .fetchFailed(let message):
            noticeBody(icon: "wifi.exclamationmark",
                       title: "预警数据获取失败",
                       detail: message.isEmpty ? "未能获取官方预警数据。" : message)
        case .dataTooOld(let latest, let age):
            noticeBody(icon: "clock.badge.exclamationmark",
                       title: "预警数据已过期",
                       detail: Self.staleDetail(latest: latest, age: age))
        }
    }

    /// 统一提示行（图标 + 标题 + 说明）。
    private func noticeBody(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: Theme.FontSize.footnote))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 格式化（纯函数，`nonisolated` 便于直接单测）

    /// 分档语义色：复用 AQI 六档（`AirQualityCard.color(for:)`）。
    ///
    /// ⚠️ **蓝色不复用 `.good`（绿）** —— 理由见文件头：预警的蓝**仍是预警**，
    /// 用绿色会读成"一切正常"，那是**误导**。
    static func color(for color: NmcAlarmColor) -> Color {
        switch color {
        case .red: return AirQualityCard.color(for: .medium)     // 红
        case .orange: return AirQualityCard.color(for: .light)   // 橙
        case .yellow: return AirQualityCard.color(for: .moderate) // 黄
        case .blue: return Theme.accentSecondary                  // 蓝（**非绿**）
        case .unspecified: return Theme.secondaryText            // 未知 = 中性灰
        }
    }

    /// 发布时间文案：1 小时内显示「X 分钟前」，否则显示**城市时区**的钟点。
    ///
    /// ⚠️ 未来时刻（`age < 0`，时区/时钟问题）**不**显示「-3 分钟前」这种
    /// 荒谬文案，改为显示钟点（让用户自己判断）。
    nonisolated static func issueTimeText(_ issuedAt: Date,
                                          now: Date,
                                          timeZone: TimeZone) -> String {
        let age = now.timeIntervalSince(issuedAt)
        if age >= 0, age < 3600 {
            let minutes = Int(age / 60)
            // ⚠️ `0` 分钟显示「刚刚」而不是「0 分钟前」—— 前者才是自然语言。
            return minutes <= 0 ? "刚刚" : "\(minutes) 分钟前"
        }
        return WeatherTimeFormatter.string(from: issuedAt,
                                           format: "HH:mm",
                                           timeZone: timeZone)
    }

    /// `.stale(.dataTooOld)` 的说明文案（**如实给出时长**，不写"很久"）。
    ///
    /// ⚠️ 能走到这里说明 `age > 6h`（或 `age < 0`，见下），
    /// 故文案里**必然**是"已超过 6 小时有效窗口" —— 不存在"仅 40 分钟就过期"
    /// 的表述（那会与判据自相矛盾）。
    nonisolated static func staleDetail(latest: Date?, age: TimeInterval) -> String {
        // latest == nil → **发布时间全部缺失**，无法判定新鲜度（不是"很旧"）。
        guard latest != nil else {
            return "预警发布时间缺失，无法确认数据是否仍然有效。"
        }
        guard age.isFinite, age > 0 else {
            // age ≤ 0（含负）→发布时间晚于当前时刻，属时钟/时区异常，
            // **如实这么说**，不谎报"已过期 N 小时"。
            return "预警发布时间晚于当前时刻，无法确认数据是否仍然有效。"
        }
        let hours = Int(age / 3600)
        if hours >= 1 {
            return "最新一条预警发布于 \(hours) 小时前，已超过 6 小时有效窗口。"
        }
        return "最新一条预警发布于 \(max(1, Int(age / 60))) 分钟前，已超过 6 小时有效窗口。"
    }
}
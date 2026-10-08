//
//  UVIndexCard.swift
//  ZhishengWeather（主 App target）
//
//  UV 指数卡（P2 · AC-B17c）：当前 UV 档位 + 防晒建议 + 当日峰值与峰值时刻。
//
//  ── 挂点 ──
//  `ContentView.mainScroll` 内，**与「短时降水卡」「空气质量卡」同级**，
//  位置在 `ForEach(orderedVisibleSections)` **之前**（即固定区块，**不占用**
//  `HomeSection`、不参与排序/隐藏——理由与 `RadarMapCard` 同款：新增 `case`
//  会让老用户的持久化顺序把它补到尾部，且用户没主动要求过它可排序）。
//
//  ── 判定与文案一律来自 Core 单一真源 ──
//  分级/建议：`UVIndexGuide.currentAdvice(uv:)`；峰值：`UVIndexGuide.dailyPeak(...)`。
//  **本文件不拼任何分级字符串、不重算峰值**（口径两处漂移比没有文案更糟）。
//
//  ── 三条诚实纪律 ──
//  1. `UV == 0` 是**合法值**（夜间），显示「低 · 无需防护」；**不得**当成缺失。
//  2. 当前值与峰值**都**缺失（服务端未返回 / 旧缓存无此键）→ 整卡不渲染；
//     **绝不**显示「未知 / 0 / --」把"没测到"说成"没有紫外线"。
//  3. 峰值时刻按**选中城市时区**渲染（D-4 纪律：设备时区渲染异地城市的钟点会说谎）；
//     且**只有峰值时刻确实来自逐时序列时才显示时刻**——回退到 `daily[0].uvIndexMax`
//     时我们并不知道峰值出现在几点，**绝不**拿 `now` 编一个"峰值出现在现在"出来。
//
//  ── 时钟 ──
//  `now` 由 `TimelineView(.everyMinute)` 注入（**本文件不调用 `Date()`**），
//  与 `MinutelyPrecipitationCard.headlineRow` / `DaylightCard` 同一做法：
//  峰值归属"当日"随时间推移会变（跨零点后应改算新一天的峰值），
//  而调用方注入的固定 `snapshot.fetchedAt` 会静止到下一次整屏刷新。
//

import SwiftUI

/// UV 指数卡。
@MainActor
struct UVIndexCard: View {

    /// 逐时序列（供峰值计算；`WeatherSnapshot.hourly`）。
    let points: [HourlyPoint]
    /// 此刻 UV 指数（`WeatherSnapshot.uvIndex`，**实况**值）。
    ///
    /// ⚠️ 与卡内展示的「当日峰值」语义不同，故峰值优先取逐时序列算出的
    /// `dailyPeak`（含**峰值时刻**），只有当日逐时序列一个有效点都没有时
    /// 才回退到 `DailyForecast.uvIndexMax`（`dailyPeakFallback`，可 nil）。
    let currentUV: Double?
    /// 当日 UV 峰值（`DailyForecast.uvIndexMax`）——**仅在逐时序列算不出峰值时**兜底，
    /// 且此时**不显示峰值时刻**（该字段只有数值，见文件头纪律 3）。
    var dailyPeakFallback: Double? = nil
    /// 城市时区（D-4）。默认设备时区；由 `ContentView` 透传 `viewModel.selectedTimeZone`。
    var timeZone: TimeZone = .current

    /// 本卡折叠态（初值读持久化；点标题行右侧按钮翻转）。
    @State private var isCollapsed: Bool = CardVisibilityStore.isCollapsed(.uv)

    /// 分档语义色（UV 越高越警示）。
    ///
    /// ⚠️ **不引入新配色体系**：低档用 `Theme.accentSecondary`，
    /// 其余四档复用既有 AQI 六档色（`AirQualityCard.color(for:)`）里语义相近的档，
    /// 保证与既有卡片同源、可视觉联想（"越红越警示"）。
    static func color(for level: UVIndexLevel) -> Color {
        switch level {
        case .low: return Theme.accentSecondary
        case .moderate: return AirQualityCard.color(for: .good)
        case .high: return AirQualityCard.color(for: .moderate)
        case .veryHigh: return AirQualityCard.color(for: .light)
        case .extreme: return AirQualityCard.color(for: .severe)
        }
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
    }

    // MARK: - 取值（全部委托 Core，本视图不重算）

    /// 卡片实际要渲染的内容（一次性派生，避免 body 里反复调Core）。
    private struct Resolved {

        /// 当前实况档位建议；nil = 无实况数据。
        let advice: UVIndexGuide.Advice?
        /// 当日峰值；nil = 无数据。
        let peak: UVPeak?
        /// 峰值时刻是否可靠（true = 来自逐时序列；false = 由逐日峰值回退而来，无时刻）。
        let peakTimeIsReliable: Bool
    }

    private func resolve(now: Date) -> Resolved {
        let advice = UVIndexGuide.currentAdvice(uv: currentUV)
        if let peak = UVIndexGuide.dailyPeak(points: points, now: now, timeZone: timeZone) {
            return Resolved(advice: advice, peak: peak, peakTimeIsReliable: true)
        }
        // 逐时序列算不出（缺测 / 空 / 跨天超长）→ 回退逐日峰值；此时**无可靠时刻**。
        let fallback: UVPeak? = dailyPeakFallback.map { UVPeak(value: $0, time: now) }
        return Resolved(advice: advice, peak: fallback, peakTimeIsReliable: false)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let resolved = resolve(now: now)
        // 当前与峰值都无 → 整卡不渲染（纪律 2）。
        if resolved.advice != nil || resolved.peak != nil {
            card(resolved)
        }
    }

    // MARK: - 布局

    private func card(_ resolved: Resolved) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(resolved)
            // 折叠态：只保留标题行，建议 / 峰值 / 补充行全部不渲染。
            //
            // ⚠️ `header` 内仍按 `resolved` 渲染当前档位大字—— 用户折叠后
            // 仍能在标题行看到「当前 UV 值 + 档位」，这正是折叠的价值
            // （收起长文、保留一眼可读的读数）。
            if !isCollapsed {
                if let advice = resolved.advice {
                    Text(advice.adviceText)
                        .font(.system(size: Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Self.color(for: advice.level))
                }
                if let peak = resolved.peak, let peakLevel = UVIndexLevel(uv: peak.value) {
                    peakRow(peak: peak, level: peakLevel, timeIsReliable: resolved.peakTimeIsReliable)
                }
                extraRows
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// 标题行：卡名 + 当前 UV 大字 + 等级名（无实况值 → 大字位显示 "--"）。
    private func header(_ resolved: Resolved) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.accentSecondary)
            Text("紫外线")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 8)
            if let advice = resolved.advice {
                Text(Self.uvText(currentUV))
                    .font(.system(size: Theme.FontSize.metric, weight: .semibold))
                    .foregroundStyle(Self.color(for: advice.level))
                Text(advice.level.displayName)
                    .font(.system(size: Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Self.color(for: advice.level))
            } else {
                Text("当前 --")
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            }
            CardCollapseButton(card: .uv, isCollapsed: isCollapsed, onToggle: toggleCollapse)
        }
    }

    // MARK: - 折叠切换

    /// 翻转折叠态：落库 + 改本地状态（动画与图标统一由 `CardCollapseButton` 驱动）。
    private func toggleCollapse() {
        let next = CardCollapseButton.toggleCollapsed(.uv)
        withAnimation(.easeInOut(duration: 0.15)) {
            isCollapsed = next
        }
    }

    /// 峰值行：数值 + 峰值时刻。
    /// `timeIsReliable == false` 时**不渲染时刻**（见文件头纪律 3）。
    private func peakRow(peak: UVPeak, level: UVIndexLevel, timeIsReliable: Bool) -> some View {
        HStack(spacing: 6) {
            Text("今日峰值 \(Self.uvText(peak.value))")
                .font(.system(size: Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Self.color(for: level))
            Spacer(minLength: 8)
            if timeIsReliable {
                Text("约 \(timeText(peak.time))")
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    /// 逐时补充两行：最低能见度 + 零度层高度峰值。
    ///
    /// 数据来自本轮新增的 `HourlyPoint.visibility` / `.freezingLevelHeight`。
    /// 纪律：**要求该字段在整个序列里都有值**才出行——只要有一个小时缺测，
    /// 「最低能见度」就无从谈起（少数点里的最小值会**低估**真实最差值，
    /// 拿它当结论就是在说谎）。全缺则该行整行隐藏，**绝不**显示 "-- km" 冒充。
    @ViewBuilder
    private var extraRows: some View {
        if !points.isEmpty {
            let visibilities = points.map(\.visibility)
            if visibilities.allSatisfy({ $0 != nil }),
               let minVisibility = visibilities.compactMap({ $0 }).min() {
                detailRow(icon: "eye", text: "能见度最低 \(Self.visText(minVisibility))")
            }
            let levels = points.map(\.freezingLevelHeight)
            if levels.allSatisfy({ $0 != nil }),
               let maxLevel = levels.compactMap({ $0 }).max() {
                detailRow(icon: "arrow.up.to.line", text: "零度层最高 \(Self.metersText(maxLevel))")
            }
        }
    }

    private func detailRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Theme.accentSecondary)
                .frame(width: 16)
            Text(text)
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 格式化（纯函数；`nonisolated` 便于直接单测）

    /// UV 数值文案：1 位小数。
    /// ⚠️ `0.0` 是**合法夜间值**，原样显示为 `0.0`，**不得**转成 "--"。
    nonisolated static func uvText(_ uv: Double?) -> String {
        guard let uv, uv.isFinite else { return "--" }
        return String(format: "%.1f", uv)
    }

    /// 能见度文案（米）：≥1000 m 用 km（1 位小数），否则用 m（整数）。
    /// 与 `ContentView.visibilityText` **同一口径**（≥1 km 才换算）。
    nonisolated static func visText(_ meters: Double?) -> String {
        guard let meters, meters.isFinite, meters >= 0 else { return "--" }
        return metersText(meters)
    }

    /// 米 → 「X m」/「X.X km」（零度层高度与能见度共用同一口径）。
    nonisolated static func metersText(_ meters: Double) -> String {
        if meters >= 1000 { return String(format: "%.1f km", meters / 1000) }
        return String(format: "%.0f m", meters)
    }

    /// 「HH:mm」——按选中城市时区渲染（D-4）。
    private func timeText(_ date: Date) -> String {
        WeatherTimeFormatter.string(from: date, format: "HH:mm", timeZone: timeZone)
    }
}
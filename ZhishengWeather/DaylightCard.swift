//
//  DaylightCard.swift
//  ZhishengWeather（主 App target）  [D-C3]
//
//  日照与昼夜卡：显示今日**昼长** + 「距日落 X 小时 Y 分」。
//
//  ── 昼长取值阶梯（**单点决策**：值与"它从哪来"一起返回，防止标签与实际取值脱钩）──
//   ① 主源 `snapshot.daily` 首项的 `daylightDuration`（**秒**，Open-Meteo 原值；
//      A1 之后 `daily[0]` 恒为今天）；
//   ② 第二源 overlay 的 `daylightDuration`（sunrise-sunset.org 的 day_length；
//      按 `FieldFallbackResolver` 语义，主源有值时它不会是落选者，故这一档实际只在
//      主源缺失时命中 —— 那时**必须**按 L2 纪律标注来源）；
//   ③ 兜底派生：日落 − 日出（两侧都在才有值）。
//  秒 → 「X 小时 Y 分」**一律**走 Core 既有纯函数
//  `DurationFormatter.hoursMinutesText(fromSeconds:)`：本文件**不自带**第二份换算
//  （本项目曾因同一个量在两处各写一份而漂移）。
//  ⚠️ 昼长（`daylightDuration`）≠ 日照时数（`sunshineDuration`）：本卡只做**昼长**，
//     不展示、也不借用日照时数，两者绝不共用一个标签。
//
//  ── 时钟（AC-C7「距日落」倒计时）──
//  由 `TimelineView(.everyMinute)` 驱动：时刻由 SwiftUI 供给，本文件**不调用 `Date()`**
//  （与 Core「禁内部取时钟」同款纪律），且倒计时随视图存活**自动走字** —— 若沿用
//  调用方注入的固定 `now`，屏幕上的倒计时会静止到下一次整屏刷新为止。
//  因此原先的 `now:` 注参已**移除**（两套时钟并存必然漂移，单一真源更诚实）。
//
//  ── 诚实纪律（AC-C7 / AC-C8 / L2）──
//  - 极昼 / 极夜（日出与日落**都**缺失，而昼长是满日 ≥ 86399s 或 0s）→ 如实文案，
//    **绝不编造时刻**；
//  - 日落缺失 → 「距日落」整段隐藏（不显示「-- 小时」）；
//  - 日出/日落各自缺失时只渲染存在的一侧，绝不用另一侧的值顶替；
//  - 第二源交叉校验：overlay 非 nil 字段优先显示；该字段 provenance 标记 .fallback 时
//    行尾标注「来自 sunrise-sunset.org」（沿用既有「本地估算 · 仅供参考」标注范式）。
//
//  注：静态常量用 `private static let`（静态属性不参与合成逐成员初始化器）。
//

import SwiftUI

/// 日照与昼夜卡。
@MainActor
struct DaylightCard: View {

    /// 主源快照（提供 daily[0] 昼长、sunrise/sunset 兜底）。
    let snapshot: WeatherSnapshot
    /// 第二源覆盖层（稀疏字段补丁；已装载的字段优先，缺失字段退回主源）。
    let overlay: FieldPatch?
    /// 逐字段来源图（L2 标注依据）。
    let provenance: FieldProvenanceMap?
    /// 城市时区（上屏按城市时区渲染绝对时刻）。
    let timeZone: TimeZone

    /// 「满日」判据（秒）：≥ 23:59:59 视为极昼（服务端偶尔返回 86399 而非 86400）。
    private static let fullDaySeconds: Double = 86_399

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headline
            sunsetRow
            riseSetRow
        }
    }

    // MARK: - 取值阶梯（overlay 优先，缺则退回主源/派生）

    /// overlay 优先于快照的日出。
    private var effectiveSunrise: Date? { overlay?.instant(.sunrise) ?? snapshot.sunrise }
    /// overlay 优先于快照的日落。
    private var effectiveSunset: Date? { overlay?.instant(.sunset) ?? snapshot.sunset }

    /// 昼长（秒）+ 是否取自第二源（见文件头阶梯）。
    private var daylight: (seconds: Double, isFromSecondSource: Bool)? {
        if let seconds = snapshot.daily?.first?.daylightDuration {
            return (seconds, false)
        }
        if let seconds = overlay?.seconds(.daylightDuration) {
            return (seconds, true)
        }
        if let sunrise = effectiveSunrise, let sunset = effectiveSunset {
            return (sunset.timeIntervalSince(sunrise), false)
        }
        return nil
    }

    /// 极昼 / 极夜文案（AC-C8）：日出与日落**都**缺失，且昼长为满日或零。
    /// 两者只要有一侧存在，就说明该地当天有升落，绝不套用极昼/极夜措辞。
    private var polarText: String? {
        guard effectiveSunrise == nil, effectiveSunset == nil,
              let seconds = daylight?.seconds else { return nil }
        if seconds >= Self.fullDaySeconds { return "今日极昼（全天日照）" }
        if seconds <= 0 { return "今日极夜（全天无日照）" }
        return nil
    }

    // MARK: - 主卡片（图标 + 昼夜 + 昼长）

    private var headline: some View {
        HStack(spacing: 14) {
            Image(systemName: "sun.max")
                .font(.system(size: 30))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accent)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("昼夜")
                    .font(.system(size: Theme.FontSize.metric, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                daylightLine
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(Theme.divider, lineWidth: 0.5)
        )
    }

    /// 昼长行：极昼/极夜 → 如实文案；否则 → 「昼长 X 小时 Y 分」。
    /// 昼长取自第二源时，行尾加标注（标签跟着**实际取值**走，不跟着 provenance 表走）。
    @ViewBuilder
    private var daylightLine: some View {
        if polarText != nil || daylight != nil {
            VStack(alignment: .leading, spacing: 1) {
                if let polarText {
                    Text(polarText)
                        .font(.system(size: Theme.FontSize.caption))
                        .foregroundStyle(Theme.secondaryText)
                } else if let daylight {
                    Text("昼长 \(DurationFormatter.hoursMinutesText(fromSeconds: daylight.seconds))")
                        .font(.system(size: Theme.FontSize.caption))
                        .foregroundStyle(Theme.secondaryText)
                }
                if daylight?.isFromSecondSource == true {
                    Text("来自 sunrise-sunset.org")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accentSecondary)
                }
            }
        }
    }

    // MARK: - 距日落（TimelineView 驱动的走字倒计时）

    /// 「距日落 X 小时 Y 分」行。
    ///
    /// - 日落缺失 → **整段隐藏**（AC-C8：不显示「-- 小时」）；
    /// - 时刻来自 `TimelineView(.everyMinute)`，每分钟自动重算（AC-C7）。
    @ViewBuilder
    private var sunsetRow: some View {
        if effectiveSunset != nil {
            TimelineView(.everyMinute) { context in
                sunsetText(now: context.date)
            }
        }
    }

    /// 倒计时文案（已过日落 → 如实说"今日已日落"，不显示负数或 0 分倒计时）。
    @ViewBuilder
    private func sunsetText(now: Date) -> some View {
        if let sunset = effectiveSunset {
            Group {
                if now < sunset {
                    Text("距日落 \(DurationFormatter.hoursMinutesText(fromSeconds: sunset.timeIntervalSince(now)))")
                } else {
                    Text("今日已日落")
                }
            }
            .font(.system(size: Theme.FontSize.caption))
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 日出 / 日落行（带 L2 来源标注）

    private var riseSetRow: some View {
        HStack(spacing: 16) {
            if let sunrise = effectiveSunrise {
                VStack(alignment: .leading, spacing: 2) {
                    Text("日出 \(timeText(sunrise))")
                        .font(.system(size: Theme.FontSize.caption))
                        .foregroundStyle(Theme.secondaryText)
                    if provenanceLabel(for: .sunrise) {
                        Text("来自 sunrise-sunset.org")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accentSecondary)
                    }
                }
            }
            if let sunset = effectiveSunset {
                VStack(alignment: .leading, spacing: 2) {
                    Text("日落 \(timeText(sunset))")
                        .font(.system(size: Theme.FontSize.caption))
                        .foregroundStyle(Theme.secondaryText)
                    if provenanceLabel(for: .sunset) {
                        Text("来自 sunrise-sunset.org")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accentSecondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 标注 / 格式化

    /// 该字段是否由辅助源补齐（L2 标注）。
    private func provenanceLabel(for key: WeatherFieldKey) -> Bool {
        provenance?[key]?.kind == .fallback
    }

    /// 绝对时刻 → 城市时区 "HH:mm"。
    private func timeText(_ date: Date) -> String {
        WeatherTimeFormatter.string(from: date, format: "HH:mm", timeZone: timeZone)
    }
}

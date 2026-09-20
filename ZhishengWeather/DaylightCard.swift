//
//  DaylightCard.swift
//  ZhishengWeather（主 App target）  [D-C3]
//
//  日照与昼夜卡：显示今日昼长 + 「距日落 X 小时 Y 分」。
//
//  诚实纪律（ARCH §2 D-C3 / AC-C7/C8）：
//  - 日出/日落任一为 nil → 如实文案（"今日无日出/日落记录"），**不编造时刻**；
//  - `now` 由调用方注入（App target 允许取 Date，但沿用注入约定，不私自取时钟）。
//
//  第二源交叉校验（D-C3 / L2）：overlay（来自 sunrise-sunset.org）逐字段叠加，
//  overlay 非 nil 字段优先显示；该字段 provenance 标记 .fallback 时，行尾标注
//  「来自 sunrise-sunset.org」（沿用既有「本地估算 · 仅供参考」标注范式）。
//

import SwiftUI

/// 日照与昼夜卡。
@MainActor
struct DaylightCard: View {

    /// 主源快照（提供 sunrise/sunset/daylightDuration 兜底）。
    let snapshot: WeatherSnapshot
    /// 第二源覆盖层（4 个 solar 字段；非 nil 字段优先）。
    let overlay: FieldPatch?
    /// 逐字段来源图（L2 标注依据）。
    let provenance: FieldProvenanceMap?
    /// 城市时区（上屏按城市时区渲染绝对时刻）。
    let timeZone: TimeZone
    /// 当前时刻（注入，用于「距日落」计算）。
    let now: Date

    /// overlay 优先于快照的日出。
    private var effectiveSunrise: Date? { overlay?.sunrise ?? snapshot.sunrise }
    /// overlay 优先于快照的日落。
    private var effectiveSunset: Date? { overlay?.sunset ?? snapshot.sunset }
    /// 昼长：优先 overlay.daylightDuration；否则由 日落后推 日出→日落。
    private var effectiveDaylight: TimeInterval? {
        if let d = overlay?.daylightDuration, d > 0 { return d }
        if let rise = effectiveSunrise, let set = effectiveSunset {
            return set.timeIntervalSince(rise)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    if let daylight = effectiveDaylight {
                        Text("昼长 \(Self.durationText(daylight))")
                            .font(.system(size: Theme.FontSize.caption))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .stroke(Theme.divider, lineWidth: 0.5)
            )

            // 距日落（基于 effectiveSunset 与注入 now）。
            if let sunset = effectiveSunset {
                if now < sunset {
                    let remain = sunset.timeIntervalSince(now)
                    Text("距日落 \(Self.durationText(remain))")
                        .font(.system(size: Theme.FontSize.caption))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("今日已日落")
                        .font(.system(size: Theme.FontSize.caption))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // 日出/日落行（带 L2 来源标注）。
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

    /// 秒 → 「X 小时 Y 分」（纯函数）。
    private static func durationText(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return "\(hours) 小时 \(minutes) 分"
    }
}

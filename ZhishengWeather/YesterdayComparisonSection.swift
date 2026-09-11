//
//  YesterdayComparisonSection.swift
//  ZhishengWeather（主 App target）
//
//  A1-5 昨日对比行（ARCH-A1 §1.5 / AC-A1-15/16）：
//  Hero 区下方独立小行（不进指标格）——「较昨天 +2° · 昨天 25°→23°」。
//
//  纪律：
//  - `yesterday == nil` → 整行不渲染（AC-A1-16），连占位都不出；
//  - 温差带正负号（+ / −），按"今天均值 − 昨天均值"取整；
//  - 复用 Theme 配色与字号，不新增视觉常量。
//

import SwiftUI

/// 主屏昨日对比行。
/// @MainActor：与项目内其他 View 保持一致。
@MainActor
struct YesterdayComparisonSection: View {

    /// 昨日数据（nil → 整行隐藏，AC-A1-16）。
    let yesterday: DailyForecast?
    /// 今日最高温（℃）（温差与文案的"今天"侧）。
    let todayHigh: Double
    /// 今日最低温（℃）。
    let todayLow: Double

    var body: some View {
        if let yesterday {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accentSecondary)

                Text(text(yesterday))
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Private

    /// 「较昨天 +2° · 昨天 25°→23°」（AC-A1-15 文案式样）。
    ///
    /// 温差 = 今天高低温均值 − 昨天高低温均值（单侧比较会被天气节奏误导，
    /// 均值口径稳定且不受"今天峰值未到"影响）；带正负号，0 显「±0°」。
    private func text(_ yesterday: DailyForecast) -> String {
        let todayMean = (todayHigh + todayLow) / 2
        let yesterdayMean = (yesterday.tempMax + yesterday.tempMin) / 2
        let delta = Int((todayMean - yesterdayMean).rounded())
        let sign = delta > 0 ? "+" : (delta < 0 ? "-" : "±")
        return "较昨天 \(sign)\(abs(delta))° · 昨天 "
            + "↑\(Int(yesterday.tempMax.rounded()))° ↓\(Int(yesterday.tempMin.rounded()))°"
    }
}

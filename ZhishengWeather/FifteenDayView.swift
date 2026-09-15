//
//  FifteenDayView.swift
//  ZhishengWeather（主 App target）
//
//  15 天独立页（A2-9，AC-A2-26/27）：
//   - 数据**复用同一份快照**（构造时传入，不发新请求，AC-A2-27）；
//   - 压暗显示昨天（A1 已在 snapshot.yesterday）+ 全部逐日行（≤15 天）；
//   - 每行数据沿用 DailyForecastRow（含展开态，A2-5 复用）。
//

import SwiftUI

/// 15 天天气页（从逐日区块"查看 15 天"入口进入）。
@MainActor
struct FifteenDayView: View {

    let snapshot: WeatherSnapshot
    /// 城市坐标（逐日行月出月落计算透传）。
    let latitude: Double
    let longitude: Double

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 昨天（压暗显示，AC-A2-26）。
                if let yesterday = snapshot.yesterday {
                    DailyForecastRow(day: yesterday,
                                     latitude: latitude,
                                     longitude: longitude)
                        .opacity(0.55)
                }

                // 全部逐日（≤15 天；daily 自今日起截，A1 纪律）。
                ForEach(snapshot.daily ?? []) { day in
                    DailyForecastRow(day: day,
                                     latitude: latitude,
                                     longitude: longitude)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("15 天预报")
        .navigationBarTitleDisplayMode(.inline)
    }
}

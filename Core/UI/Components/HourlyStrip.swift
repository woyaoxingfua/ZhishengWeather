//
//  HourlyStrip.swift
//  Core / UI / Components  [App + Widget 共用]
//
//  逐小时横向条（列宽 56pt）。主屏与 Medium 小组件复用。
//  首项显示「现在」。
//

import SwiftUI

/// 逐小时横向滚动条。
struct HourlyStrip: View {

    /// 逐小时点（已按 now 起截取）。
    let points: [HourlyPoint]
    /// 首项文案（默认「现在」）。
    var leadingLabel: String = "现在"
    /// 列宽。
    var columnWidth: CGFloat = 56
    /// 图标字号。
    var symbolSize: CGFloat = 16

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    column(index: index, point: point)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Private

    private func column(index: Int, point: HourlyPoint) -> some View {
        VStack(spacing: 6) {
            Text(index == 0 ? leadingLabel : Self.hourFormatter.string(from: point.time))
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)

            WeatherSymbol(code: point.weatherCode,
                          isDay: Self.isDaytime(point.time),
                          size: symbolSize)

            Text("\(Int(point.temperature.rounded()))°")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
        }
        .frame(width: columnWidth)
    }

    /// 小时展示格式器（设备本地时区）。
    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "H时"
        return formatter
    }()

    /// 依据小时判断昼夜（6:00–17:59 记为白天），仅用于图标选择。
    private static func isDaytime(_ date: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= 6 && hour < 18
    }
}

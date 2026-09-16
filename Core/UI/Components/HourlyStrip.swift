//
//  HourlyStrip.swift
//  Core / UI / Components  [App + Widget 共用]
//
//  逐小时横向条（列宽 56pt）。主屏与 Medium 小组件复用。
//  首项显示「现在」。
//
//  D-4：时间渲染改按**传入时区**（默认设备时区）格式化，不再用写死设备时区的
//  静态格式器——App 侧由 VM 透传 selectedTimeZone，异地城市的逐小时时间才正确。
//

import SwiftUI

/// 逐小时横向滚动条。
/// @MainActor：与项目内其他 View 一致（SwiftUI 仅对 body 推断主 actor 隔离），
/// 且下方时间渲染经 `WeatherTimeFormatter`（@MainActor）——整体标注消除非隔离盲区。
@MainActor
struct HourlyStrip: View {

    /// 逐小时点（已按 now 起截取）。
    let points: [HourlyPoint]
    /// 首项文案（默认「现在」）。
    var leadingLabel: String = "现在"
    /// 列宽。
    var columnWidth: CGFloat = 56
    /// 图标字号。
    var symbolSize: CGFloat = 16
    /// 时间渲染时区（D-4）。默认设备时区；App 侧由 ContentView 透传
    /// `viewModel.selectedTimeZone`，小组件侧沿用默认（widget 载荷无时区，本轮不涉及）。
    var timeZone: TimeZone = .current

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
            // D-4：按传入时区渲染小时（首项固定「现在」文案，不渲染时刻）。
            Text(index == 0
                 ? leadingLabel
                 : WeatherTimeFormatter.string(from: point.time,
                                               format: "H时",
                                               timeZone: timeZone))
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

    /// 依据小时判断昼夜（6:00–17:59 记为白天），仅用于图标选择。
    private static func isDaytime(_ date: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= 6 && hour < 18
    }
}

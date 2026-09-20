//
//  HourlyStrip.swift
//  Core / UI / Components  [App + Widget 共用]
//
//  逐小时横向条（列宽 56pt）。首项显示「现在」。
//
//  ⚠️ **事实更正（经代码核实）**：本组件**只被主屏使用**，小组件不复用它。
//  历史上本文件头部曾写「主屏与 Medium 小组件复用」，该断言**不成立**：
//  `ZhishengWeatherWidget/MediumWeatherView` 明确注释「刻意不用 HourlyStrip」
//  （Medium 宽度仅约 338pt，横向滚动区在小组件里不可用），改用自己的布局；
//  `ZhishengWeatherWidget/LargeWeatherView` 亦自带逐时布局。
//  这个错误断言曾一路传导进 PRD 的 AC 与架构文档的设计理由（据此要求"加行不得
//  溢出小组件"），属**事实前提被证伪**。改动本组件时请以此段为准，
//  不要再据"小组件复用"推出任何约束。
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
    /// 是否渲染「降水概率」行（P2 数据补全，已取到未展示的补渲染）。
    ///
    /// 默认 `true`：本组件**当前唯一调用点是主屏**（见文件头的「事实更正」段，
    /// 小组件不复用本组件），主屏可用即应展示。
    ///
    /// 该开关保留的意义是"将来出现高度受限的调用点时可关掉"，**不是**为了小组件
    /// ——早期设计理由（"保护小组件 Medium 不溢出"）建立在被证伪的复用前提上。
    /// 带默认值保证既有调用点不改也能编译。
    var showsPrecipitationProbability: Bool = true

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

            // P2 数据补全：已取到未展示的补渲染——逐时降水概率。
            // nil（服务端未返回 / 元素 null / 旧缓存）→ 显示 "--"，绝不显示 0%；
            // 概率 ≥ 50 用 accentSecondary 强调，否则 secondaryText（复用同一概率值，不另起数字）。
            if showsPrecipitationProbability {
                if let probability = point.precipitationProbability {
                    Text("\(Int(probability.rounded()))%")
                        .font(.system(size: 11))
                        .foregroundStyle(probability >= 50 ? Theme.accentSecondary : Theme.secondaryText)
                        .lineLimit(1)
                } else {
                    Text("--")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: columnWidth)
    }

    /// 依据小时判断昼夜（6:00–17:59 记为白天），仅用于图标选择。
    private static func isDaytime(_ date: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= 6 && hour < 18
    }
}

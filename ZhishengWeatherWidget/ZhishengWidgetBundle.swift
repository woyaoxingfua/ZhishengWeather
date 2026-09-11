//
//  ZhishengWidgetBundle.swift
//  ZhishengWeatherWidget（Widget target）
//
//  @main WidgetBundle 入口 + 天气小组件定义。
//  一个 widget 通过 supportedFamilies 支持 Small / Medium / Large 桌面三族
//  （A1 后再追加 accessoryCircular / accessoryRectangular / accessoryInline
//  锁屏三族，只增不减）；具体渲染由 `ZhishengWeatherWidgetEntryView`
//  按 `@Environment(\.widgetFamily)` 分流。
//
//  F-C 桌面小组件城市选择：`StaticConfiguration` → `AppIntentConfiguration`
//  （三 family 共用**全仓唯一一处** configuration 构造 + 同一 intent 类型，
//  F-C-9 结构性防线）；`kind` 与 `supportedFamilies` 逐字不变（§4.5.5 回归防线）。
//
//  入口由 `@main` 合成提供；Widget Extension 的 Info.plist 只需
//  NSExtensionPointIdentifier = com.apple.widgetkit-extension 这一个键。
//  不要写 principal class —— Swift struct 不符合 NSObject，不会被注册进
//  ObjC 运行时，写上反而解析不到类。
//

import WidgetKit
import SwiftUI
import AppIntents

@main
struct ZhishengWidgetBundle: WidgetBundle {
    var body: some Widget {
        ZhishengWeatherWidget()
    }
}

/// 枳生天气小组件。
struct ZhishengWeatherWidget: Widget {

    /// 唯一标识（§4.5.5：逐字不变，升级后已有组件依赖它迁移）。
    let kind: String = "ZhishengWeatherWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind,
                               intent: WidgetCitySelectionIntent.self,
                               provider: WeatherProvider()) { entry in
            ZhishengWeatherWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("枳生天气")
        .description("一眼查看当前天气、逐小时趋势与体感/湿度/风速等指标。")
        // A1-6：追加锁屏 accessory 三族（只增不减硬纪律，SC-35 基线为前三族）；
        // `kind` / Intent / Provider 零改动（R-A2：已有组件保留性依赖 kind 不变）。
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

/// 依据系统给出的 family 选择对应视图。
///
/// `@unknown default` 不可省略：WidgetKit 未来新增 family（历史上已新增过
/// `.systemExtraLarge`）时，缺省分支能保证老二进制不崩溃、不编译告警。
struct ZhishengWeatherWidgetEntryView: View {

    @Environment(\.widgetFamily) private var family

    let entry: WeatherEntry

    var body: some View {
        switch family {
        case .systemMedium:
            MediumWeatherView(entry: entry)

        case .systemLarge:
            LargeWeatherView(entry: entry)

        case .systemSmall:
            SmallWeatherView(entry: entry)

        case .accessoryCircular:
            AccessoryCircularWeatherView(entry: entry)

        case .accessoryRectangular:
            AccessoryRectangularWeatherView(entry: entry)

        case .accessoryInline:
            AccessoryInlineWeatherView(entry: entry)

        @unknown default:
            // 未知 / 未来新增尺寸：回落到 Small 布局（Smallest 也能放下，
            // 且所有取值路径都已做空态兜底）。
            SmallWeatherView(entry: entry)
        }
    }
}

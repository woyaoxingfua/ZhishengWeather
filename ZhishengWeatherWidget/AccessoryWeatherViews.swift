//
//  AccessoryWeatherViews.swift
//  ZhishengWeatherWidget（Widget target）
//
//  A1-6 锁屏小组件 Accessory 三族（ARCH-A1 §1.6）：
//    - AccessoryCircularWeatherView：温度大字 + 图标（AC-A1-17a）；
//    - AccessoryRectangularWeatherView：城市 / 温度 + 现象 两行（AC-A1-17b）；
//    - AccessoryInlineWeatherView：`23° 多云` 单行（AC-A1-17c）。
//
//  纪律：
//  - **不用 `widgetBackground` / `containerBackground`**：accessory 族背景由
//    系统管理，容器背景调用会被忽略/告警（ARCH-A1 §1.6，SC 纪律平移）；
//  - **AOD 可读（AC-A1-19）**：锁屏由系统按单色/着色模式重绘，文字用
//    `.primary` / 默认前景色层级（不依赖 Theme 深底浅字对比度，R-A7），
//    图标用 WeatherSymbol 的 hierarchical 渲染；
//  - 取值与现有三视图**同源**：`entry.payload?.snapshot` + `displayCityName`，
//    空态 `--°` /「暂无数据」兜底；归属校验（R-C2）经 WeatherProvider 天然继承。
//

import SwiftUI
import WidgetKit

/// Accessory Circular（锁屏圆形）：温度大字 + 图标。
struct AccessoryCircularWeatherView: View {

    let entry: WeatherEntry

    var body: some View {
        VStack(spacing: 2) {
            WeatherSymbol(code: weatherCode, isDay: isDay, size: 20)

            Text(temperatureText)
                .font(.system(size: 22, weight: .bold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
    }

    // MARK: - 取值（与 Small/Medium/Large 同源，空态安全兜底）

    private var snapshot: WeatherSnapshot? { entry.payload?.snapshot }

    private var temperatureText: String {
        guard let snapshot else { return "--°" }
        return "\(Int(snapshot.temperature.rounded()))°"
    }

    private var weatherCode: Int {
        snapshot?.weatherCode ?? -1
    }

    private var isDay: Bool {
        snapshot?.isDay ?? true
    }
}

/// Accessory Rectangular（锁屏矩形）：城市 / 温度 + 现象 两行。
struct AccessoryRectangularWeatherView: View {

    let entry: WeatherEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(cityName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            HStack(spacing: 4) {
                WeatherSymbol(code: weatherCode, isDay: isDay, size: 14)

                Text(temperatureText)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)

                Text(conditionText)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.primary)
    }

    // MARK: - 取值（与 Small/Medium/Large 同源，空态安全兜底）

    private var snapshot: WeatherSnapshot? { entry.payload?.snapshot }

    private var cityName: String {
        // F-C：实例目标城市优先，回退快照 location（placeholder 预览路径）。
        entry.displayCityName ?? "—"
    }

    private var temperatureText: String {
        guard let snapshot else { return "--°" }
        return "\(Int(snapshot.temperature.rounded()))°"
    }

    private var conditionText: String {
        guard let snapshot else { return "暂无数据" }
        return WMOCodeMapper.description(for: snapshot.weatherCode)
    }

    private var weatherCode: Int {
        snapshot?.weatherCode ?? -1
    }

    private var isDay: Bool {
        snapshot?.isDay ?? true
    }
}

/// Accessory Inline（锁屏单行）：`23° 多云`。
struct AccessoryInlineWeatherView: View {

    let entry: WeatherEntry

    var body: some View {
        // inline 族：单行内容，温度 + 现象拼一句（AC-A1-17c）。
        Text("\(temperatureText) \(conditionText)")
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(.primary)
    }

    // MARK: - 取值（与 Small/Medium/Large 同源，空态安全兜底）

    private var snapshot: WeatherSnapshot? { entry.payload?.snapshot }

    private var temperatureText: String {
        guard let snapshot else { return "--°" }
        return "\(Int(snapshot.temperature.rounded()))°"
    }

    private var conditionText: String {
        guard let snapshot else { return "暂无数据" }
        return WMOCodeMapper.description(for: snapshot.weatherCode)
    }
}

//
//  MetricGridLayout.swift
//  ZhishengWeatherWidget（Widget target）
//
//  指标网格：把 `WeatherSnapshot` 的**现有**标量字段（不含任何新增字段）
//  摊平成可复用的 `MetricCell` 网格，供 Medium / Large 两种尺寸共用。
//
//  数据来源严格限定为 `Core/Models/WeatherSnapshot.swift` 已有字段：
//    体感、今日最高、今日最低、湿度、风速、风向、月相。
//  不凭空构造「未来 3 天预报」（模型内没有该字段）。
//

import SwiftUI

/// 网格里的一格。
///
/// 这是一个**视图层**（Widget target）的值对象，不进入 `Core/`，
/// 因此不影响 App / Widget 共用的模型与序列化契约。
struct WidgetMetric: Identifiable, Equatable {

    /// 稳定标识（用 caption 即可，指标名唯一）。
    var id: String { caption }
    /// SF Symbol 名。
    let icon: String
    /// 主数值（含单位，如「3.2 m/s」）。
    let value: String
    /// 说明文案（如「风速」）。
    let caption: String

    init(icon: String, value: String, caption: String) {
        self.icon = icon
        self.value = value
        self.caption = caption
    }
}

/// 指标网格视图（`LazyVGrid` 布局，`MetricCell` 渲染）。
struct MetricGridLayout: View {

    /// 网格元素。
    let metrics: [WidgetMetric]
    /// 列数。
    var columns: Int = 2
    /// 列间距 / 行间距。
    var spacing: CGFloat = 8

    var body: some View {
        LazyVGrid(columns: gridColumns, spacing: spacing) {
            ForEach(metrics) { metric in
                MetricCell(icon: metric.icon,
                           value: metric.value,
                           caption: metric.caption)
            }
        }
    }

    /// 等宽列定义。
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing),
              count: max(1, columns))
    }
}

// MARK: - 快照 → 指标摊平

extension WeatherSnapshot {

    /// 由快照现有字段构造指标数组（空态传 nil 时返回空数组）。
    ///
    /// - Parameter optional: 可能为空的快照。
    /// - Returns: 按「体感 / 今日最高 / 今日最低 / 湿度 / 风速 / 风向」顺序排列的指标。
    static func widgetMetrics(from optional: WeatherSnapshot?) -> [WidgetMetric] {
        guard let snapshot = optional else { return [] }
        return [
            WidgetMetric(icon: "thermometer.medium",
                         value: snapshot.apparentTemperatureText,
                         caption: "体感"),
            WidgetMetric(icon: "arrow.up",
                         value: snapshot.dailyHighText,
                         caption: "今日最高"),
            WidgetMetric(icon: "arrow.down",
                         value: snapshot.dailyLowText,
                         caption: "今日最低"),
            WidgetMetric(icon: "humidity.fill",
                         value: "\(snapshot.humidity)%",
                         caption: "湿度"),
            WidgetMetric(icon: "wind",
                         value: snapshot.windSpeedText,
                         caption: "风速"),
            WidgetMetric(icon: "location.north.fill",
                         value: snapshot.windDirectionText,
                         caption: "风向")
        ]
    }
}

// MARK: - 展示格式化（Widget target 内的小工具）

extension WeatherSnapshot {

    /// 「21°」。
    var apparentTemperatureText: String {
        Self.degreeText(apparentTemperature)
    }

    /// 「25°」。
    var dailyHighText: String {
        Self.degreeText(dailyHigh)
    }

    /// 「15°」。
    var dailyLowText: String {
        Self.degreeText(dailyLow)
    }

    /// 「3.2 m/s」。
    var windSpeedText: String {
        String(format: "%.1f m/s", windSpeed)
    }

    /// 风向角度 → 8 方位中文（与主屏 `ContentView` 的算法保持一致）。
    var windDirectionText: String {
        let directions = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
        let normalized = windDirection.truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        let index = Int((positive / 45).rounded()) % directions.count
        return directions[index]
    }

    /// 气温整度文本。
    private static func degreeText(_ value: Double) -> String {
        "\(Int(value.rounded()))°"
    }
}

extension Optional where Wrapped == WeatherSnapshot {

    /// 「3.2 m/s 东南」；无数据时返回 `nil`（调用方据此隐藏整行）。
    var widgetWindLine: String? {
        guard let snapshot = self else { return nil }
        return "\(snapshot.windSpeedText) \(snapshot.windDirectionText)"
    }
}

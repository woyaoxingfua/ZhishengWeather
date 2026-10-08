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
    /// 🔴 v1.6：`humidity` / `windSpeed` / `windDirection` 已可选 →
    ///   各自走 `humidityText` / `windSpeedText` / `windDirectionText`，
    ///   nil 时如实给占位，**绝不**把 nil 渲染成 `0%` / `0.0 m/s`。
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
                         value: snapshot.humidityText,
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

    /// 🔴 v1.6：**当前气温**大字文案（Small / Medium / Large / Accessory 四族共用）。
    ///
    /// ⚠️ **本文件是它在Widget target 内的唯一实现** —— 本仓历史上因
    ///   `windDirectionText` 在两处各写一份而漂移过一次（见 `docs/DEV-NOTES.md`），
    ///   故此处新增时**刻意收口到一处**，四族视图一律调它，绝不各写一份。
    ///
    /// nil（没测到）→ `"--°"`（与空态的 `--°` 同款，缺测 ≠ 0℃**）。
    var currentTemperatureText: String {
        guard let celsius = temperature, celsius.isFinite else { return "--°" }
        return "\(Int(UnitPreference.displayTemperature(celsius: celsius).rounded()))°"
    }

    /// 🔴 v1.6：湿度文案；nil → `"--"`（**绝不** `"0%"`**：0% 合法，缺测不是 0%**）。
    var humidityText: String {
        guard let percent = humidity else { return "--" }
        return "\(percent)%"
    }

    /// 「3.2 m/s」；nil（没测到）→ `"--"`（**绝不** `"0.0 m/s"`：静风 ≠ 缺测）。
    var windSpeedText: String {
        guard let speed = windSpeed, speed.isFinite else { return "--" }
        return String(format: "%.1f m/s", speed)
    }

    /// 风向角度 → 8 方位中文（与主屏 `ContentView` 的算法保持一致）。
    ///
    /// 🔴 v1.6：nil → `"--"`。**0° / 360° 都是合法风向，原样保留**，
    ///   绝不规范化成 nil（`WindDirectionFormatter` 的既有语义，本仓单测已钉）。
    var windDirectionText: String {
        guard let degrees = windDirection, degrees.isFinite else { return "--" }
        return Self.compassText(from: degrees)
    }

    /// 气温整度文本。
    private static func degreeText(_ value: Double) -> String {
        "\(Int(value.rounded()))°"
    }

    /// 度 → 8 方位中文。
    ///
    /// ⚠️ 与 `Core/Logic/WeatherFieldFormatters.swift` 的 `WindDirectionFormatter.text(from:)`
    ///   **算法逐字一致**（本仓曾因两处各写一份而漂移，见 `docs/DEV-NOTES.md`）。
    ///   本函数是 Widget target 内的本地副本，**仅供本 target 使用**
    ///   （Widget 与 App 是两个编译单元，本仓既有形态即如此）。
    private static func compassText(from degrees: Double) -> String {
        let directions = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        let index = Int((positive / 45).rounded()) % directions.count
        return directions[index]
    }
}

extension Optional where Wrapped == WeatherSnapshot {

    /// 「3.2 m/s 东南」；无数据时返回 `nil`（调用方据此隐藏整行）。
    ///
    /// 🔴 v1.6：风速或风向任一**缺测** → 返回 `nil`（**整行隐藏**），
    ///   绝不渲染 `3.2 m/s --` 这种半截行（半真值比不显示更容易被误读）。
    ///
    /// ⚠️ 判据**直接查可选值本身**，而不是去比较格式化后的字符串 ——
    ///   拿「`--` 这个字符串」当判据，等于把"显示层"和"判空层"绑在一起，
    ///   将来有人改一次占位文案，这里就会静默失配（判据与渲染各写一份必然漂移，
    ///   本仓已因`windDirectionText` 漂移吃过一次亏，见 `docs/DEV-NOTES.md`）。
    var widgetWindLine: String? {
        guard let snapshot = self,
              snapshot.windSpeed?.isFinite == true,
              snapshot.windDirection?.isFinite == true else { return nil }
        return "\(snapshot.windSpeedText) \(snapshot.windDirectionText)"
    }
}

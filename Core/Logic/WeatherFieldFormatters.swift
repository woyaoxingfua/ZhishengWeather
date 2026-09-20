//
//  WeatherFieldFormatters.swift
//  Core / Logic  [App + Widget 共用]
//
//  P2 数据补全的纯展示格式器（与领域数据解耦，便于单测）：
//   - `WindDirectionFormatter`：风向角度 → 8 方位中文（0=北，顺时针）。
//     与 `ContentView.windDirectionText` / `MetricGridLayout.windDirectionText`
//     的既有 8 方位算法逐字一致，抽成单一真相源，避免三处漂移。
//   - `DurationFormatter`：秒 → 「X 小时 Y 分」（昼长 / 日照时数转换）。
//   - `PrecipitationFormatter`：降水深度(mm) → 「X.X mm」（换算责任层，单位锁定 mm）。
//   - `SnowfallFormatter`：降雪深度(cm) → 「X.X cm」（换算责任层，单位锁定 cm；
//     Open-Meteo `snowfall_*` 原值即 cm，禁止改 mm，详见类型注释与单测机械锁）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//  四个 formatter 均为无状态命名空间枚举 + 静态纯函数，不引入实例状态。
//

import Foundation

/// 风向角度 → 8 方位中文（单一真相源）。
enum WindDirectionFormatter {

    /// 8 方位表（索引 0=北，顺时针每 45° 一档）。
    private static let directions = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]

    /// 将风向角度（度，0=北，顺时针）映射为 8 方位中文。
    /// 负角度、超 360 角度均先归一化到 [0, 360)；与既有实现逐字一致。
    /// - Parameter degrees: 风向角度（Open-Meteo `wind_direction_*` 字段原值）。
    static func text(from degrees: Double) -> String {
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        let index = Int((positive / 45).rounded()) % directions.count
        return directions[index]
    }
}

/// 秒 → 「X 小时 Y 分」时长格式器（昼长 / 日照时数）。
enum DurationFormatter {

    /// 将秒数格式化为「X 小时 Y 分」。
    /// - 入参为非负有限值：返回「X 小时 Y 分」（X>0 时）或「Y 分」（不足 1 小时）。
    /// - 非有限 / 负值 → "--"（防御性；调用方通常已对 nil 做了整段隐藏）。
    /// 注：Open-Meteo 的 daylight_duration / sunshine_duration 原值即为秒，本层只做换算，
    /// **不做**任何语义合并（昼长 ≠ 日照时数，二者 UI 分标签）。
    static func hoursMinutesText(fromSeconds seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--" }
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分"
        }
        return "\(minutes) 分"
    }
}

/// 降水深度格式器（单位 **mm**，Open-Meteo `precipitation_*` 原值）。
///
/// ⚠️ 换算责任层锁定：降水单位恒为 **毫米(mm)**，禁止改为 cm。
/// 入参标签 `fromMillimeters:` 在调用点强制显式单位，是防止 cm/mm 串味的
/// 第一道机械锁；配套单测为第二道机械锁（断言 "X.X mm" 而非 "cm"）。
/// 入参为调用方已解包的非 nil 值（nil 隐藏由 `DailyForecast` 文案层处理）；
/// 非有限值 → "--" 防御。
enum PrecipitationFormatter {

    /// 将降水深度（毫米）格式化为「X.X mm」。
    static func text(fromMillimeters mm: Double) -> String {
        guard mm.isFinite else { return "--" }
        return "\(String(format: "%.1f", mm)) mm"
    }
}

/// 降雪深度格式器（单位 **cm**，Open-Meteo `snowfall_*` 原值）。
///
/// ⚠️ 换算责任层锁定：降雪单位恒为 **厘米(cm)**，禁止改为 mm。
/// Open-Meteo 的 `snowfall_*` 字段原值即为 cm（非 mm），这是 P2 探针实测结论；
/// 任何把雪量当 mm 处理的地方都会产生 10× 误差。入参标签 `fromCentimeters:`
/// 在调用点强制显式单位，是防止 cm/mm 串味的第一道机械锁；配套单测为第二道
/// 机械锁（断言 "X.X cm" 而非 "mm"）。
/// 入参为调用方已解包的非 nil 值（nil 隐藏由 `DailyForecast` 文案层处理）；
/// 非有限值 → "--" 防御。
enum SnowfallFormatter {

    /// 将降雪深度（厘米）格式化为「X.X cm」。
    static func text(fromCentimeters cm: Double) -> String {
        guard cm.isFinite else { return "--" }
        return "\(String(format: "%.1f", cm)) cm"
    }
}

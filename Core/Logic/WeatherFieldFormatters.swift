//
//  WeatherFieldFormatters.swift
//  Core / Logic  [App + Widget 共用]
//
//  P2 数据补全的纯展示格式器（与领域数据解耦，便于单测）：
//   - `WindDirectionFormatter`：风向角度 → 8 方位中文（0=北，顺时针）。
//     与 `ContentView.windDirectionText` / `MetricGridLayout.windDirectionText`
//     的既有 8 方位算法逐字一致，抽成单一真相源，避免三处漂移。
//   - `DurationFormatter`：秒 → 「X 小时 Y 分」（昼长 / 日照时数转换）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//  两个 formatter 均为无状态命名空间枚举 + 静态纯函数，不引入实例状态。
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

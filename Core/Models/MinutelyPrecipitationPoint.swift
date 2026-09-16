//
//  MinutelyPrecipitationPoint.swift
//  Core / Models  [App + Widget 共用]
//
//  B1-2 短时降水：单个 15 分钟窗的领域点。
//  风格与 `HourlyPoint` / `DailyForecast` 保持一致：Codable + Equatable + Identifiable + Sendable。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 短时降水序列中的一个 15 分钟数据点（未来约 2 小时）。
///
/// 语义（B1-2 / AC-B1-7）：数据为 **15 分钟粒度**，中国等非原生覆盖区为
/// **插值**——领域层只承载数值，**不声明**其精度来源；"插值"标注由 UI 文案承担
/// （禁止暗示逐分钟 / 雷达临近）。
struct MinutelyPrecipitationPoint: Codable, Equatable, Identifiable, Sendable {

    /// 该 15 分钟窗的起始时刻（epoch 秒解析而来，间隔 900s）。
    var time: Date
    /// 该窗累计降水量（mm）。0 表示该 15 分钟无降水记录。
    var precipitation: Double
    /// 该窗降水概率（%）。
    /// nil = 服务端未返回 / 元素 null（**绝不冒充 0**，与 DailyForecast 同款纪律）。
    var probability: Double? = nil

    /// 以时刻作为稳定标识（同一 15 分钟窗唯一）。
    var id: Date { time }
}

//
//  FieldPatch.swift
//  Core / Networking  [App + Widget 共用]
//
//  一个辅助源的「字段补丁」：只装它声明能力范围内的字段，绝不携带整包快照。
//  这是「按能力挂载而非按整源替换」的载体——第二源 sunrise-sunset.org 只填
//  sunrise/sunset/solarNoon/daylightDuration 四格（ARCH §3.2）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 辅助源产出的「稀疏字段补丁」。
///
/// `capturedAt` 由调用方注入（Core 禁内部取时钟），承载时间维度，
/// 使后续 `FieldFallbackResolver` 纯函数化、无需读墙钟。
struct FieldPatch: Equatable, Sendable {

    /// 产出此补丁的源标识。
    var sourceID: SourceID
    /// 采集时刻（调用方注入，非源内取时钟）。
    var capturedAt: Date

    /// 日出（绝对时刻；上屏时按城市时区渲染，见 ARCH §3.5）。
    var sunrise: Date?
    /// 日落（绝对时刻）。
    var sunset: Date?
    /// 太阳正午（绝对时刻；主源无此字段，仅第二源提供，验证「补一格」能力）。
    var solarNoon: Date?
    /// 昼长（秒，领域单位）。
    var daylightDuration: TimeInterval?

    /// 已装载（非 nil）的字段键集合（派生，不存储）。
    ///
    /// 用于快速判断「该源补了哪些字段」，不进 Equatable 比较、不落盘。
    var fields: [WeatherFieldKey] {
        var result: [WeatherFieldKey] = []
        if sunrise != nil { result.append(.sunrise) }
        if sunset != nil { result.append(.sunset) }
        if solarNoon != nil { result.append(.solarNoon) }
        if daylightDuration != nil { result.append(.daylightDuration) }
        return result
    }

    /// 便捷构造：全部可选，默认 nil。
    init(sourceID: SourceID,
         capturedAt: Date,
         sunrise: Date? = nil,
         sunset: Date? = nil,
         solarNoon: Date? = nil,
         daylightDuration: TimeInterval? = nil) {
        self.sourceID = sourceID
        self.capturedAt = capturedAt
        self.sunrise = sunrise
        self.sunset = sunset
        self.solarNoon = solarNoon
        self.daylightDuration = daylightDuration
    }
}

//
//  SunriseSunsetResponse.swift
//  Core / Networking  [App + Widget 共用]
//
//  第二源 DTO。所有字段**可选 / 整块可选**——任一字段缺失或元素异常都不许让
//  解码抛错（ARCH §7 T08 / 测试锚点）。
//
//  **实测键名（2026-09-19 探针）**：`results.{sunrise,sunset,solar_noon,
//  day_length,...}` + 顶层 `status`("OK") + `tzid`("UTC")。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 第二源响应 DTO（解码失败安全：全部可选）。
struct SunriseSunsetResponse: Decodable, Sendable {

    /// results 子块（整块可选；缺失 → 整体视为无效）。
    struct Results: Decodable, Sendable {
        /// 日出（ISO8601 带 +00:00 偏移，绝对时刻）。
        var sunrise: String?
        /// 日落（ISO8601 带 +00:00 偏移，绝对时刻）。
        var sunset: String?
        /// 太阳正午（ISO8601 带 +00:00 偏移，绝对时刻）。
        var solar_noon: String?
        /// 昼长（秒；实测为整数，用 Double 以同时容纳整数/小数两种形态）。
        var day_length: Double?
    }

    /// 结果块（缺失/异常 → nil，由 mapper 回落为空补丁）。
    var results: Results?
    /// 状态（"OK" 才有效）。
    var status: String?
}

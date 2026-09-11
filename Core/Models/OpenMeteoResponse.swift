//
//  OpenMeteoResponse.swift
//  Core / Models  [App + Widget 共用]
//
//  Open-Meteo /v1/forecast 的原始 DTO。
//  请求带 `timeformat=unixtime`，故所有时间字段均为 epoch 秒（Int），
//  解析侧一律 `Date(timeIntervalSince1970:)`，不做字符串解析。
//
//  v1.1 修订：新增 `daily` 块（采纳 daily 参数）。
//

import Foundation

/// Open-Meteo 原始响应（仅保留本项目所需字段）。
struct OpenMeteoResponse: Codable, Sendable {

    /// 当前实况。
    struct Current: Codable, Sendable {
        /// epoch 秒（timeformat=unixtime）。
        let time: Int
        let temperature_2m: Double
        let relative_humidity_2m: Int
        let apparent_temperature: Double
        let weather_code: Int
        let wind_speed_10m: Double
        let wind_direction_10m: Double
        /// 0 = 夜，1 = 昼。
        let is_day: Int
    }

    /// 逐小时序列。
    struct Hourly: Codable, Sendable {
        let time: [Int]
        let temperature_2m: [Double]
        let weather_code: [Int]
    }

    /// 逐日序列（用于当日高/低温 + F-A 逐日预报）。
    struct Daily: Codable, Sendable {
        let time: [Int]
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
        /// F-A 新增。整键可选：服务端异常省略键时不炸
        /// （mapper 按空数组对齐 → 逐日为空 → 区块隐藏）。
        /// 偏差备案 D-1：PRD 原写非可选，改为可选以与 `daily: Daily?`
        /// 的解码鲁棒性风格一致（DTO 不落盘，解码失败会连累实况与逐小时）。
        let weather_code: [Int]?
        /// F-A 新增。整键可选 + 元素可选：Open-Meteo 可能返回 null 元素（AC-A5）。
        let precipitation_probability_max: [Int?]?
    }

    let timezone: String
    let utc_offset_seconds: Int
    let current: Current
    let hourly: Hourly
    /// 可选：当服务端未返回 daily（或旧缓存）时为 nil，映射层负责回退。
    let daily: Daily?
}

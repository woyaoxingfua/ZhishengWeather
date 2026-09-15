//
//  OpenMeteoResponse.swift
//  Core / Models  [App + Widget 共用]
//
//  Open-Meteo /v1/forecast 的原始 DTO。
//  请求带 `timeformat=unixtime`，故所有时间字段均为 epoch 秒（Int），
//  解析侧一律 `Date(timeIntervalSince1970:)`，不做字符串解析。
//  ⚠️ **唯一例外**：daily.sunrise / daily.sunset（A1-4）绕过 unixtime
//  全局参数，仍为 ISO 本地墙钟字符串 —— DTO 只存原始 String，
//  解码走 `ISOTimeStringDecoder`（ARCH-A1 §1.4 四铁律）。
//
//  v1.1 修订：新增 `daily` 块（采纳 daily 参数）。
//  v1.2 修订（A1）：Current +pressure_msl/surface_pressure（可选 Double，
//    键缺失不炸，偏差备案 D-A1）；Daily +sunrise/sunset（[String]?，D-1 风格）。
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
        /// 海平面气压（hPa）。A1 新增，整键可选：服务端异常省略键时不炸
        /// （偏差备案 D-A1；mapper 内 msl 优先、缺则回退 surface_pressure）。
        let pressure_msl: Double?
        /// 地面气压（hPa）。A1 新增，整键可选（同上）。
        let surface_pressure: Double?
    }

    /// 逐小时序列。
    struct Hourly: Codable, Sendable {
        let time: [Int]
        let temperature_2m: [Double]
        let weather_code: [Int]
        /// A2-2 新增。逐时降水概率（%），元素/整键均可选（Open-Meteo 可能返回 null 元素）。
        /// 默认 nil：旧测试/旧调用零改动（Codable 解码不受默认值影响）。
        var precipitation_probability: [Double?]? = nil
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
        /// A1-4 新增。日出时刻，ISO 本地墙钟字符串（如 "2026-09-11T05:53"，
        /// 无时区后缀）——⚠️ 不受 timeformat=unixtime 影响，**禁止**用 epoch
        /// 路径解析；解码入口 = `ISOTimeStringDecoder.date(from:utcOffsetSeconds:)`。
        /// 整键可选 + 元素可选（极地日期可能为 null 元素）。
        let sunrise: [String?]?
        /// A1-4 新增。日落时刻，同上。
        let sunset: [String?]?
        /// A2-2 新增。逐日 UV 指数峰值，元素/整键均可选。默认 nil（旧调用零改动）。
        var uv_index_max: [Double?]? = nil
    }

    let timezone: String
    let utc_offset_seconds: Int
    let current: Current
    let hourly: Hourly
    /// 可选：当服务端未返回 daily（或旧缓存）时为 nil，映射层负责回退。
    let daily: Daily?
}

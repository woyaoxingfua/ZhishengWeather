//
//  ArchiveResponse.swift
//  Core / Models  [App + Widget 共用]
//
//  历史天气 DTO（A3-1，ERA5 再分析）。**不进共享容器**（仅历史页消费，
//  Widget 载荷契约零改动）。全字段可选——服务端异常缺键时解码不炸。
//  ⚠️ ERA5 为网格再分析资料，非实况观测（页面脚注声明，AC-A3-3）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// Open-Meteo Archive 原始响应。
struct ArchiveResponse: Codable, Sendable {

    /// 逐日块。
    struct Daily: Codable, Sendable {
        /// 日期（ISO `yyyy-MM-dd` 字符串数组——Archive API 无 timeformat=unixtime）。
        let time: [String]?
        /// 日最高温（℃）。
        let temperature_2m_max: [Double?]?
        /// 日最低温（℃）。
        let temperature_2m_min: [Double?]?
        /// WMO 天气码。
        let weather_code: [Int?]?
        /// 日降水量合计（mm）。
        let precipitation_sum: [Double?]?
    }

    let daily: Daily?
}

//
//  GeocodingResponse.swift
//  Core / Models  [App + Widget 共用]
//
//  F-B：Open-Meteo geocoding /v1/search 的原始 DTO。
//  仅保留本项目所需字段；可选键一律显式 Optional。
//
//  Core 纪律：仅 import Foundation；纯 Codable 结构体，无逻辑。
//

import Foundation

/// Open-Meteo geocoding 原始响应（仅保留本项目所需字段）。
struct GeocodingResponse: Codable, Sendable {

    /// 一个地理候选点。
    struct Place: Codable, Sendable {
        /// 城市名（geocoding 必返）。
        let name: String
        let latitude: Double
        let longitude: Double
        /// 国家（去歧义显示用）；可缺（AC-B20）。
        let country: String?
        /// 省份；可缺，**绝不渲染 "null"**（AC-B20）。
        let admin1: String?
        /// IANA 时区；可缺 → `City.timeZoneIdentifier = nil`。
        let timezone: String?
    }

    /// 候选列表。
    ///
    /// ⚠️ **必须可选**：无命中时服务端**不返回该键**（PRD §3.5.1），
    /// 若声明为非可选，"无命中"会整条解码失败、被误判成网络/解码错误，
    /// 违反 AC-B19（无命中 ≠ 失败）。
    let results: [Place]?
}

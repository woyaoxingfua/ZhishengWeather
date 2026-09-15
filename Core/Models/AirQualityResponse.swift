//
//  AirQualityResponse.swift
//  Core / Models  [App + Widget 共用]
//
//  Open-Meteo Air Quality API 的原始 DTO（独立域名
//  `air-quality-api.open-meteo.com/v1/air-quality`，CAMS 模型）。
//
//  本文件仅描述本项目所需的 `current` 块；所有字段**整键可选**
//  （DTO 不落盘、不参与共享容器）：服务端异常省略某键时解码不炸，
//  缺失字段由 `AirQualityMapper` 映射为 nil（偏差备案 D-A1 风格）。
//  负值在 mapper 层被净化（见 AirQualityMapper），DTO 保留原始值以保留诊断信息。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// Open-Meteo 空气质量原始响应（仅保留本项目所需字段）。
struct AirQualityResponse: Codable, Sendable {

    /// 当前空气质量实测。
    struct Current: Codable, Sendable {
        /// 海平面 PM2.5（μg/m³）。整键可选。
        let pm2_5: Double?
        /// PM10（μg/m³）。整键可选。
        let pm10: Double?
        /// 一氧化碳 CO（μg/m³）。整键可选。
        let carbon_monoxide: Double?
        /// 二氧化氮 NO₂（μg/m³）。整键可选。
        let nitrogen_dioxide: Double?
        /// 二氧化硫 SO₂（μg/m³）。整键可选。
        let sulphur_dioxide: Double?
        /// 臭氧 O₃（μg/m³）。整键可选。
        let ozone: Double?
        /// 美标 AQI（0–500+）。整键可选。
        /// 着色与分档只采用美标（PRD §7 Q2 裁定），见 `AirQuality.level`。
        let us_aqi: Int?
        /// 欧标 AQI。整键可选，仅作辅助展示，不参与着色。
        let european_aqi: Int?
    }

    /// 当前块（响应可能整体缺少 current → 上游按回退处理）。
    let current: Current?
}

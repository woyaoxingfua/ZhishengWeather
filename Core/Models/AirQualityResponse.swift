//
//  AirQualityResponse.swift
//  Core / Models  [App + Widget 共用]
//
//  Open-Meteo Air Quality API 的原始 DTO（独立域名
//  `air-quality-api.open-meteo.com/v1/air-quality`，CAMS 模型）。
//
//  本文件描述本项目所需的 `current` 块与 `hourly` 块（P2 修订 D-B11 新增逐时）；
//  所有字段**整键可选**，数组类字段**整键可选 + 元素也可选**（`[T?]?`）：
//  服务端异常省略某键、或返回 null 元素时解码都不炸，缺失字段由
//  `AirQualityMapper` 映射为 nil（偏差备案 D-A1 风格）。
//  负值在 mapper 层被净化（见 AirQualityMapper），DTO 保留原始值以保留诊断信息。
//
//  ⚠️ 为什么数组元素也必须可选（本仓库真机事故）：默认窗口（120 小时）尾段实测
//  返回 null 元素；若把元素写成非可选（`[Double]`），合成解码器会抛错导致
//  **整包解码失败** —— 主屏与小组件同时无数据。逐时块一律用 `[T?]?`。
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

    /// 逐时序列（P2 修订 D-B11 / D-C4 新增；D-B11 明确含 AQI 与 PM2.5）。
    ///
    /// 实测形态（2026-09-20 探针，声明 `forecast_hours=24`）：`time` / `us_aqi` /
    /// `pm2_5` / `pm10` 四个数组等长 24 条，`time` 为 epoch 秒、步长 3600s
    /// （`timeformat=unixtime` 生效）。
    ///
    /// 可选纪律：整键可选 + **元素也可选**（`[T?]?`）。不声明长度时服务端会继承
    /// 120 小时默认窗口，尾段元素实测为 null —— 元素非可选会让合成解码器整包失败。
    struct Hourly: Codable, Sendable {
        /// 逐时整点时刻（本项目固定 `timeformat=unixtime` → epoch 秒）。
        let time: [Int?]?
        /// 逐时美标 AQI。元素 null = 该小时缺测（**绝不补 0**：0 是合法读数）。
        let us_aqi: [Int?]?
        /// 逐时 PM2.5（μg/m³）。元素 null = 该小时缺测。
        let pm2_5: [Double?]?
        /// 逐时 PM10（μg/m³）。元素 null = 该小时缺测。
        let pm10: [Double?]?
    }

    /// 当前块（响应可能整体缺少 current → 上游按回退处理）。
    let current: Current?

    /// 逐时块（P2 修订 D-B11 新增）。
    /// `var ... = nil` 而非 `let`：合成逐成员初始化器把它放在末位并带默认值，
    /// 既有构造点零改动；同时 JSON 缺 `hourly` 键（旧响应 / 旧测试凭据）
    /// → 合成解码器返回 nil、不抛错。
    var hourly: Hourly? = nil
}

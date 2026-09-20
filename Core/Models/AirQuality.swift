//
//  AirQuality.swift
//  Core / Models  [App + Widget 共用]
//
//  空气质量领域模型（A2-1）：由 `AirQualityMapper` 从 DTO 映射而来，
//  **仅存于 WeatherViewModel 的独立属性 `airQuality`**，不进
//  `WeatherSnapshot` / 共享容器（ARCH-A2 §1.1①，Widget 载荷契约零改动）。
//
//  AQI 分档裁定（PRD §7 Q2）：着色与六档**只跟美标 us_aqi**；
//  欧标 european_aqi 仅辅助展示。六档边界为 EPA 官方断点：
//  优(0-50) 良(51-100) 轻度(101-150) 中度(151-200) 重度(201-300) 严重(>300)。
//
//  主导污染物（D-A2-1 备案）：简化相对权重法 —— 六项实测值除以各自
//  EPA 24h 基准浓度做归一化，取比值最大者。基准值来源（EPA NAAQS，
//  便于后续升级完整断点法时对照）：
//    PM2.5: 35.0 μg/m³   PM10: 150.0 μg/m³   O₃: 70.0 ppb≈137.5 μg/m³(*)
//    NO₂: 100.0 μg/m³    SO₂: 365.0 μg/m³    CO: 40000.0 μg/m³
//  (*) O₃ 单位按 μg/m³ 直录，比例权重不影响"取最大"的相对排序。
//
//  P2 修订（D-C4 / D-B11）：新增 `hourly` 逐时趋势（见 `AqiHourlyPoint`），
//  仅供主屏空气卡的 24 小时 AQI 趋势区使用；**不进** `WeatherSnapshot` /
//  共享容器，小组件载荷契约零改动。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 逐时 AQI 趋势点（P2 修订 D-C4 / D-B11，AC-C9 / AC-C10 的数据来源）。
///
/// 只承载数值，**不声明**精度来源。任一值字段为 nil = 服务端该小时未返回 /
/// 元素为 null（**绝不补 0**：`0` 是合法读数，与"缺测"必须区分）。
/// nil 在曲线上表现为**断开**（见 `AqiTrendLayout`），绝不连线跨越缺口 ——
/// 跨越缺口会把"没有数据"画成"空气变好"或"持续平稳"（AC-C10）。
struct AqiHourlyPoint: Codable, Equatable, Identifiable, Sendable {

    /// 该小时整点时刻（由 epoch 秒解析而来，步长 3600s）。
    var time: Date
    /// 该小时美标 AQI（六档着色的数据源）。nil = 缺测。
    var usAqi: Int?
    /// 该小时 PM2.5（μg/m³）。nil = 缺测。`0` 原样保留为 0。
    var pm25: Double?
    /// 该小时 PM10（μg/m³）。nil = 缺测。`0` 原样保留为 0。
    var pm10: Double?

    /// 以时刻作为稳定标识（同一整点唯一）。
    var id: Date { time }
}

/// 空气质量领域模型（独立于天气快照链路，ARCH-A2 §1.1①）。
struct AirQuality: Codable, Equatable, Sendable {

    /// 美标 AQI（着色/分档唯一依据，Q2 裁定）。nil = 服务端未返回/解析失败。
    var usAqi: Int?
    /// 欧标 AQI（仅辅助展示，不参与着色）。
    var europeanAqi: Int?
    /// PM2.5（μg/m³）。
    var pm25: Double?
    /// PM10（μg/m³）。
    var pm10: Double?
    /// 一氧化碳 CO（μg/m³）。
    var carbonMonoxide: Double?
    /// 二氧化氮 NO₂（μg/m³）。
    var nitrogenDioxide: Double?
    /// 二氧化硫 SO₂（μg/m³）。
    var sulphurDioxide: Double?
    /// 臭氧 O₃（μg/m³）。
    var ozone: Double?
    /// 逐时 AQI 趋势（P2 修订 D-C4 / D-B11）。
    ///
    /// nil（旧载荷 / 服务端未返回该块 / time 为空）与空数组同义：
    /// 趋势区**整块隐藏**，不留空槽（AC-B24）。
    /// 末位带默认值：既有构造点与既有 JSON 解码零改动。
    var hourly: [AqiHourlyPoint]? = nil
}

// MARK: - AQI 六档（美标 us_aqi）

/// AQI 六档分级（EPA 断点，着色语义在 UI 层由 level 映射颜色）。
enum AqiLevel: Equatable, Sendable {
    case good          // 优    0–50
    case moderate      // 良    51–100
    case light         // 轻度  101–150
    case medium        // 中度  151–200
    case heavy         // 重度  201–300
    case severe        // 严重  >300
    case unknown       // usAqi 缺失 → "未知"（卡片降级显示 --）

    /// 由美标 AQI 数值分级（边界 50/51、100/101、150/151、200/201、300/301）。
    init(usAqi: Int?) {
        guard let aqi = usAqi else {
            self = .unknown
            return
        }
        switch aqi {
        case ...50:   self = .good
        case ...100:  self = .moderate
        case ...150:  self = .light
        case ...200:  self = .medium
        case ...300:  self = .heavy
        default:      self = .severe
        }
    }

    /// 中文等级名（空气卡显示用）。
    var displayName: String {
        switch self {
        case .good: return "优"
        case .moderate: return "良"
        case .light: return "轻度污染"
        case .medium: return "中度污染"
        case .heavy: return "重度污染"
        case .severe: return "严重污染"
        case .unknown: return "未知"
        }
    }
}

extension AirQuality {

    /// 美标六档（Q2 裁定：仅由 usAqi 分档；nil → .unknown）。
    var level: AqiLevel {
        AqiLevel(usAqi: usAqi)
    }

    /// 主导污染物（D-A2-1 简化相对权重法：实测值 / EPA 24h 基准，取比值最大）。
    /// 全部六项缺失或非正 → nil（卡片隐藏该段）。
    var dominantPollutant: String? {
        // EPA NAAQS 24h 基准（μg/m³），见文件头注释。
        let ratios: [(name: String, ratio: Double?)] = [
            ("PM2.5", pm25.map { $0 / 35.0 }),
            ("PM10", pm10.map { $0 / 150.0 }),
            ("臭氧", ozone.map { $0 / 137.5 }),
            ("二氧化氮", nitrogenDioxide.map { $0 / 100.0 }),
            ("二氧化硫", sulphurDioxide.map { $0 / 365.0 }),
            ("一氧化碳", carbonMonoxide.map { $0 / 40_000.0 })
        ]
        // 只取"有效测量值"参与比较（nil 或非正数跳过——负值在 mapper 已净化，双保险）。
        let candidates = ratios.compactMap { item -> (String, Double)? in
            guard let ratio = item.ratio, ratio > 0 else { return nil }
            return (item.name, ratio)
        }
        guard let max = candidates.max(by: { $0.1 < $1.1 }) else { return nil }
        return max.0
    }
}

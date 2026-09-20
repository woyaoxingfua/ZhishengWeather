//
//  HourlyPoint.swift
//  Core / Models  [App + Widget 共用]
//
//  单个逐小时预报点。
//

import Foundation

/// 逐小时预报中的一个时间点。
struct HourlyPoint: Codable, Equatable, Identifiable, Sendable {

    /// 该小时的时刻（epoch 秒解析而来）。
    var time: Date
    /// 气温（℃）。
    var temperature: Double
    /// WMO 天气码（0–99）。
    var weatherCode: Int
    /// 降水概率（%，0–100）。A2-2 摘要引擎输入（A2 新增，可选）：
    /// nil = 服务端未返回 / 元素 null / 旧缓存无此键（Widget 不消费，仅主屏摘要用）。
    var precipitationProbability: Double? = nil
    /// P2 数据补全：该小时降水量（mm）。可选：
    /// nil = 服务端未返回 / 元素 null / 旧缓存无此键。0.0 是合法值（原样保留，不转 nil）。
    var precipitation: Double? = nil
    /// P2 数据补全：该小时风速（m/s，随 wind_speed_unit=ms）。可选，nil 语义同上。
    var windSpeed: Double? = nil
    /// P2 数据补全：该小时阵风（m/s）。可选，nil 语义同上。
    var windGusts: Double? = nil
    /// P2 数据补全：该小时体感温度（℃）。可选，nil 语义同上。
    var apparentTemperature: Double? = nil

    /// 以时刻作为稳定标识（同一小时内唯一）。
    var id: Date { time }
}

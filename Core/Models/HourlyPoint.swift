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

    /// 以时刻作为稳定标识（同一小时内唯一）。
    var id: Date { time }
}

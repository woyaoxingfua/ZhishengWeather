//
//  SharedWeatherPayload.swift
//  Core / Models  [App + Widget 共用]
//
//  App Group 共享容器的落盘结构：{ snapshot, updatedAt }。
//

import Foundation

/// 写入共享容器的载荷。主 App 写、Widget 只读。
struct SharedWeatherPayload: Codable, Equatable, Sendable {

    /// 天气快照。
    var snapshot: WeatherSnapshot
    /// 该快照的写入时间（用于「更新于 HH:mm」与新鲜度判断）。
    var updatedAt: Date
}

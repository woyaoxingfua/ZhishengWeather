//
//  LocationInfo.swift
//  Core / Models  [App + Widget 共用]
//
//  城市名 + 经纬度 + 是否为回落（fallback）坐标。
//

import Foundation

/// 查询天气所使用的地理位置。
struct LocationInfo: Codable, Equatable, Sendable {

    /// 展示用城市名（例如「北京」或「当前位置」）。
    var name: String
    /// 纬度（WGS84）。
    var latitude: Double
    /// 经度（WGS84）。
    var longitude: Double
    /// 是否为回落的默认坐标（授权被拒 / 失败 / 超时）。
    var isFallback: Bool

    init(name: String, latitude: Double, longitude: Double, isFallback: Bool) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.isFallback = isFallback
    }

    /// 默认回落坐标：北京。
    static let beijing = LocationInfo(
        name: "北京",
        latitude: 39.9042,
        longitude: 116.4074,
        isFallback: true
    )
}

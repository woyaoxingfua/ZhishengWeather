//
//  GeocodingMapper.swift
//  Core / Networking  [App + Widget 共用]
//
//  F-B：geocoding DTO → [City] 候选。
//  纯函数、无状态、禁内部 Date()；nil 字段透传（AC-B20 数据侧）。
//

import Foundation

/// geocoding DTO → 领域模型映射器（纯函数）。
enum GeocodingMapper {

    /// 将 geocoding 响应映射为城市候选数组。
    ///
    /// - 规范化 id 由 `City.init` 内部统一走 `City.makeID`（唯一入口）；
    /// - `country` / `admin1` / `timezone` 缺失 → 透传 nil（绝不造空串或 "null"）；
    /// - 候选一律 `isCurrentLocation == false`（"当前位置"只来自定位 upsert）。
    ///
    /// - Parameter response: 解码后的 DTO。
    /// - Returns: 候选城市数组；`results` 为 nil / 空时返回空数组。
    static func cities(from response: GeocodingResponse) -> [City] {
        guard let places = response.results else { return [] }
        return places.map { place in
            City(name: place.name,
                 latitude: place.latitude,
                 longitude: place.longitude,
                 isCurrentLocation: false,
                 country: place.country,
                 admin1: place.admin1,
                 timeZoneIdentifier: place.timezone)
        }
    }
}

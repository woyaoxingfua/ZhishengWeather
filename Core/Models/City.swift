//
//  City.swift
//  Core / Models  [App + Widget 共用]
//
//  F-B 多城市：用户城市列表中的一项。
//  持久化为 `[City]` JSON（独立共享 key `zs.weather.cities`），
//  数组顺序即展示顺序（D-2：不设 sortOrder 字段）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 用户城市列表中的一项。
struct City: Codable, Equatable, Identifiable, Sendable {

    /// 稳定标识：坐标规范化（保留 2 位小数）拼接 "lat,lon"，如 "39.90,116.41"。
    /// 跨启动稳定；同时是 AC-B8 去重（容差 ~0.01°）的判定键。
    var id: String
    /// 展示名（"杭州" / "当前位置"）。
    var name: String
    /// 纬度（WGS84）。
    var latitude: Double
    /// 经度（WGS84）。
    var longitude: Double
    /// IANA 时区（如 "Asia/Shanghai"）。来自 geocoding `timezone`，缺失为 nil。
    /// 本轮仅存储（供列表显示与后续 F-C），取数仍用 `timezone=auto` 不变。
    var timeZoneIdentifier: String?
    /// 国家（去歧义显示用），缺失为 nil。
    var country: String?
    /// 省份（去歧义显示用），缺失为 nil（AC-B20：缺省绝不渲染 "null"）。
    var admin1: String?
    /// 是否为"当前位置"项（随定位更新坐标）。
    var isCurrentLocation: Bool

    /// 由字段构造（id 由 `makeID` 规范化生成）。
    /// - Parameters:
    ///   - name: 展示名。
    ///   - latitude: 纬度。
    ///   - longitude: 经度。
    ///   - isCurrentLocation: 是否"当前位置"项。
    ///   - country: 国家（可缺）。
    ///   - admin1: 省份（可缺）。
    ///   - timeZoneIdentifier: IANA 时区（可缺）。
    init(name: String, latitude: Double, longitude: Double, isCurrentLocation: Bool,
         country: String? = nil, admin1: String? = nil, timeZoneIdentifier: String? = nil) {
        self.id = Self.makeID(latitude: latitude, longitude: longitude)
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.timeZoneIdentifier = timeZoneIdentifier
        self.country = country
        self.admin1 = admin1
        self.isCurrentLocation = isCurrentLocation
    }

    // MARK: - 规范化 id（全项目唯一入口）

    /// 生成规范化坐标 id：`"%.2f,%.2f"`（四舍五入，正负对称，见 ARCH-FB R-6）。
    /// 去重与持久化都依赖它，禁止在其他处自行拼 id。
    /// - Parameters:
    ///   - latitude: 纬度。
    ///   - longitude: 经度。
    /// - Returns: 形如 "39.90,116.41" 的稳定标识。
    static func makeID(latitude: Double, longitude: Double) -> String {
        String(format: "%.2f,%.2f", latitude, longitude)
    }

    // MARK: - 便捷构造

    /// 默认城市：北京（复用 `LocationInfo.beijing` 的坐标与名称，不引入第二套默认坐标）。
    static var beijingDefault: City {
        City(name: LocationInfo.beijing.name,
             latitude: LocationInfo.beijing.latitude,
             longitude: LocationInfo.beijing.longitude,
             isCurrentLocation: false)
    }

    /// → `LocationInfo`（取数与快照 location 覆盖用，ARCH-FB §3.2 / 回归点 R-3）。
    var locationInfo: LocationInfo {
        LocationInfo(name: name,
                     latitude: latitude,
                     longitude: longitude,
                     isFallback: false)
    }
}

//
//  ArchiveEndpoint.swift
//  Core / Networking  [App + Widget 共用]
//
//  历史天气第三链路（A3-1，独立域名 archive-api.open-meteo.com，ERA5 再分析）。
//  请求近 N 日 `temperature_2m_max/min,weather_code,precipitation_sum`（AC-A3-1）。
//  与主链路/空气链路物理分离；错误收敛 `WeatherError`。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// Open-Meteo Archive 请求地址拼装器（历史天气第三链路）。
enum ArchiveEndpoint {

    /// 独立基础地址（ERA5 再分析资料）。
    static let baseURLString = "https://archive-api.open-meteo.com/v1/archive"

    /// daily 字段（AC-A3-1）。
    static let dailyFields = [
        "temperature_2m_max",
        "temperature_2m_min",
        "weather_code",
        "precipitation_sum"
    ].joined(separator: ",")

    /// 依据坐标与起止日期拼装请求 URL。
    /// - Parameters:
    ///   - latitude: 纬度。
    ///   - longitude: 经度。
    ///   - startDate: 起始日（含），格式 `yyyy-MM-dd`。
    ///   - endDate: 结束日（含），格式 `yyyy-MM-dd`。
    static func url(latitude: Double, longitude: Double,
                    startDate: String, endDate: String) -> URL? {
        var components = URLComponents(string: baseURLString)
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "start_date", value: startDate),
            URLQueryItem(name: "end_date", value: endDate),
            URLQueryItem(name: "daily", value: dailyFields),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        return components?.url
    }

    /// 气候档案专用 URL：仅取日最高温，最小化响应体积与加权成本。
    /// 保持 `url(latitude:longitude:startDate:endDate:)` 不变，避免影响历史天气页。
    /// - Parameters:
    ///   - latitude: 纬度。
    ///   - longitude: 经度。
    ///   - startDate: 起始日（含），格式 `yyyy-MM-dd`。
    ///   - endDate: 结束日（含），格式 `yyyy-MM-dd`。
    static func climateProfileURL(latitude: Double, longitude: Double,
                                  startDate: String, endDate: String) -> URL? {
        var components = URLComponents(string: baseURLString)
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "start_date", value: startDate),
            URLQueryItem(name: "end_date", value: endDate),
            URLQueryItem(name: "daily", value: "temperature_2m_max"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        return components?.url
    }
}

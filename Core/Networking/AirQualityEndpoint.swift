//
//  AirQualityEndpoint.swift
//  Core / Networking  [App + Widget 共用]
//
//  拼装 Open-Meteo Air Quality API 请求 URL（第二条免密链路，独立域名）。
//  与 `OpenMeteoEndpoint`（/v1/forecast 主链路）并列，互不干扰。
//
//  设计点：
//  - 仅取 `current`（瞬时六项 + 双 AQI），无需 hourly / daily / 历史，
//    故**不声明** `timeformat=unixtime`（无时间数组需要 epoch 解析）。
//  - 声明 `timezone=auto` 跟随坐标时区（与主链路一致），用于服务端一致性。
//  - 请求面 AC-A2-1：current = pm10,pm2_5,carbon_monoxide,nitrogen_dioxide,
//    sulphur_dioxide,ozone,us_aqi,european_aqi。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// Open-Meteo Air Quality 请求地址拼装器（独立域名）。
enum AirQualityEndpoint {

    /// 独立基础地址（与主链路 api.open-meteo.com 分离）。
    static let baseURLString = "https://air-quality-api.open-meteo.com/v1/air-quality"

    /// 实况字段（AC-A2-1，八字段）。
    static let currentFields = [
        "pm10",
        "pm2_5",
        "carbon_monoxide",
        "nitrogen_dioxide",
        "sulphur_dioxide",
        "ozone",
        "us_aqi",
        "european_aqi"
    ].joined(separator: ",")

    /// 依据坐标拼装请求 URL；失败返回 nil（由调用方收敛为 `WeatherError.badURL`）。
    static func url(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: baseURLString)
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: currentFields),
            // 跟随坐标时区（与主链路一致），无时间数组故不声明 timeformat。
            URLQueryItem(name: "timezone", value: "auto")
        ]
        return components?.url
    }
}

//
//  SunriseSunsetEndpoint.swift
//  Core / Networking  [App + Widget 共用]
//
//  第二源 api.sunrise-sunset.org 请求 URL 拼装（免 Key、无特殊头，已实测 200）。
//
//  **实测结论（2026-09-19 真实 curl 探针，HTTP 200）**：
//  响应体键名：`results.{sunrise, sunset, solar_noon, day_length,
//  civil_twilight_begin/end, ...}` + 顶层 `status`（"OK"）+ `tzid`（"UTC"）。
//  时间形态：sunrise/sunset/solar_noon 为**带 +00:00 偏移的 ISO8601 字符串**
//  （如 "2026-09-19T21:58:29+00:00"），即**绝对 UTC 时刻**；day_length 为
//  **整数秒**（如 44329）。本端点请求 `formatted=0` 以拿到 ISO 形态时间。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// api.sunrise-sunset.org 请求拼装器（独立域名，免 Key）。
enum SunriseSunsetEndpoint {

    /// 独立基础地址。
    static let baseURLString = "https://api.sunrise-sunset.org/json"

    /// 拼装请求 URL（date 默认 today；formatted=0 让时间以 ISO8601 绝对时刻返回）。
    ///
    /// - Returns: 失败返回 nil（由调用方收敛为 `WeatherError.badURL`）。
    static func url(latitude: Double, longitude: Double, date: String = "today") -> URL? {
        var components = URLComponents(string: baseURLString)
        components?.queryItems = [
            URLQueryItem(name: "lat", value: String(latitude)),
            URLQueryItem(name: "lng", value: String(longitude)),
            URLQueryItem(name: "date", value: date),
            URLQueryItem(name: "formatted", value: "0")
        ]
        return components?.url
    }
}

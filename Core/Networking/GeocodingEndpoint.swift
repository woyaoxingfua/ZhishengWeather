//
//  GeocodingEndpoint.swift
//  Core / Networking  [App + Widget 共用]
//
//  F-B：Open-Meteo geocoding 搜索请求 URL 拼装。
//  与 `OpenMeteoEndpoint` 同风格：静态、纯函数、失败返 nil。
//
//  说明：
//  - name 走 URLComponents 自动百分号编码（中文安全）；
//  - name 为空白（纯空格/换行）时返回 nil（由调用方收敛为 WeatherError.badURL）；
//  - 显式 format=json（服务端默认即 json，写死防策略漂移）。
//

import Foundation

/// Open-Meteo geocoding 请求地址拼装器。
enum GeocodingEndpoint {

    /// 基础地址。
    static let baseURLString = "https://geocoding-api.open-meteo.com/v1/search"

    /// 依据城市名拼装搜索 URL。
    /// - Parameters:
    ///   - name: 城市名（中文安全，自动百分号编码）；首尾空白会被修剪。
    ///   - count: 返回条数上限（默认 10）。
    ///   - language: 结果语言（默认中文）。
    /// - Returns: 请求 URL；name 为空白或拼装失败时为 nil。
    static func url(name: String, count: Int = 10, language: String = "zh") -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components = URLComponents(string: baseURLString)
        components?.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "format", value: "json")
        ]
        return components?.url
    }
}

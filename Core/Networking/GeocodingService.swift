//
//  GeocodingService.swift
//  Core / Networking  [App + Widget 共用]
//
//  F-B：geocoding 搜索的 actor 实现。
//  与 `WeatherService` 同构：session 注入、坏 URL/badStatus/network/decoding 四收敛。
//

import Foundation

/// 基于 Open-Meteo geocoding 的搜索实现。
actor GeocodingService: GeocodingProviding {

    private let session: URLSession

    /// 初始化。
    /// - Parameter session: 可注入的 URLSession（测试可传自定义 configuration）。
    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 按城市名搜索候选城市；所有失败路径收敛为 `WeatherError`。
    /// - Parameter name: 城市名。
    /// - Returns: 候选城市数组（无命中为空数组）。
    /// - Throws: `WeatherError`。
    func search(name: String) async throws -> [City] {
        guard let url = GeocodingEndpoint.url(name: name) else {
            throw WeatherError.badURL
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw WeatherError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw WeatherError.network("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WeatherError.badStatus(http.statusCode)
        }

        let dto: GeocodingResponse
        do {
            dto = try JSONDecoder().decode(GeocodingResponse.self, from: data)
        } catch {
            throw WeatherError.decoding(error.localizedDescription)
        }

        return GeocodingMapper.cities(from: dto)
    }
}

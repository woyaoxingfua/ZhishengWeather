//
//  ArchiveProviding.swift
//  Core / Networking  [App + Widget 共用]
//
//  历史天气第三链路（A3-1）：协议 + actor 实现，镜像 AirQualityService。
//  日期参数由调用方计算（Core 禁 Date()——VM 层用注入的 now 推导近 7 日）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / try! / fatalError。
//

import Foundation

/// 历史天气取数协议（测试注入 Stub 用）。
protocol ArchiveProviding: Sendable {
    /// 取回 [startDate, endDate] 闭区间（含两端）的历史逐日序列。
    /// 日期格式 `yyyy-MM-dd`；所有失败路径收敛为 `WeatherError`。
    func fetch(latitude: Double, longitude: Double,
               startDate: String, endDate: String) async throws -> HistoricalWeather
}

/// 基于 Open-Meteo Archive API 的取数实现。
actor ArchiveService: ArchiveProviding {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(latitude: Double, longitude: Double,
               startDate: String, endDate: String) async throws -> HistoricalWeather {
        guard let url = ArchiveEndpoint.url(latitude: latitude, longitude: longitude,
                                            startDate: startDate, endDate: endDate) else {
            throw WeatherError.badURL
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw WeatherError.timeout(urlError.localizedDescription)
        } catch {
            throw WeatherError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw WeatherError.network("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WeatherError.badStatus(http.statusCode)
        }

        // 统一解码入口：失败携带 codingPath（可诊断性修复）。
        let dto = try ResponseDecoding.decode(ArchiveResponse.self, from: data)

        return ArchiveMapper.map(dto)
    }
}

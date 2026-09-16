//
//  AirQualityProviding.swift
//  Core / Networking  [App + Widget 共用]
//
//  空气质量第二链路（A2-1）：协议 + actor 实现，镜像 `WeatherProviding` /
//  `WeatherService` 的结构。与主天气链路（`api.open-meteo.com`）物理分离，
//  走独立域名 `air-quality-api.open-meteo.com` —— R5 双向失败隔离的物理基础。
//
//  错误收敛：全部失败路径抛 `WeatherError`（复用既有错误类型，VM 的
//  `loadAir` catch 只置 `airQuality = nil`，绝不触碰天气 `state`）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / try! / fatalError。
//

import Foundation

/// 空气质量取数协议（测试注入 Stub 用）。
protocol AirQualityProviding: Sendable {
    /// 取回一次空气质量领域模型；所有失败路径收敛为 `WeatherError`。
    func fetch(latitude: Double, longitude: Double) async throws -> AirQuality
}

/// 基于 Open-Meteo Air Quality API 的取数实现。
actor AirQualityService: AirQualityProviding {

    private let session: URLSession

    /// 初始化。
    /// - Parameter session: 可注入的 URLSession（测试传自定义 configuration）。
    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 取回空气质量；所有失败路径收敛为 `WeatherError`。
    func fetch(latitude: Double, longitude: Double) async throws -> AirQuality {
        guard let url = AirQualityEndpoint.url(latitude: latitude, longitude: longitude) else {
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
        let dto = try ResponseDecoding.decode(AirQualityResponse.self, from: data)

        return AirQualityMapper.map(dto)
    }
}

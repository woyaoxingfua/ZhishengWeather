//
//  EnsembleProviding.swift
//  Core / Networking  [App + Widget 共用]
//
//  集合预报第三链路（独立域名 `ensemble-api.open-meteo.com`）：协议 + actor 实现，
//  镜像 `WeatherProviding` / `AirQualityProviding`。与主天气链路物理分离，且与
//  空气链路并列——VM 侧三条链路各自独立 Task、独立槽位、双向失败隔离。
//
//  额度纪律（PRD §4.1）：本调用**等价 4.0 次**日额度，故：
//   - 由 VM 侧以**独立慢节奏**（3 小时）触发，**不随 15 分钟主循环刷新**；
//   - 服务本身只做「一次取数」，不自行重试、不做定时器。
//
//  错误收敛：全部失败路径抛 `WeatherError`（复用既有错误类型）。VM 的
//  `loadEnsemble` catch 只置 `ensemble = nil`，**绝不触碰天气 `state`**。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / try! / fatalError。
//

import Foundation

/// 集合预报取数协议（测试注入 Stub 用）。
protocol EnsembleProviding: Sendable {
    /// 取回一次集合预报领域模型；所有失败路径收敛为 `WeatherError`。
    func fetch(latitude: Double, longitude: Double) async throws -> EnsembleForecast
}

/// 基于 Open-Meteo Ensemble API 的取数实现。
actor EnsembleService: EnsembleProviding {

    private let session: URLSession

    /// 初始化。
    /// - Parameter session: 可注入的 URLSession（测试传自定义 configuration）。
    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 取回集合预报；所有失败路径收敛为 `WeatherError`。
    func fetch(latitude: Double, longitude: Double) async throws -> EnsembleForecast {
        guard let url = EnsembleEndpoint.url(latitude: latitude, longitude: longitude) else {
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

        let dto: EnsembleResponse
        do {
            dto = try JSONDecoder().decode(EnsembleResponse.self, from: data)
        } catch {
            throw WeatherError.decoding(error.localizedDescription)
        }

        return EnsembleMapper.map(dto)
    }
}

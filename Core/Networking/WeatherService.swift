//
//  WeatherService.swift
//  Core / Networking  [App + Widget 共用]
//
//  actor：URLSession + async 取数 → 解码 → 映射 → 抛 WeatherError。
//  `now` 以闭包注入（默认 `Date.init`），保证截窗可测。
//
//  本轮改造（可诊断性）：
//   - 超时从「网络失败」中**细分**（`WeatherError.timeout`）；
//   - 解码走统一的 `ResponseDecoding`（**携带 codingPath**，run37 事故修复）；
//   - 响应结构性为空（无逐小时且无逐日）→ `WeatherError.dataMissing`。
//   其余流程与语义逐行保留。
//

import Foundation

/// 基于 Open-Meteo 的取数实现。
actor WeatherService: WeatherProviding {

    private let session: URLSession
    private let now: @Sendable () -> Date

    /// 初始化。
    /// - Parameters:
    ///   - session: 可注入的 URLSession（测试可传自定义 configuration）。
    ///   - now: 当前时刻提供者；默认 `Date.init`，测试可注入固定时刻。
    init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session
        self.now = now
    }

    /// 取回一次天气快照；所有失败路径收敛为 `WeatherError`。
    func fetch(latitude: Double, longitude: Double) async throws -> WeatherSnapshot {
        guard let url = OpenMeteoEndpoint.url(latitude: latitude, longitude: longitude) else {
            throw WeatherError.badURL
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let urlError as URLError where urlError.code == .timedOut {
            // 超时单列：与「连不上」的处置文案不同（见 FaultDomain）。
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

        // 统一解码入口：失败时携带 codingPath + debugDescription（且写 os.Logger）。
        let dto = try ResponseDecoding.decode(OpenMeteoResponse.self, from: data)

        // 服务层只知坐标；城市名由上层 VM 覆盖（快照的 location 为可变属性）。
        let location = LocationInfo(name: "当前位置",
                                    latitude: latitude,
                                    longitude: longitude,
                                    isFallback: false)
        let snapshot = OpenMeteoMapper.map(dto, location: location, now: now())

        // 结构性为空（无逐小时且无逐日）→ 该坐标无预报数据，不冒充成功。
        guard !SnapshotCompleteness.isEffectivelyEmpty(snapshot) else {
            throw WeatherError.dataMissing("坐标 \(latitude),\(longitude)")
        }
        return snapshot
    }
}

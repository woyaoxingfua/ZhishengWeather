//
//  FloodProviding.swift
//  Core / Networking  [App + Widget 共用]
//
//  第五源取数：协议 + actor 实现，镜像 `MarineProviding` 的形状
//  （同为"独立链路 + 独立领域模型"，故同取 `…Providing` 而非
//  `FieldSupplying`：河道流量**不在** `WeatherFieldKey` 域内，
//  塞进 `FieldPatch` 只会逼出一个假字段 —— 见 `SourceCapability` 注释）。
//
//  ── 失败隔离 ─────────────────────────────────────────────────────────
//  与 marine 同纪律：全部失败路径抛 `WeatherError`（复用既有错误类型），
//  调用方 catch 后只置本槽位、不 rethrow、不连累主天气链路（R5）。
//  非 2xx → `.badStatus(code)`（EV-3 据此裁定冷却 / 会话摘除）。
//
//  ── ⚠️ 本源**没有坐标判据**（与 marine 相反，有实测依据）────────────
//  实测内陆城市 flood **照样有值**：北京 (39.9,116.4) → `[5.07, 5.05, ...]`、
//  拉萨 (29.65,91.1) → `[0.24, 0.17, 0.15]`。河道流量对内陆城市同样有意义，
//  按"是否沿海"过滤会**错杀真实数据**。故 flood 对任何坐标都发请求，
//  由响应后的 `RiverDischarge.isEffectivelyEmpty` 决定"有没有可展示的读数"。
//
//  「这个坐标没有河道数据」不是**故障**而是**正常业务结果**，故回空模型、
//  **不**抛错 —— 与 marine 的同一决策，且理由相同（详见 MarineProviding 注释）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / try! / fatalError。
//

import Foundation

/// 河道流量取数协议（测试注入Stub 用）。
protocol FloodProviding: Sendable {
    /// 取回一次河道流量领域模型；所有**真故障**路径收敛为 `WeatherError`。
    ///
    /// - Note: 无有效数据时**不**抛错，返回 `isEffectivelyEmpty == true`
    ///   的空模型（见类型注释）。
    func fetch(latitude: Double, longitude: Double) async throws -> RiverDischarge
}

/// 基于 Open-Meteo Flood API 的取数实现。
actor FloodService: FloodProviding {

    private let session: URLSession

    /// 初始化。
    /// - Parameter session: 可注入的 URLSession（测试传自定义 configuration）。
    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 取回河道流量；所有**真故障**路径收敛为 `WeatherError`。
    func fetch(latitude: Double, longitude: Double) async throws -> RiverDischarge {
        guard let url = FloodEndpoint.url(latitude: latitude, longitude: longitude) else {
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

        // 统一解码入口：失败携带 codingPath（可诊断性）。
        let dto = try ResponseDecoding.decode(FloodResponse.self, from: data)

        // ⚠️ **请求坐标必须原样传入**（本服务已持有，无需再查一次）：
        // mapper 要用它与响应**回显**的网格中心算距离，填错会让「数据取自
        // 距你约 N km 的网格点」显示成错误值（比不显示更糟）。
        // mapper 逐元素判非空：全null → 空序列（不冒充"断流 0"）。
        return FloodMapper.map(dto,
                               requestedLatitude: latitude,
                               requestedLongitude: longitude)
    }
}
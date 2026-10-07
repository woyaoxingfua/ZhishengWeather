//
//  MarineProviding.swift
//  Core / Networking  [App + Widget 共用]
//
//  第四源取数：协议 + actor 实现，镜像 `AirQualityProviding` 的形状
//  （海浪与空气同为"独立链路 + 独立领域模型"，故取同一形状而非
//  `FieldSupplying`：海浪要素**不在** `WeatherFieldKey` 域内，
//  塞进 `FieldPatch` 只会逼出一个假字段 —— 宁可单列，见
//  `SourceCapability` 注释里已就 `.basicNumericFields` 立过的纪律）。
//
//  ── 失败隔离 ─────────────────────────────────────────────────────────
//  全部失败路径抛 `WeatherError`（复用既有错误类型），调用方 catch 后
//  只置本槽位、不 rethrow、不连累主天气链路（R5 双向失败隔离）。
//  · 非 2xx → `.badStatus(code)`（供 EV-3 裁定冷却 / 会话摘除）；
//  · 网络失败 → `.network` / `.timeout`（沿用既有二分）。
//
//  ── ⚠️ 坐标判据在这里生效（`requestEligibility`）─────────────────────
//  内陆坐标**不联网**：直接回 `MarineConditions.empty`，**不抛错**。
//  为什么不是抛 `WeatherError.dataMissing`：
//  「这个城市没有海浪」是**正常的业务结果**，不是故障 —— 抛错会让上层
//  把它记成一次失败（污染链路健康度、可能触发不必要的降级提示）。
//  既有先例：`WeatherService` 对"结构性为空"抛 `dataMissing`，
//  但那是因为**天气快照缺失确实是故障**；海浪在内陆城市本就没有，
//  两者性质不同，故此处回空模型而不抛错。
//  这也与 marine 的实测行为一致：对内陆坐标它自己回的是 **200 + 全 null**
//  （不是 404），即服务端也把"内陆无浪"当成一次正常应答。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / try! / fatalError。
//

import Foundation

/// 海浪取数协议（测试注入 Stub 用）。
protocol MarineProviding: Sendable {
    /// 取回一次海浪领域模型；所有**真故障**路径收敛为 `WeatherError`。
    ///
    /// - Note: 内陆坐标（判据不通过）**不**抛错，返回
    ///   `isEffectivelyEmpty == true` 的空模型（见类型注释）。
    /// - Returns: 海浪领域模型 + **同一次请求**顺带回的潮汐序列。
    ///
    /// ⚠️ 潮汐与浪况**共用一次 HTTP 请求**（实测：同一响应体里
    ///   `current` 与 `minutely_15` 两块共存），故它挂在返回值里而**不是**
    ///   另开一条链路 —— 另开就是第二次请求、多一次配额，违背"零成本扩展"。
    func fetch(latitude: Double,
               longitude: Double) async throws -> (wave: MarineConditions, tide: TideForecast)
}

/// 基于 Open-Meteo Marine API 的取数实现。
actor MarineService: MarineProviding {

    private let session: URLSession

    /// 初始化。
    /// - Parameter session: 可注入的 URLSession（测试传自定义 configuration）。
    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 取回海浪要素；所有**真故障**路径收敛为 `WeatherError`。
    func fetch(latitude: Double,
               longitude: Double) async throws -> (wave: MarineConditions, tide: TideForecast) {
        // 坐标判据：**不联网**地挡掉内陆坐标（省配额，且不给用户空卡片）。
        // 判据刻意保守 —— 放行不代表有数据，权威判据在响应后的
        // `MarineConditions.isEffectivelyEmpty` / `TideForecast.isEffectivelyEmpty`
        // （见 MarineEndpoint 类型注释）。
        // ⚠️ 实测依据：潮汐的 null 分布与浪况**逐点一致**（沿海有值、内陆全 null），
        //   故**同一个判据**同时管两者，不另造第二套"沿海"定义。
        guard MarineEndpoint.requestEligibility(latitude: latitude,
                                                longitude: longitude) else {
            return (.empty, .empty)
        }

        guard let url = MarineEndpoint.url(latitude: latitude, longitude: longitude) else {
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
        let dto = try ResponseDecoding.decode(MarineConditionsResponse.self, from: data)

        // mapper 逐字段判非空：全 null → empty（不冒充"浪高 0"）。
        // ⚠️ 两个映射**各自独立**：浪况块缺失不该连累潮汐块，反之亦然
        //（实测内陆城市是**两块同时**全 null，但那是服务端行为，不是可依赖的契约）。
        let wave = MarineMapper.map(dto)
        let tide = MarineMapper.mapTide(dto.minutely_15,
                                        utcOffsetSeconds: dto.utc_offset_seconds)
        return (wave, tide)
    }
}
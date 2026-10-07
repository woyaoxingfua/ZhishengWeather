//
//  NmcTyphoonProviding.swift
//  Core / Networking  [App + Widget 共用]
//
//  第七源取数：协议 + actor 实现，形状镜像 `NmcAlarmProviding`
//（台风与预警同为「独立链路 + 独立领域模型 + 列表型」，故取同款形状而非
//  `FieldSupplying`：台风**不在** `WeatherFieldKey` 域内，且它是**列表**，
//  塞进 `FieldPatch` 只会逼出一个假字段 —— 同 `SourceCapability` 注释里
//  已就`.officialWarning` 立过的纪律）。
//
//  ── 🔴 失败隔离 ───────────────────────────────────────────────────
//  与 `NmcAlarmProviding` 同款：全部失败路径抛 `WeatherError`，
//  调用方 catch 后只置本槽位、不 rethrow、不连累主天气链路。
//   · 非 2xx → `.badStatus(code)`。⚠️ 实测错误 id 返回 **404 + HTML**，
//     故**状态码检查必须排在剥壳之前**：否则 404 的 HTML 会以
//     「解码失败」的面貌出现，把「台风不存在」误报成「数据格式变了」。
//   · 网络失败 → `.network` / `.timeout`（沿用既有二分）。
//
//  ── ⚠️ **返回空数组 ≠ 成功**（与预警源同款契约）────────────────────
//  `fetchSummaries()` 返回 `[]` 只表示「HTTP 2xx + 解码成功 + 上游当前
//  **没有活跃台风**」；任何故障都**抛错**。
//  为什么必须这样切分：调用方要用「成功但为空」与「失败」区分
//  `.none`（真的没台风 → 显示「当前无活跃台风」）与
//  `.unavailable`（取不到 → **显式告知**）。
//  ⚠️ 尤其对台风：**「没有台风」是常态**（实测一年里多数时段无活跃台风），
//  把它与「取不到」混为一谈，会在台风季最需要的时候显示「无活跃台风」——
//  那是一条**内容错误**，且用户无从分辨。
//
//  ── 不做本地缓存 ──────────────────────────────────────────────────
//  实测上游数据本身约**3 小时量级延迟**（实测末点 UTC `202610070600`
//  = 北京时间 14:00，而请求时刻约北京时间 17:00）。
//  故本层**不缓存**：调用方按需刷新即可，缓存策略由 UI 层的刷新节律决定。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 台风取数协议（测试注入 Stub 用）。
protocol NmcTyphoonProviding: Sendable {

    /// 取回**默认列表**（实测含当前年全部台风，**含已停止**）。
    ///
    /// - Note: 空数组 = 取数成功且确实没有台风；**故障一律抛 `WeatherError`**。
    func fetchSummaries() async throws -> [TyphoonSummary]

    /// 取回**指定年份**的台风列表（实测可回溯到 1950）。
    ///
    /// - Parameter year: 年份。
    /// - Note: 同上；**该年无台风**时返回 `[]`（实测 `list_1950` 42 条全为 `"stop"`，
    ///   但列表本身非空 —— 故 `[]` 只在解码失败被上游清空时出现）。
    func fetchSummaries(year: Int) async throws -> [TyphoonSummary]

    /// 取回单个台风的完整路径 + 官方预报。
    ///
    /// - Parameter id: 台风 id。
    /// - Note: 结构不符 → 返回 nil；**故障抛 `WeatherError`**。
    func fetchTrack(id: String) async throws -> TyphoonTrack?
}

/// 基于中央气象台台风网公开接口的取数实现。
actor NmcTyphoonService: NmcTyphoonProviding {

    private let session: URLSession

    /// 初始化。
    /// - Parameter session: 可注入的 `URLSession`（测试传带 `URLProtocol` 桩的配置）。
    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 取默认列表。
    func fetchSummaries() async throws -> [TyphoonSummary] {
        guard let url = NmcTyphoonEndpoint.defaultListURL() else {
            throw WeatherError.badURL
        }
        return try await fetchSummaries(from: url)
    }

    /// 取指定年份列表。
    func fetchSummaries(year: Int) async throws -> [TyphoonSummary] {
        guard let url = NmcTyphoonEndpoint.yearListURL(year: year) else {
            throw WeatherError.badURL
        }
        return try await fetchSummaries(from: url)
    }

    /// 取单个台风路径 + 预报。
    func fetchTrack(id: String) async throws -> TyphoonTrack? {
        guard let url = NmcTyphoonEndpoint.trackURL(id: id) else {
            throw WeatherError.badURL
        }
        let response = try await fetchData(from: url)
        // ⚠️ 剥壳在状态码检查**之后**（实测 404 是 HTML，不是 JSONP）。
        let dto = try ResponseDecoding.decode(NmcTyphoonResponse.self,
                                              from: NmcTyphoonJSONP.unwrap(response))
        return NmcTyphoonMapper.track(from: dto)
    }

    // MARK: - 内部

    /// 列表端点的共用取数 + 映射。
    private func fetchSummaries(from url: URL) async throws -> [TyphoonSummary] {
        let data = try await fetchData(from: url)
        let dto = try ResponseDecoding.decode(NmcTyphoonResponse.self,
                                              from: NmcTyphoonJSONP.unwrap(data))
        return NmcTyphoonMapper.summaries(from: dto)
    }

    /// 请求 + **先判状态码**再返回字节。
    ///
    /// ⚠️ 顺序是硬要求：实测 `view_9999999` / `list_2030` 返回
    /// **404 + `text/html`**，若先剥壳会把「台风不存在」报成
    /// 「JSON 解码失败」—— 两者对用户的处置完全不同。
    private func fetchData(from url: URL) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            // ⚠️ 实测免Referer、无需凭据、无需特定 UA → 用最简请求。
            // ⚠️ 必须走 `.data(from:)`（它内部跟随 301/302）；本机若只测到
            // 301 空壳那是 curl 没带 `-L`，与端点无关。
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
            // EV-3：非 2xx 透传状态码（供健康账本裁定冷却 / 会话摘除）。
            throw WeatherError.badStatus(http.statusCode)
        }
        return data
    }
}
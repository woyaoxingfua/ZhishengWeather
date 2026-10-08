//
//  UsgsEarthquakeProviding.swift
//  Core / Networking  [App + Widget 共用]
//
//  第九源取数：协议 + actor 实现，形状镜像 `NmcTyphoonProviding`
//  （同为「独立链路 + 独立领域模型 + 列表型」，故取同款形状而非
//  `FieldSupplying`：地震要素**不在** `WeatherFieldKey` 域内，
//  且它是**列表**，塞进 `FieldPatch` 只会逼出一个假字段 —— 同
//  `SourceCapability` 注释里已就 `.officialWarning` / `.typhoonTrack`
//  立过的纪律）。
//
//  ── 🔴 失败隔离 ───────────────────────────────────────────────────────
//  与 typhoon / flood 同款：全部失败路径抛 `WeatherError`，
//  调用方 catch 后只置本槽位、不 rethrow、不连累主天气链路（R5）。
//   · 非 2xx → `.badStatus(code)`。
//   · 网络失败 → `.network` / `.timeout`（沿用既有二分）。
//
//  ── ⚠️ **先判 content-type，再决定是否 JSONDecode** ───────────────────
//  本仓已有纪律：有的源在错误时会返回 **HTML 错误页**
//  （台风源实测 `404` + `text/html`，逐字以 `<!DOCTYPE HTML` 开头）。
//  本端点在实测中错误参数也可能返回**非 JSON** 正文。
//  故本实现**先判 `Content-Type` 是否含 `json`**：
//  · 是 → 走 `ResponseDecoding.decode`（失败携带 codingPath，可诊断）；
//  · 否 → 抛 `.dataMissing` 并**带上正文前若干字节**，
//    让「上游返回了 HTML / 纯文本」这件事**在错误里可见**
//    —— 否则用户看到的是「天气数据结构与预期不符（可能是接口变更）」，
//    而真实原因是「服务端返回了一个错误页」。归因完全错误。
//
//  ⚠️ **注意**：本源**不能**学`SevenTimerService` 的「先判正文」那套 ——
//  7timer 的错误正文是纯文本 `ERR: ...`（实测），而本端点的
//  `format=geojson` 正常响应本身就是 JSON；用「正文像不像 JSON」当判据
//  在本源是**多余的一层猜测**，而 content-type 是**服务端给的显式声明**。
//
//  ── ⚠️ **返回空数组 ≠ 成功**（与台风源同款契约）────────────────────────
//  `fetchNearbyEvents(...)` 返回 `events.isEmpty` 只表示
//  「HTTP 2xx + 解码成功 + 上游**当前确实没有**附近地震」；
//  任何故障都**抛错**。
//  ⚠️ 这条对地震源尤其重要：实测北京 300km / 30 天 / M2.5+ 就是
//  **0 条**（主理人已确认是**真的没地震**，不是参数写错）。
//  把「取不到」显示成「附近没地震」是**内容错误** ——
//  用户会在最需要知道「有没有震」的时候看到一句「附近没有地震」。
//
//  ── 🔴 `startDate` **注入**（Core 内禁 `Date()`）────────────────────
//  见 `UsgsEarthquakeEndpoint` 文件头与静态门禁 SC-11：
//  查询起始时刻由 **App 层**取当前时间后注入，Core 只负责按 UTC 日期格式化。
//
//  ── 不做本地缓存 ──────────────────────────────────────────────────────
//  地震是**低频事件**，且「附近有没有震」必须**当下**准确
//  （缓存会让用户看到已经过去的震情）。故本层**不缓存**，
//  由 UI 层随城市切换 / 下拉刷新重取。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 地震取数协议（测试注入 Stub 用）。
protocol UsgsEarthquakeProviding: Sendable {

    /// 取回一次「附近地震」领域模型；所有**真故障**路径收敛为 `WeatherError`。
    ///
    /// - Parameters:
    ///   - latitude: 观测点纬度（WGS84；**由调用方从既有真源取**，本协议不查城市）。
    ///   - longitude: 观测点经度（WGS84）。
    ///   - startDate: 查询起始时刻（**注入**；Core 内不取时钟）。
    /// - Note: 无附近地震时**不**抛错，返回 `isEffectivelyEmpty == true`
    ///   的空 feed（见类型注释）。**故障一律抛 `WeatherError`**。
    func fetchNearbyEvents(latitude: Double,
                           longitude: Double,
                           startDate: Date) async throws -> EarthquakeFeed
}

/// 基于 USGS FDSN Event Web Service 的取数实现。
actor UsgsEarthquakeService: UsgsEarthquakeProviding {

    /// 非 JSON 响应时，错误里带上正文的前若干字节（够看清是 HTML 还是纯文本）。
    ///
    /// 取 128字节：足够包含 `<!DOCTYPE HTML …>` 或 `ERR: …` 这类前缀，
    /// 又不至于把整个响应体塞进日志。
    private static let errorBodyPreviewByteCount = 128

    private let session: URLSession

    /// 初始化。
    /// - Parameter session: 可注入的 `URLSession`（测试传带 `URLProtocol` 桩的配置）。
    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 取回附近地震。
    func fetchNearbyEvents(latitude: Double,
                           longitude: Double,
                           startDate: Date) async throws -> EarthquakeFeed {
        guard let url = UsgsEarthquakeEndpoint.url(latitude: latitude,
                                                    longitude: longitude,
                                                    startDate: startDate) else {
            throw WeatherError.badURL
        }

        let data: Data
        let response: URLResponse
        do {
            // ⚠️ 实测免 Key / 免注册 / 无需 Referer、无需特定 UA → 用最简请求。
            (data, response) = try await session.data(from: url)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw WeatherError.timeout(urlError.localizedDescription)
        } catch {
            throw WeatherError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw WeatherError.network("非 HTTP 响应")
        }
        // 🔴 **状态码先于内容判别**：否则 4xx/5xx 的 HTML 正文会以
        // 「解码失败」的面貌出现，把「服务端报错」误报成「接口结构变了」。
        guard (200..<300).contains(http.statusCode) else {
            // EV-3：非 2xx 透传状态码（供健康账本裁定冷却 / 会话摘除）。
            throw WeatherError.badStatus(http.statusCode)
        }

        // ⚠️ **先判 content-type，再决定是否解码**（理由见文件头）。
        // content-type 缺失时**不**直接失败 —— 部分代理会剥掉该头，
        // 那时宁可尝试解码（失败会得到带 codingPath 的 decodingDetail，
        // 比「因为没有头就报错」更有诊断价值）。
        if let contentType = http.value(forHTTPHeaderField: "Content-Type"),
           !contentType.lowercased().contains("json") {
            throw WeatherError.dataMissing(Self.describeNonJSONBody(data, statusCode: http.statusCode))
        }

        // 统一解码入口（失败携带 codingPath，可诊断）。
        let dto = try ResponseDecoding.decode(UsgsEarthquakeResponse.self, from: data)

        // mapper 逐条判必填项；一条坏 feature 只丢自己。
        return UsgsEarthquakeMapper.map(dto,
                                       originLatitude: latitude,
                                       originLongitude: longitude)
    }

    // MARK: - Private

    /// 非 JSON 正文 → 用户/日志可读的说明（**带上正文前缀**）。
    ///
    /// ⚠️ 正文可能是 HTML 错误页，也可能是纯文本；
    /// 截断到前 128 字节并**去掉换行**（避免错误信息把日志撑成多行）。
    private static func describeNonJSONBody(_ data: Data, statusCode: Int) -> String {
        let prefix = data.prefix(errorBodyPreviewByteCount)
        let text = String(data: prefix, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "无法解析为文本"
        return "USGS 返回非JSON 内容（HTTP \(statusCode)，"
            + "Content-Type 不是 json）：\(text)"
    }
}
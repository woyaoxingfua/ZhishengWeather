//
//  QWeatherProviding.swift
//  Core / Networking  [App + Widget 共用]
//
//  第九源「和风天气」取数：协议 + actor 实现，形状镜像 `FloodProviding`。
//
//  ══════════════════════════════════════════════════════════════════════════
//  实测基准：2026-10-08（主理人用真实凭据在本机打通全链路）
//  实测结论（逐字，见 `QWeatherCredentials` 文件头）：
//  · 不带 Authorization → HTTP 401；带正确 JWT → HTTP 200
//  · 端点 `/weather/v1/daily/{lat}/{lon}?days=N`（不是 `/v7/…`）
//  · `humidity` / `cloudCover` / `probability` 是 `[0,1]`（实测 0.32 / 0）
//
//  ── 🔴 逐时实测补记（2026-10-09，`?hours=24` → **HTTP 200**）────────────
//  · 端点 `/weather/v1/hourly/{lat}/{lon}?hours=N`（**路径段是 `hourly`**）；
//  · 🔴🔴 但**响应顶层键逐字是 `hours`** —— 两者不是同一个词。写错**不报错**，
//    只会让整源静默变成「无数据」（详见 `QWeatherHourlyResponse` 文件头）；
//  · 逐时 `humidity = 0.33` / `cloudCover = 0` → **与逐日同一量纲 `[0,1]`**
//    → mapper 复用同一套 `unitFraction` 净化，**不另立口径**。
// ══════════════════════════════════════════════════════════════════════════
//
//  ── 🔴 凭据从哪来（Core 不读凭据，`SC-42a` 硬门禁）────────────────────
//  Core **不**读 UserDefaults / Keychain / 任何存储（`SC-42a` 静态门禁会扫）。
//  故 `credentials` 由**App 侧**读取后**注入**本actor。
//  凭据缺失 → 每次调用抛 `WeatherError.dataMissing`
//  → 上层显示「未配置 API 凭据」，**绝不静默换源、绝不伪造数据**。
//
//  ── 🔴 401 与 403 必须**可区分**（不是一律当网络错）────────────────────
//  实测 Host 错误 / 签名不对 / token 过期，**都**表现为 401 或 403，
//  但处置完全不同：
//  · 401 → token 可能过期 → 下一轮会重签（可自愈）
//  · 403 → Host 不对 / 权限不足 → **重签也没用**，要让用户改配置
//  → 故本文件把它们**分别**收敛为带不同说明的 `WeatherError.badStatus`，
//    而**不**统一压成 `network(...)`（那是把「需要改配置」说成「网不好」）。
//
//  ── ⚠️ 错误响应**不保证是 JSON**（本仓既有纪律）──────────────────────
//  和风的鉴权失败可能返回**非 JSON**（实测历史博客记录过 Tomcat 风格 HTML 400）。
//  → 故状态码判定**在解码之前**，且解码失败时不把原始字节当消息抛出
//    （那会把 HTML 整页塞进用户界面）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 和风天气取数协议（测试注入Stub 用）。
protocol QWeatherProviding: Sendable {

    /// 取回逐日预报；所有**真故障**路径收敛为 `WeatherError`。
    ///
    /// - Note: **凭据缺失也走抛错**（`WeatherError.dataMissing`），
    ///   不返回空模型 —— 与「真的没有数据」必须区分（纪律同本仓其他源）。
    func fetchDaily(latitude: Double,
                    longitude: Double,
                    days: Int) async throws -> QWeatherDailyForecast

    /// 取回逐时预报；所有**真故障**路径收敛为 `WeatherError`。
    ///
    /// 🔴 **实测基准 2026-10-09**：`/weather/v1/hourly/{lat}/{lon}?hours=24`
    /// 带正确 JWT → **HTTP 200**，响应顶层键逐字是 **`hours`**。
    ///
    /// - Note: 与 `fetchDaily` 同款纪律 —— 凭据缺失抛 `dataMissing`，
    ///   **不**返回空模型（「没配置」与「真的没数据」必须可区分）。
    func fetchHourly(latitude: Double,
                     longitude: Double,
                     hours: Int) async throws -> QWeatherHourlyForecast

    /// 取回坐标反查结果（**能拿到的最细粒度行政区**）。
    ///
    /// 🔴⚠️ **本端点未实测**（2026-10-08 实测该 Host 下 `/geo/v2/city/lookup`
    ///    返回 **404 空响应体**；用故意错误的 token 则 401 → 路由存在，
    ///    Host / 订阅侧有问题）。真机行为**未经验证**，接入后必须核验。
    ///
    /// ⚠️ 坐标顺序由**实现内部**按官方规格处理（`location={经度},{纬度}`），
    ///   **调用方仍传 `latitude:` / `longitude:` 两个独立参数** ——
    ///   绝不把「经度在前」这件事泄漏成调用方的责任：
    ///   参数名与类型已经说明了各自是什么，比一个位置敏感的双重参数安全。
    ///
    /// - Note: 与 `fetchDaily` / `fetchHourly` 同款纪律 —— 凭据缺失抛
    ///   `dataMissing`，**不**返回空模型（「没配置」与「真的查不到」必须可区分）。
    func fetchCityLookup(latitude: Double,
                         longitude: Double,
                         number: Int) async throws -> QWeatherResolvedPlaces
}

/// 基于和风天气 Web API 的取数实现。
actor QWeatherService: QWeatherProviding {

    private let session: URLSession
    private let credentials: QWeatherCredentials?
    private let signer: any QWeatherTokenSigning

    /// 初始化。
    /// - Parameters:
    ///   - session: 可注入的 `URLSession`（测试传带 `URLProtocol` 桩的配置）。
    ///   - credentials: **由 App 侧注入**的凭据；`nil` = 未配置（每次调用抛错）。
    ///   - signer: JWT 签名器（测试可注入固定 token 的桩）。
    ///   - now: 取当前时刻的闭包。
    ///
    /// 🔴 **`now` 没有默认值**（2026-10-08 静态门禁 SC-11 实测教训）：
    ///   Core层**禁`Date()`** —— 默认参数 `{ Date() }` 写在 Core 里同样被扫到
    ///   （报 `SC-11 Core/ 内出现非注释 Date()`）。
    ///   故**由 App 侧显式传`Date()`**（App 层不在 SC-11 范围内）。
    ///   ⚠️ 上一轮我在这里留了 `= { Date() }`，门禁当场抓出来了 ——
    ///   这正是「静态门禁存在的意义」，比等到 CI 快一个数量级。
    init(session: URLSession = .shared,
         credentials: QWeatherCredentials? = nil,
         signer: (any QWeatherTokenSigning)? = nil,
         now: @escaping @Sendable () -> Date) {
        self.session = session
        self.credentials = credentials
        // `signer` 给了桩就用桩，没给就建真的（`QWeatherTokenSigner` 同样要 `now`）。
        self.signer = signer ?? QWeatherTokenSigner(now: now)
    }

    /// 取回逐日预报。
    func fetchDaily(latitude: Double,
                    longitude: Double,
                    days: Int) async throws -> QWeatherDailyForecast {
        // ① 凭据（先于 URL 拼装：没凭据时连URL 都拼不出来，报错更直接）。
        let token = try await resolveToken()
        let host = try apiHost()

        // ② URL（`days` 越界 → nil → `badURL`，**绝不**静默改成 7）。
        guard let url = QWeatherEndpoint.dailyURL(apiHost: host,
                                                   latitude: latitude,
                                                   longitude: longitude,
                                                   days: days) else {
            throw WeatherError.badURL
        }

        let data = try await performRequest(url: url, token: token)
        // ④ 解码（走统一入口，保留 codingPath 便于排障）。
        return QWeatherMapper.map(
            try ResponseDecoding.decode(QWeatherDailyResponse.self, from: data))
    }

    /// 取回逐时预报（**实测可用**：2026-10-09 `?hours=24` → HTTP 200）。
    ///
    /// 🔴 与 `fetchDaily` **完全同构**（同一 Host / 同一 Bearer JWT / 同一错误处置），
    ///    唯一差别是路径段`hourly` 与参数 `hours`，以及**响应顶层键是 `hours`**。
    ///    → 共享逻辑抽到 `resolveToken()` 与 `performRequest(url:token:)`，
    ///      避免两份鉴权/状态码处置**各自演化**（那正是本仓吃过亏的地方：
    ///      逐日与实况曾各写一遍 401 处置，措辞悄悄漂移）。
    func fetchHourly(latitude: Double,
                     longitude: Double,
                     hours: Int) async throws -> QWeatherHourlyForecast {
        // ① 凭据（同逐日：先于 URL 拼装）。
        let token = try await resolveToken()
        let host = try apiHost()

        // ② URL（`hours` 越界 → nil → `badURL`，**绝不**静默改成 24）。
        guard let url = QWeatherEndpoint.hourlyURL(apiHost: host,
                                                   latitude: latitude,
                                                   longitude: longitude,
                                                   hours: hours) else {
            throw WeatherError.badURL
        }

        let data = try await performRequest(url: url, token: token)
        // ④ 解码 → 映射（顶层键 `hours`，见 `QWeatherMapper.mapHourly`）。
        return QWeatherMapper.mapHourly(
            try ResponseDecoding.decode(QWeatherHourlyResponse.self, from: data))
    }

    /// 取回坐标反查结果（GeoAPI city lookup）。
    ///
    /// 🔴⚠️ **未实测**：2026-10-08 实测该 Host 下本端点 404 空响应体
    ///   （坏 token 则 401 → 路由存在，Host/订阅侧有问题）。
    ///   → 真机首次接入时**必须**核验响应结构（逐条对照
    ///     `QWeatherCityResponse.swift` 的字段注释）。
    ///
    /// ⚠️ 与前两条链路**完全同构**（同一 Host / 同一 Bearer JWT / 同一错误处置），
    ///   唯一差别是：坐标在**查询串**且顺序是**经度在前**，
    ///   以及响应顶层是 `location` + `refer`（**没有 `metadata`**）。
    ///   → 共享逻辑仍走 `resolveToken()` 与 `performRequest(url:token:)`。
    func fetchCityLookup(latitude: Double,
                         longitude: Double,
                         number: Int = QWeatherGeoEndpoint.defaultNumber) async throws -> QWeatherResolvedPlaces {
        // ① 凭据（同逐日 / 逐时：先于 URL 拼装，报错更直接）。
        let token = try await resolveToken()
        let host = try apiHost()

        // ② URL（`number` 越界 / 坐标非法 → nil → `badURL`，**绝不**静默改默认值）。
        guard let url = QWeatherGeoEndpoint.cityLookupURL(apiHost: host,
                                                          latitude: latitude,
                                                          longitude: longitude,
                                                          number: number) else {
            throw WeatherError.badURL
        }

        let data = try await performRequest(url: url, token: token)
        // ③ 解码 → 映射（顶层 `location` + `refer`，见 `QWeatherMapper.mapCityLookup`）。
        return QWeatherMapper.mapCityLookup(
            try ResponseDecoding.decode(QWeatherCityResponse.self, from: data))
    }

    // MARK: - Private

    /// 取回凭据并签出**当前有效**的 JWT（逐日/ 逐时共用）。
    ///
    /// - Returns: Bearer token。
    /// - Throws: `WeatherError.dataMissing`（未配置凭据）。
    private func resolveToken() async throws -> String {
        guard let credentials else {
            throw WeatherError.dataMissing("未配置和风天气凭据"
                + "（需要 API Host / Project ID / Credential ID / Ed25519 私钥）")
        }
        // 签名（内部含凭据完整性校验 + token 缓存/过期重签）。
        return try await signer.token(for: credentials)
    }

    /// 已配置凭据里的 API Host（逐日 / 逐时共用）。
    ///
    /// ⚠️ **独立于 `resolveToken()` 存在**是为了让两条链路的步骤顺序
    ///   **逐字一致**（① 凭据 → ② 签 token → ③ 取 Host → ④ 拼 URL），
    ///   免得读代码时要在一处里推断「Host 是在检查凭据前还是后取的」。
    ///
    /// - Returns: 控制台分配的专属 API Host。
    /// - Throws: `WeatherError.dataMissing`（未配置凭据）。
    private func apiHost() throws -> String {
        guard let credentials else {
            throw WeatherError.dataMissing("未配置和风天气凭据"
                + "（需要 API Host / Project ID / Credential ID / Ed25519 私钥）")
        }
        return credentials.apiHost
    }

    /// 发起请求并返回**已确认 2xx** 的响应体（逐日 / 逐时共用）。
    ///
    /// ⚠️ 状态码**先于解码**判定（实测 401/403 的响应体**不是**预报 JSON，
    ///   硬解会把 HTML 当 JSON 解析 → 报成「解码失败」，掩盖真正的鉴权问题）。
    ///
    /// - Parameters:
    ///   - url: 已拼装好的请求地址。
    ///   - token: Bearer JWT。
    /// - Returns: 2xx 响应体字节。
    private func performRequest(url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        // 🔴 官方现行鉴权是 **Bearer JWT**（**不是**老式的 `?key=xxx`）。
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw WeatherError.timeout(urlError.localizedDescription)
        } catch {
            throw WeatherError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw WeatherError.network("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.statusError(statusCode: http.statusCode)
        }
        return data
    }

    /// 状态码 → 错误（**只保留原始状态码**，说明文字另走`authenticationHint`）。
    ///
    /// ⚠️ 用 `WeatherError.badStatus(Int)`（**保留原始状态码**，
    /// 供健康账本与自动摘除判定），**不新造 case** ——
    /// 新造 case 会让上游所有 `switch WeatherError` 落到 `default`，
    /// 那是另一种静默行为变更（与 `SevenTimerResponse` 的教训同款）。
    ///
    /// ⚠️ 「人话说明」**不在这里拼进错误消息**：那会让同一状态码在不同
    /// 调用点产生不同文案（漂移）。统一由
    /// `QWeatherCardModel.describe` 依 `authenticationHint(statusCode:)`
    /// **二次渲染**，错误消息这一层保持**单一真源**。
    ///
    /// ⚠️ 状态码**先于解码**判定（实测 401/403 的响应体**不是**预报 JSON，
    /// 硬解会把 HTML 当 JSON 解析 → 报成「解码失败」，掩盖真正的鉴权问题）。
    static func statusError(statusCode: Int) -> WeatherError {
        .badStatus(statusCode)
    }

    /// 401/403 的**人话说明**（供 UI 渲染；**单一真源**，别处switch 会漂移）。
    ///
    /// - Returns: 未收录的状态码 → nil（调用方回落到通用文案）。
    static func authenticationHint(statusCode: Int) -> String? {
        switch statusCode {
        case 401:
            return "鉴权失败（401）：API Host 与凭据不匹配，或 token 已过期"
                + "（会自动重签；若持续失败请检查 Project ID / Credential ID / 私钥）"
        case 403:
            return "无权限（403）：专属 API Host 不正确，或该凭据无此端点权限"
                + "（重签无用，请检查控制台的 API Host）"
        default:
            return nil
        }
    }

    /// 错误响应体的**短提示**（**绝不**把整页 HTML 塞给用户）。
    ///
    /// ⚠️ 本仓纪律：网络层错误分支要先判 content-type 再决定是否解码；
    ///   非 JSON 一律只取「短提示」，且**截断**。
    static func shortBodyHint(_ data: Data, limit: Int = 120) -> String {
        guard !data.isEmpty else { return "" }
        // 快速判是否为可读文本（JSON/HTML 都有可打印前缀）。
        guard let text = String(data: data.prefix(512), encoding: .utf8) else {
            return "（响应体非文本）"
        }
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return "" }
        // 截断，避免整页 HTML 灌进 UI。
        return String(flattened.prefix(limit))
            + (flattened.count > limit ? "…" : "")
    }
}
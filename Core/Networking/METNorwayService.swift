//
//  METNorwayService.swift
//  Core / Networking  [App + Widget 共用]
//
//  第三源取数实现（actor，实现 FieldSupplying），按能力补「基础数值字段」。
//
//  失败隔离（沿用既有 loadAir 四纪律，ARCH §3.4 / 硬约束④）：自带 Task、
//  catch 只置本槽位、不 rethrow、不连累主链路。HTTP 非 2xx（403/429）抛
//  `WeatherError.badStatus(code)`，由协调器按 EV-3 裁定（会话摘除 / 冷却）。
//
//  ⚠️ **`User-Agent` 是本源的硬要求**（MET Norway 条款要求标识自身，缺它可能被拒）
//  → 用 `URLRequest` 显式带上（故这里用 `session.data(for:)` 而非 `data(from:)`）。
//
//  **时区未知不补值**（ARCH §3.5）：本源只产出数值标量，绝不读 `TimeZone.current`、
//  绝不猜测城市；是否采用由协调器据 `City.timeZoneIdentifier` 把关。
//
//  诚实纪律：本源**不**声明/映射 `.windGust`（compact 端点无该字段，
//  声明了却拿不到会在 3 次轮询后被 EV-1 **误摘**）、**不**映射
//  `.precipitationProbability`（无该字段）、**不**把 `symbol_code` 当 WMO 码
//  （需长期维护的对照表，明确不做）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 基于 api.met.no 的辅助源取数实现（按能力补基础数值字段）。
actor METNorwayService: FieldSupplying {

    private let session: URLSession

    /// 初始化（可注入 URLSession，测试传自定义 configuration）。
    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - DataFieldSource
    //
    // 四个声明面属性均为不可变 Sendable 值类型，语义上无需隔离；
    // 加 `nonisolated` 以满足 FieldSupplying（nonisolated 协议要求），
    // 否则 Swift 严格并发检查会拒绝「actor 隔离属性满足 nonisolated 要求」。

    nonisolated let id: SourceID = .metNorwayForecast
    nonisolated let displayName: String = "MET Norway"
    nonisolated let capabilities: Set<SourceCapability> = [.basicNumericFields]
    /// ⚠️ 必须**恰好**等于 `METNorwayMapper` 会写入的字段集合（两侧对齐，
    /// 由 `METNorwayTests.testFullResponseCoversEveryRequiredField` 钉住）：
    /// 多声明 → 该源被 EV-1 误摘（静默自伤）；漏声明 → 该字段永不参与 EV-1（哑火）。
    nonisolated let requiredFields: Set<WeatherFieldKey> = [
        .temperature, .pressure, .humidity, .cloudCover, .windSpeed, .windDirection
    ]

    // MARK: - FieldSupplying

    func fetchFields(latitude: Double,
                     longitude: Double,
                     capabilities: Set<SourceCapability>,
                     now: Date) async throws -> FieldPatch {
        // 不请求本源能力 → 直接返回空补丁（不联网）。
        guard capabilities.contains(.basicNumericFields) else {
            return FieldPatch(sourceID: id, capturedAt: now)
        }

        guard let request = METNorwayEndpoint.request(latitude: latitude,
                                                     longitude: longitude) else {
            throw WeatherError.badURL
        }

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
        // EV-3：非 2xx 透传状态码（由协调器裁定 auth / rateLimit）。
        guard (200..<300).contains(http.statusCode) else {
            throw WeatherError.badStatus(http.statusCode)
        }

        // 统一解码入口（失败携带 codingPath，不静默）。
        let dto = try ResponseDecoding.decode(METNorwayResponse.self, from: data)

        // mapper 处理缺块 / 空序列 / 时间归一（取离 now 最近的一格）。
        return METNorwayMapper.map(dto, now: now)
    }
}

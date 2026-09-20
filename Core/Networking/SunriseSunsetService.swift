//
//  SunriseSunsetService.swift
//  Core / Networking  [App + Widget 共用]
//
//  第二源取数实现（actor，实现 FieldSupplying）。
//
//  失败隔离（沿用既有 loadAir 四纪律，ARCH §3.4 / 硬约束④）：自带 Task、
//  catch 只置本槽位、不 rethrow、不连累主链路。HTTP 非 2xx（401/403/429）
//  抛 `WeatherError.badStatus(code)`，由协调器按 EV-3 裁定（会话摘除 / 冷却）。
//
//  **时区未知不补值**（ARCH §3.5）：本服务只产出**绝对时刻**的 Date，
//  绝不读取 TimeZone.current；是否采用由协调器据 `City.timeZoneIdentifier`
//  把关（nil → 不写补丁、不猜测城市）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 基于 api.sunrise-sunset.org 的第二源取数实现（按能力补 solarEvents 四格）。
actor SunriseSunsetService: FieldSupplying {

    private let session: URLSession

    /// 初始化（可注入 URLSession，测试传自定义 configuration）。
    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - DataFieldSource

    var id: SourceID { .sunriseSunset }
    var displayName: String { "Sunrise-Sunset.org" }
    var capabilities: Set<SourceCapability> { [.solarEvents] }
    var requiredFields: Set<WeatherFieldKey> { [.sunrise, .sunset, .daylightDuration] }

    // MARK: - FieldSupplying

    func fetchFields(latitude: Double,
                     longitude: Double,
                     capabilities: Set<SourceCapability>,
                     now: Date) async throws -> FieldPatch {
        // 不请求本源能力 → 直接返回空补丁（不联网）。
        guard capabilities.contains(.solarEvents) else {
            return FieldPatch(sourceID: id, capturedAt: now)
        }

        guard let url = SunriseSunsetEndpoint.url(latitude: latitude, longitude: longitude) else {
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
        // EV-3：非 2xx 透传状态码（由协调器裁定 auth / rateLimit）。
        guard (200..<300).contains(http.statusCode) else {
            throw WeatherError.badStatus(http.statusCode)
        }

        // 统一解码入口（失败携带 codingPath，不静默）。
        let dto = try ResponseDecoding.decode(SunriseSunsetResponse.self, from: data)

        // mapper 处理 status/results 缺失、时间归一（产出绝对时刻）。
        return SunriseSunsetMapper.map(dto, now: now)
    }
}

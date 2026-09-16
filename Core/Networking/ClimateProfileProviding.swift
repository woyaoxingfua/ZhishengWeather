//
//  ClimateProfileProviding.swift
//  Core / Networking  [App + Widget 共用]
//
//  个人气候档案取数链路：用户进入“气候档案”页时才触发，不接入 15 分钟主循环。
//  对 Archive API 发起一次宽范围请求（约 10 年），按同月同日过滤。
//  本地 5 分钟缓存降低用户反复进入时的请求次数（配额守卫的轻量实现）。
//  失败隔离：页面内降级，绝不触碰 WeatherViewModel.state。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 气候档案取数协议（预览/测试可注入 Stub）。
protocol ClimateProfileProviding: Sendable {
    /// 取回指定城市的个人气候档案。
    /// - Parameters:
    ///   - city: 目标城市（含坐标、时区）。
    ///   - today: 今天的绝对时刻（调用方注入，Core 不内部取 Date()）。
    ///   - now: 当前绝对时刻（用于本地缓存/节流）。
    ///   - currentYearHigh: 今年今日最高温（来自主天气链路），用于计算差值；nil 时不算差值。
    func fetch(city: City, today: Date, now: Date, currentYearHigh: Double?) async throws -> ClimateProfile
}

/// Open-Meteo Archive API 实现的气候档案服务。
actor ClimateProfileService: ClimateProfileProviding {

    /// 缓存有效期：5 分钟。气候档案变化缓慢，短于该间隔的重复进入直接返回缓存。
    private static let cacheInterval: TimeInterval = 5 * 60

    private let session: URLSession
    /// 内存缓存：[城市 id -> (档案, 写入时间)]。
    private var cache: [String: (profile: ClimateProfile, fetchedAt: Date)] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(city: City, today: Date, now: Date, currentYearHigh: Double?) async throws -> ClimateProfile {
        if let cached = cache[city.id], now.timeIntervalSince(cached.fetchedAt) < Self.cacheInterval {
            return cached.profile
        }

        let calendar = Self.calendar(for: city)
        guard let (startDate, endDate) = Self.dateRange(for: today, calendar: calendar) else {
            throw WeatherError.badURL
        }

        guard let url = ArchiveEndpoint.climateProfileURL(latitude: city.latitude,
                                                          longitude: city.longitude,
                                                          startDate: startDate,
                                                          endDate: endDate) else {
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

        let dto: ArchiveResponse
        do {
            dto = try JSONDecoder().decode(ArchiveResponse.self, from: data)
        } catch {
            throw WeatherError.decoding(error.localizedDescription)
        }

        let profile = ClimateProfileMapper.map(dto, calendar: calendar, today: today, currentYearHigh: currentYearHigh)
        cache[city.id] = (profile, now)
        return profile
    }

    // MARK: - Private

    private static func calendar(for city: City) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // 用闭包而非 `flatMap(TimeZone(identifier:))`：把初始化器当函数引用传给 flatMap
        // 在 Swift 5.9 下编译失败（CI run51 实测 "cannot find 'TimeZone(identifier:)'"）。
        calendar.timeZone = city.timeZoneIdentifier.flatMap { TimeZone(identifier: $0) } ?? .current
        return calendar
    }

    /// 计算宽范围 archive 起止日期：从 11 年前留 15 天缓冲，到 6 天前（避开 ERA5 滞后窗口）。
    private static func dateRange(for today: Date, calendar: Calendar) -> (start: String, end: String)? {
        guard let end = calendar.date(byAdding: .day, value: -6, to: today),
              let start = calendar.date(byAdding: .year, value: -11, to: end) else {
            return nil
        }
        return (Self.format(start, calendar: calendar), Self.format(end, calendar: calendar))
    }

    private static func format(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      components.year ?? 0,
                      components.month ?? 0,
                      components.day ?? 0)
    }
}

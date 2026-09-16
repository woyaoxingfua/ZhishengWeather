//
//  ClimateProfileServiceTests.swift
//  ZhishengWeatherTests
//
//  气候档案服务测试：验证宽范围 URL 起止日期、解码+映射链路、5 分钟内存缓存。
//  使用自定义 URLProtocol 注入响应，不联网。
//

import XCTest
@testable import ZhishengWeather

/// 可编程 URLProtocol：startLoading 时调用静态 handler。
private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class ClimateProfileServiceTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return cal
    }

    private func city() -> City {
        City(name: "杭州", latitude: 30.27, longitude: 120.16,
             isCurrentLocation: false, timeZoneIdentifier: "Asia/Shanghai")
    }

    private func date(year: Int, month: Int, day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.timeZone = calendar.timeZone
        return calendar.date(from: comps)!
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// 编码 DTO 为 JSON 字节（throws 传播，禁止 `try!` —— SC-31 纪律）。
    private func encode(_ response: ArchiveResponse) throws -> Data {
        try JSONEncoder().encode(response)
    }

    /// 从 URL 查询参数中提取指定键的值。
    private func queryValue(_ key: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == key }?
            .value
    }

    // MARK: - 请求面

    func testServiceRequestsElevenYearWideRange() async throws {
        let service = ClimateProfileService(session: session())
        var capturedURL: URL?
        MockURLProtocol.handler = { request in
            capturedURL = request.url
            let dto = ArchiveResponse(daily: ArchiveResponse.Daily(
                time: [],
                temperature_2m_max: [],
                temperature_2m_min: nil,
                weather_code: nil,
                precipitation_sum: nil
            ))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, try self.encode(dto))
        }

        let today = date(year: 2026, month: 9, day: 16)
        _ = try await service.fetch(city: city(), today: today, now: today, currentYearHigh: 35.0)

        let url = try XCTUnwrap(capturedURL)
        XCTAssertEqual(queryValue("latitude", in: url), "30.27")
        XCTAssertEqual(queryValue("longitude", in: url), "120.16")
        XCTAssertEqual(queryValue("daily", in: url), "temperature_2m_max")

        let end = try XCTUnwrap(queryValue("end_date", in: url))
        let start = try XCTUnwrap(queryValue("start_date", in: url))
        // end = today - 6 days = 2026-09-10；start = end - 11 years = 2015-09-10。
        XCTAssertEqual(end, "2026-09-10")
        XCTAssertEqual(start, "2015-09-10")
    }

    // MARK: - 解码+映射链路

    func testServiceDecodesAndMapsResponse() async throws {
        let service = ClimateProfileService(session: session())
        MockURLProtocol.handler = { request in
            var times: [String] = []
            var maxTemps: [Double?] = []
            for year in 2016...2025 {
                times.append(String(format: "%04d-09-16", year))
                maxTemps.append(Double(year % 100))
            }
            let dto = ArchiveResponse(daily: ArchiveResponse.Daily(
                time: times,
                temperature_2m_max: maxTemps,
                temperature_2m_min: nil,
                weather_code: nil,
                precipitation_sum: nil
            ))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, try self.encode(dto))
        }

        let today = date(year: 2026, month: 9, day: 16)
        let profile = try await service.fetch(city: city(), today: today, now: today, currentYearHigh: 35.0)

        XCTAssertEqual(profile.sameDateLastYear?.year, 2025)
        XCTAssertEqual(profile.sameDateLast10Years?.count, 10)
        XCTAssertEqual(profile.tenYearAverageHigh, 20.5)
    }

    // MARK: - 本地缓存

    func testCacheReturnsSameResultWithoutSecondRequest() async throws {
        let service = ClimateProfileService(session: session())
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            let dto = ArchiveResponse(daily: ArchiveResponse.Daily(
                time: ["2025-09-16"],
                temperature_2m_max: [25.0],
                temperature_2m_min: nil,
                weather_code: nil,
                precipitation_sum: nil
            ))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, try self.encode(dto))
        }

        let today = date(year: 2026, month: 9, day: 16)
        let profile1 = try await service.fetch(city: city(), today: today, now: today, currentYearHigh: 35.0)
        let profile2 = try await service.fetch(city: city(), today: today, now: today, currentYearHigh: 35.0)

        XCTAssertEqual(requestCount, 1, "5 分钟内同一城市应命中内存缓存，不发第二请求")
        XCTAssertEqual(profile1.sameDateLastYear?.tempMax, profile2.sameDateLastYear?.tempMax)
    }

    func testDifferentCityBypassesCache() async throws {
        let service = ClimateProfileService(session: session())
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            let dto = ArchiveResponse(daily: ArchiveResponse.Daily(
                time: ["2025-09-16"],
                temperature_2m_max: [25.0],
                temperature_2m_min: nil,
                weather_code: nil,
                precipitation_sum: nil
            ))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, try self.encode(dto))
        }

        let today = date(year: 2026, month: 9, day: 16)
        let hangzhou = city()
        let beijing = City(name: "北京", latitude: 39.90, longitude: 116.41,
                           isCurrentLocation: false, timeZoneIdentifier: "Asia/Shanghai")

        _ = try await service.fetch(city: hangzhou, today: today, now: today, currentYearHigh: 35.0)
        _ = try await service.fetch(city: beijing, today: today, now: today, currentYearHigh: 35.0)

        XCTAssertEqual(requestCount, 2, "不同城市应分别请求")
    }
}

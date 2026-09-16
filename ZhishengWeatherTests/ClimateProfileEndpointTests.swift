//
//  ClimateProfileEndpointTests.swift
//  ZhishengWeatherTests
//
//  气候档案 ArchiveEndpoint 扩展测试：确认新增 `climateProfileURL` 只取日最高温。
//

import XCTest
@testable import ZhishengWeather

final class ClimateProfileEndpointTests: XCTestCase {

    func testClimateProfileURLUsesMaxTemperatureOnly() throws {
        let url = try XCTUnwrap(ArchiveEndpoint.climateProfileURL(latitude: 30.27,
                                                                  longitude: 120.16,
                                                                  startDate: "2015-09-10",
                                                                  endDate: "2026-09-10"))
        let absolute = url.absoluteString
        XCTAssertTrue(absolute.hasPrefix("https://archive-api.open-meteo.com/v1/archive"))
        XCTAssertTrue(absolute.contains("daily=temperature_2m_max"))
        XCTAssertTrue(absolute.contains("start_date=2015-09-10"))
        XCTAssertTrue(absolute.contains("end_date=2026-09-10"))
        XCTAssertTrue(absolute.contains("timezone=auto"))
        XCTAssertFalse(absolute.contains("temperature_2m_min"))
        XCTAssertFalse(absolute.contains("weather_code"))
        XCTAssertFalse(absolute.contains("precipitation_sum"))
    }

    func testExistingArchiveURLUnchanged() throws {
        let url = try XCTUnwrap(ArchiveEndpoint.url(latitude: 30.27, longitude: 120.16,
                                                    startDate: "2026-09-01", endDate: "2026-09-07"))
        let absolute = url.absoluteString
        XCTAssertTrue(absolute.contains("daily=temperature_2m_max"))
        XCTAssertTrue(absolute.contains("temperature_2m_min"))
        XCTAssertTrue(absolute.contains("weather_code"))
        XCTAssertTrue(absolute.contains("precipitation_sum"))
    }
}

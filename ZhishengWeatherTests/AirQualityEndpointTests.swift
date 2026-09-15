//
//  AirQualityEndpointTests.swift
//  ZhishengWeatherTests
//
//  空气端点请求面（AC-A2-1）：独立域名 / 八字段 current / timezone=auto /
//  无 timeformat / 坐标注入。
//

import XCTest
@testable import ZhishengWeather

final class AirQualityEndpointTests: XCTestCase {

    func testBuildsURLWithCorrectDomainAndFields() throws {
        let url = try XCTUnwrap(AirQualityEndpoint.url(latitude: 39.9042, longitude: 116.4074))
        let absolute = url.absoluteString
        XCTAssertTrue(absolute.hasPrefix("https://air-quality-api.open-meteo.com/v1/air-quality"))
        XCTAssertTrue(absolute.contains("latitude=39.9042"))
        XCTAssertTrue(absolute.contains("longitude=116.4074"))
        XCTAssertTrue(absolute.contains("timezone=auto"))
        for field in ["pm10", "pm2_5", "carbon_monoxide", "nitrogen_dioxide",
                      "sulphur_dioxide", "ozone", "us_aqi", "european_aqi"] {
            XCTAssertTrue(absolute.contains(field), "缺少字段 \(field)")
        }
        // 无时间数组 → 不声明 timeformat。
        XCTAssertFalse(absolute.contains("timeformat"))
    }

    func testZeroCoordinatesProduceValidURL() {
        // 常规坐标恒成功（坏坐标防御由调用方 service 层收敛，此处锁定请求面）。
        XCTAssertNotNil(AirQualityEndpoint.url(latitude: 0.0, longitude: 0.0))
    }
}

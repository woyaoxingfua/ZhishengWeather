//
//  EnsembleEndpointTests.swift
//  ZhishengWeatherTests
//
//  集合端点请求面：独立域名 / 最小字段（hourly=precipitation）/ 显式非空 models /
//  forecast_days=2 / timezone=auto / 不声明 timeformat。
//

import XCTest
@testable import ZhishengWeather

final class EnsembleEndpointTests: XCTestCase {

    func testBuildsURLWithCorrectDomainAndParameters() throws {
        let url = try XCTUnwrap(EnsembleEndpoint.url(latitude: 30.27, longitude: 120.16))
        let absolute = url.absoluteString
        XCTAssertTrue(absolute.hasPrefix("https://ensemble-api.open-meteo.com/v1/ensemble"),
                      "域名错误：\(absolute)")
        XCTAssertTrue(absolute.contains("latitude=30.27"))
        XCTAssertTrue(absolute.contains("longitude=120.16"))
        XCTAssertTrue(absolute.contains("hourly=precipitation"))
        XCTAssertTrue(absolute.contains("forecast_days=2"))
        XCTAssertTrue(absolute.contains("timezone=auto"))
        // 默认 iso8601 本地墙钟（time 为字符串，见 live 实测），故不声明 timeformat。
        XCTAssertFalse(absolute.contains("timeformat"),
                       "集合链路不应声明 timeformat（time 为 ISO 本地墙钟）")
    }

    func testModelParameterIsExplicitAndNonEmpty() throws {
        let url = try XCTUnwrap(EnsembleEndpoint.url(latitude: 0.0, longitude: 0.0))
        let absolute = url.absoluteString
        // 显式模式：空 `models=` 会 400（PRD §11-8），故必须是具体模式名。
        XCTAssertTrue(absolute.contains("models=gfs025"), "应显式声明非空 models")
        XCTAssertFalse(absolute.contains("models=&"), "绝不可发空 models=")
        XCTAssertEqual(EnsembleEndpoint.model, "gfs025")
        XCTAssertEqual(EnsembleEndpoint.forecastDays, 2)
    }

    func testZeroCoordinatesProduceValidURL() {
        // 坏坐标防御由 service 层收敛，此处仅锁定请求面恒可构造。
        XCTAssertNotNil(EnsembleEndpoint.url(latitude: 0.0, longitude: 0.0))
    }
}

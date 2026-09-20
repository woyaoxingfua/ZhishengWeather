//
//  AirQualityEndpointTests.swift
//  ZhishengWeatherTests
//
//  空气端点请求面（AC-A2-1 + P2 / D-B11，AC-B22 / AC-B23）：
//   独立域名 / 八字段 current / 逐时 us_aqi,pm2_5,pm10 / 显式钉住 forecast_hours=24 /
//   timeformat=unixtime / **仍只有一条 URL 的一次请求**。
//
//  ⚠️ 这些断言只校验 URL 字符串，**不联网**：字段名合法性（服务端对未知字段名
//  返回 HTTP 400）CI 测不出来，改动字段名必须另跑 curl 探针（见端点文件头）。
//

import XCTest
@testable import ZhishengWeather

final class AirQualityEndpointTests: XCTestCase {

    private func beijingURL() throws -> URL {
        try XCTUnwrap(AirQualityEndpoint.url(latitude: 39.9042, longitude: 116.4074))
    }

    // MARK: - 基础（AC-A2-1）

    func testBuildsURLWithCorrectDomainAndFields() throws {
        let url = try beijingURL()
        let absolute = url.absoluteString
        XCTAssertTrue(absolute.hasPrefix("https://air-quality-api.open-meteo.com/v1/air-quality"))
        XCTAssertTrue(absolute.contains("latitude=39.9042"))
        XCTAssertTrue(absolute.contains("longitude=116.4074"))
        XCTAssertTrue(absolute.contains("timezone=auto"))

        let current = try XCTUnwrap(try queryItems(url)["current"])
        let fields = current.split(separator: ",").map(String.init)
        for field in ["pm10", "pm2_5", "carbon_monoxide", "nitrogen_dioxide",
                      "sulphur_dioxide", "ozone", "us_aqi", "european_aqi"] {
            XCTAssertTrue(fields.contains(field), "current 缺少字段 \(field)，实际=\(current)")
        }
    }

    func testZeroCoordinatesProduceValidURL() {
        // 常规坐标恒成功（坏坐标防御由调用方 service 层收敛，此处锁定请求面）。
        XCTAssertNotNil(AirQualityEndpoint.url(latitude: 0.0, longitude: 0.0))
    }

    // MARK: - P2 逐时（AC-B22：请求面扩展为 current + hourly）

    /// AC-B22：同一 URL 内声明逐时三个字段。
    func testURLDeclaresHourlyFields() throws {
        let hourly = try XCTUnwrap(try queryItems(try beijingURL())["hourly"])
        let fields = hourly.split(separator: ",").map(String.init)
        for field in ["us_aqi", "pm2_5", "pm10"] {
            XCTAssertTrue(fields.contains(field), "hourly 缺少字段 \(field)，实际=\(hourly)")
        }
    }

    /// 逐时块必须并入**既有那一条** URL —— 全串只出现一次主机、一次端点路径，
    /// 且每个参数唯一（AC-B23：不得新增第二条 URL / 第二次请求）。
    func testHourlyIsMergedIntoSingleRequest() throws {
        let url = try beijingURL()
        let absolute = url.absoluteString
        XCTAssertEqual(absolute.components(separatedBy: "air-quality-api.open-meteo.com").count - 1, 1,
                       "AC-B23：不得新增第二条空气请求 URL")
        XCTAssertEqual(absolute.components(separatedBy: "/v1/air-quality").count - 1, 1,
                       "AC-B23：不得新增第二个端点")

        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        for name in ["current", "hourly", "forecast_hours", "timezone", "timeformat"] {
            XCTAssertEqual(items.filter { $0.name == name }.count, 1,
                           "参数 \(name) 必须唯一（并入既有请求，而非并列第二次请求）")
        }
    }

    /// 长度必须显式钉住：不声明 `forecast_hours` 时服务端实测返回 120 小时（5 天）
    /// 默认窗口且尾段带 null —— 见端点文件头的探针结论。
    /// 逐时携带时间数组 → 必须声明 `timeformat=unixtime`。
    func testURLPinsHourlyWindowAndUnixTime() throws {
        let query = try queryItems(try beijingURL())
        XCTAssertEqual(query["forecast_hours"], "24",
                       "必须显式钉住 24 小时，免疫 120h 默认窗口与尾段 null")
        XCTAssertEqual(query["forecast_hours"], String(AirQualityEndpoint.hourlyWindowHours))
        XCTAssertEqual(query["timeformat"], "unixtime",
                       "逐时含 time 数组 → 必须以 epoch 秒声明（复用既有解码纪律）")
    }

    // MARK: - Helpers

    private func queryItems(_ url: URL) throws -> [String: String] {
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(components.queryItems)
        return Dictionary(items.map { ($0.name, $0.value ?? "") },
                          uniquingKeysWith: { first, _ in first })
    }
}

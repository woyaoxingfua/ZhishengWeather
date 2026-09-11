//
//  OpenMeteoEndpointTests.swift
//  ZhishengWeatherTests
//
//  请求 URL 构建的静态校验（不联网）：
//   - 基础地址、坐标透传
//   - current / hourly / daily / timezone=auto / timeformat=unixtime 参数齐全
//   - 风速单位必须显式声明为 m/s（见下方 ★ 用例）
//

import XCTest
@testable import ZhishengWeather

final class OpenMeteoEndpointTests: XCTestCase {

    // MARK: - 基础

    func testURLIsBuiltWithExpectedHostAndPath() throws {
        let url = try XCTUnwrap(OpenMeteoEndpoint.url(latitude: 39.9042, longitude: 116.4074))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "api.open-meteo.com")
        XCTAssertEqual(url.path, "/v1/forecast")
    }

    func testURLCarriesGivenCoordinates() throws {
        let url = try XCTUnwrap(OpenMeteoEndpoint.url(latitude: -33.8688, longitude: 151.2093))
        let query = try queryItems(url)
        XCTAssertEqual(query["latitude"], "-33.8688")
        XCTAssertEqual(query["longitude"], "151.2093")
    }

    // MARK: - 参数齐全（P0-2 AC①）

    func testURLDeclaresCurrentFields() throws {
        let url = try XCTUnwrap(OpenMeteoEndpoint.url(latitude: 0, longitude: 0))
        let current = try XCTUnwrap(try queryItems(url)["current"])
        for field in ["temperature_2m", "relative_humidity_2m", "apparent_temperature",
                      "weather_code", "wind_speed_10m", "wind_direction_10m", "is_day"] {
            XCTAssertTrue(current.split(separator: ",").map(String.init).contains(field),
                          "current 缺少字段 \(field)，实际=\(current)")
        }
    }

    func testURLDeclaresHourlyFields() throws {
        let url = try XCTUnwrap(OpenMeteoEndpoint.url(latitude: 0, longitude: 0))
        let hourly = try XCTUnwrap(try queryItems(url)["hourly"])
        let fields = hourly.split(separator: ",").map(String.init)
        XCTAssertTrue(fields.contains("temperature_2m"), "hourly 缺少 temperature_2m")
        XCTAssertTrue(fields.contains("weather_code"), "hourly 缺少 weather_code")
    }

    func testURLDeclaresDailyFields() throws {
        let url = try XCTUnwrap(OpenMeteoEndpoint.url(latitude: 0, longitude: 0))
        let daily = try XCTUnwrap(try queryItems(url)["daily"])
        let fields = daily.split(separator: ",").map(String.init)
        XCTAssertTrue(fields.contains("temperature_2m_max"), "daily 缺少 temperature_2m_max")
        XCTAssertTrue(fields.contains("temperature_2m_min"), "daily 缺少 temperature_2m_min")
    }

    func testURLDeclaresTimezoneAndTimeformat() throws {
        let url = try XCTUnwrap(OpenMeteoEndpoint.url(latitude: 0, longitude: 0))
        let query = try queryItems(url)
        XCTAssertEqual(query["timezone"], "auto")
        XCTAssertEqual(query["timeformat"], "unixtime")
    }

    // MARK: - 风速单位（回归防护）

    /// Open-Meteo 文档：`wind_speed_unit` 默认值为 `kmh`（可选 ms/mph/kn）。
    /// 本项目领域模型 `WeatherSnapshot.windSpeed` 与主屏 UI（`ContentView` 渲染
    /// `"%.1f m/s"`）均按 **m/s** 标注，故 URL 必须显式声明 `wind_speed_unit=ms`；
    /// 否则 `wind_speed_10m` 以 km/h 返回并被当作 m/s 展示 → 风速放大 3.6 倍。
    ///
    /// 本用例最初用于复现该缺陷（`OpenMeteoEndpoint` v1.2 前缺失该参数）；
    /// 缺陷修复后转为**回归防护**，防止后续重构把该参数移除。
    func testURLDeclaresWindSpeedUnitMetersPerSecond() throws {
        let url = try XCTUnwrap(OpenMeteoEndpoint.url(latitude: 39.9042, longitude: 116.4074))
        let query = try queryItems(url)
        XCTAssertEqual(query["wind_speed_unit"], "ms",
                       "风速单位未声明为 ms，Open-Meteo 会按默认 km/h 返回，与 UI/模型标注的 m/s 不符")
    }

    // MARK: - F-A 逐日预报参数

    /// ⚠️ A1 勘误：forecast_days 由 7 升 16（A1-3 显式防漂移），旧断言随任务更新。
    func testURLDeclaresForecastDaysSixteen() throws {
        let url = try XCTUnwrap(OpenMeteoEndpoint.url(latitude: 39.9042, longitude: 116.4074))
        let query = try queryItems(url)
        XCTAssertEqual(query["forecast_days"], "16",
                       "必须显式声明 forecast_days=16（今天 + 15 天，A1-3）")
    }

    /// A1-5：past_days=1（昨日对比的数据源）。
    func testURLDeclaresPastDaysOne() throws {
        let url = try XCTUnwrap(OpenMeteoEndpoint.url(latitude: 39.9042, longitude: 116.4074))
        let query = try queryItems(url)
        XCTAssertEqual(query["past_days"], "1",
                       "必须显式声明 past_days=1（A1-5 昨日对比）")
    }

    /// A1-1：current 含气压双键。
    func testURLCurrentFieldsContainPressureKeys() throws {
        let url = try XCTUnwrap(OpenMeteoEndpoint.url(latitude: 0, longitude: 0))
        let current = try XCTUnwrap(try queryItems(url)["current"])
        let fields = current.split(separator: ",").map(String.init)
        XCTAssertTrue(fields.contains("pressure_msl"), "current 缺少 pressure_msl")
        XCTAssertTrue(fields.contains("surface_pressure"), "current 缺少 surface_pressure")
    }

    /// A1-4：daily 含 sunrise/sunset（AC-A1-11 请求面）。
    func testURLDailyFieldsContainSunriseSunset() throws {
        let url = try XCTUnwrap(OpenMeteoEndpoint.url(latitude: 0, longitude: 0))
        let daily = try XCTUnwrap(try queryItems(url)["daily"])
        let fields = daily.split(separator: ",").map(String.init)
        XCTAssertTrue(fields.contains("sunrise"), "daily 缺少 sunrise")
        XCTAssertTrue(fields.contains("sunset"), "daily 缺少 sunset")
    }

    /// daily 请求字段扩展为 4 字段（F-A），顺序无关断言。
    func testURLDailyFieldsContainFANewFields() throws {
        let url = try XCTUnwrap(OpenMeteoEndpoint.url(latitude: 0, longitude: 0))
        let daily = try XCTUnwrap(try queryItems(url)["daily"])
        let fields = daily.split(separator: ",").map(String.init)
        for field in ["temperature_2m_max", "temperature_2m_min",
                      "weather_code", "precipitation_probability_max"] {
            XCTAssertTrue(fields.contains(field), "daily 缺少字段 \(field)，实际=\(daily)")
        }
    }

    /// F-A 后其余参数不回归：风速单位仍为 ms（v1.2 裁定，回归防护）。
    func testURLStillDeclaresWindSpeedUnitAfterFA() throws {
        let url = try XCTUnwrap(OpenMeteoEndpoint.url(latitude: 0, longitude: 0))
        let query = try queryItems(url)
        XCTAssertEqual(query["wind_speed_unit"], "ms", "F-A 扩展不得破坏 wind_speed_unit=ms")
    }

    // MARK: - Helpers

    private func queryItems(_ url: URL) throws -> [String: String] {
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(components.queryItems)
        return Dictionary(items.map { ($0.name, $0.value ?? "") },
                          uniquingKeysWith: { first, _ in first })
    }
}

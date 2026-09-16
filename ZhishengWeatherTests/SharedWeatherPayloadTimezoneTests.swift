//
//  SharedWeatherPayloadTimezoneTests.swift
//  ZhishengWeatherTests
//
//  D-4 Widget 时区补齐：共享载荷携带可选时区字段 + 格式化时区决策。
//   - 载荷**有**该字段 → 解码出城市时区；
//   - 载荷**无**该字段（旧缓存手写 JSON）→ 解码为 nil、不失败；
//   - 格式化决策：有城市时区 → 用城市时区；缺省 → 设备时区。
//
//  说明：Widget target 的 `WidgetTimeFormatter` 不在本测试 bundle 内（测试仅依赖
//  app target）。故此处覆盖其**时区裁定单一真源**——`WeatherTimeFormatter.resolveTimeZone`
//  （Widget 的非隔离格式化路径直接委托它），确保"有则用城市、无则用设备"这一决策被锁死。
//

import XCTest
@testable import ZhishengWeather

@MainActor
final class SharedWeatherPayloadTimezoneTests: XCTestCase {

    /// 最小合法快照 JSON（不含任何可选新键）。
    private static let snapshotJSON = """
    {
      "location": { "name": "杭州", "latitude": 30.27, "longitude": 120.16, "isFallback": false },
      "temperature": 23.4,
      "apparentTemperature": 21.0,
      "weatherCode": 2,
      "windSpeed": 3.2,
      "windDirection": 135.0,
      "humidity": 58,
      "isDay": true,
      "hourly": [],
      "dailyHigh": 26.1,
      "dailyLow": 15.2,
      "fetchedAt": 1700000010.0
    }
    """

    // MARK: - 载荷解码：有 / 无新字段

    func testPayloadDecodesTimeZoneIdentifierWhenPresent() throws {
        let json = """
        { "snapshot": \(Self.snapshotJSON), "updatedAt": 1700000500.0,
          "timeZoneIdentifier": "Asia/Shanghai" }
        """
        let payload = try JSONDecoder().decode(SharedWeatherPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(payload.snapshot.location.name, "杭州")
    }

    func testLegacyPayloadWithoutTimeZoneFieldDecodesToNil() throws {
        let json = """
        { "snapshot": \(Self.snapshotJSON), "updatedAt": 1700000500.0 }
        """
        let payload = try JSONDecoder().decode(SharedWeatherPayload.self, from: Data(json.utf8))
        XCTAssertNil(payload.timeZoneIdentifier, "旧缓存无该键必须解码为 nil（不失败，R3）")
        XCTAssertEqual(payload.snapshot.location.name, "杭州")
        XCTAssertEqual(payload.snapshot.temperature, 23.4, accuracy: 0.001)
    }

    func testPayloadRoundTripsTimeZoneIdentifier() throws {
        let date = Date(timeIntervalSinceReferenceDate: 1_700_000_000)
        let snapshot = WeatherSnapshot(
            location: .beijing, temperature: 23, apparentTemperature: 21, weatherCode: 2,
            windSpeed: 3.2, windDirection: 135, humidity: 58, isDay: true, hourly: [],
            dailyHigh: 25, dailyLow: 15, fetchedAt: date)
        let payload = SharedWeatherPayload(snapshot: snapshot, updatedAt: date,
                                           timeZoneIdentifier: "America/New_York")

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(SharedWeatherPayload.self, from: data)

        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.timeZoneIdentifier, "America/New_York")
    }

    // MARK: - 格式化时区决策（Widget 路径委托的 Core 单一真源）

    func testFormatterPicksCityTimeZoneWhenPresent() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let resolved = WeatherTimeFormatter.resolveTimeZone(identifier: "Asia/Shanghai")

        XCTAssertEqual(resolved.identifier, "Asia/Shanghai", "有城市时区 → 用城市时区")
        XCTAssertEqual(
            WeatherTimeFormatter.string(from: date, format: "HH:mm", timeZone: resolved),
            WeatherTimeFormatter.string(from: date, format: "HH:mm", timeZone: shanghai))
    }

    func testFormatterPicksDeviceTimeZoneWhenAbsent() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let resolved = WeatherTimeFormatter.resolveTimeZone(identifier: nil)

        XCTAssertEqual(resolved.identifier, TimeZone.current.identifier,
                       "缺省 → 设备时区（保持既有行为）")
        XCTAssertEqual(
            WeatherTimeFormatter.string(from: date, format: "HH:mm", timeZone: resolved),
            WeatherTimeFormatter.string(from: date, format: "HH:mm", timeZone: .current))
    }

    /// 城市时区 ≠ 设备时区时，同一时刻渲染必须不同（时区确实生效，而非静默回退设备）。
    func testCityTimeZoneDiffersFromDeviceRendering() {
        // CI runner 时区非上海；若恰好相等则本断言无意义，跳过。
        guard TimeZone.current.identifier != "Asia/Shanghai" else { return }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let cityText = WeatherTimeFormatter.string(
            from: date, format: "HH:mm",
            timeZone: WeatherTimeFormatter.resolveTimeZone(identifier: "Asia/Shanghai"))
        let deviceText = WeatherTimeFormatter.string(
            from: date, format: "HH:mm",
            timeZone: WeatherTimeFormatter.resolveTimeZone(identifier: nil))
        XCTAssertNotEqual(cityText, deviceText)
    }
}

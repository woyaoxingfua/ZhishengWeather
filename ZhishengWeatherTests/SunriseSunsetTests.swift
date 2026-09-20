//
//  SunriseSunsetTests.swift
//  ZhishengWeatherTests
//
//  第二源 DTO 解码 + 时间归一 + 时区前提锚点（ARCH §7 T08 / §8 守卫⑦）：
//  - 任一字段缺失 / 整块缺失 → 解码不抛错（mapper 回落空补丁）；
//  - 时间归一后是绝对时刻（不依赖设备时区）；
//  - status != "OK" → 空补丁；
//  - 元素异常（results 非对象）→ 解码抛错（服务会 catch 回落空补丁）。
//
//  不联网：全部喂本地造好的 JSON。
//

import XCTest
@testable import ZhishengWeather

final class SunriseSunsetTests: XCTestCase {

    let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// 完整响应 → 全部字段解析 + 时间归一为绝对时刻。
    func testDecodeFullAndNormalizeAbsolute() throws {
        let json = #"""
        {"results":{"sunrise":"2026-09-19T21:58:29+00:00","sunset":"2026-09-20T10:17:18+00:00","solar_noon":"2026-09-20T04:07:54+00:00","day_length":44329},"status":"OK","tzid":"UTC"}
        """#.data(using: .utf8)!

        let dto = try JSONDecoder().decode(SunriseSunsetResponse.self, from: json)
        XCTAssertEqual(dto.status, "OK")
        let patch = SunriseSunsetMapper.map(dto, now: now)

        XCTAssertNotNil(patch.sunrise)
        XCTAssertNotNil(patch.sunset)
        XCTAssertNotNil(patch.solarNoon)
        XCTAssertEqual(patch.daylightDuration, 44329.0)

        // 绝对时刻：UTC 2026-09-19 21:58:29（与设备时区无关）。
        let fmt = ISO8601DateFormatter()
        fmt.timeZone = TimeZone(identifier: "UTC")
        let expected = fmt.date(from: "2026-09-19T21:58:29+00:00")
        XCTAssertEqual(patch.sunrise, expected)
    }

    /// 单字段缺失 → 解码不抛错，缺失字段为 nil。
    func testMissingFieldDecodesWithoutThrowing() throws {
        let json = #"{"results":{"sunrise":"2026-09-19T21:58:29+00:00","day_length":44329},"status":"OK"}"#.data(using: .utf8)!
        let dto = try JSONDecoder().decode(SunriseSunsetResponse.self, from: json)
        let patch = SunriseSunsetMapper.map(dto, now: now)

        XCTAssertNotNil(patch.sunrise)
        XCTAssertNil(patch.sunset, "缺失字段必须 nil，不崩")
        XCTAssertNil(patch.solarNoon)
    }

    /// results 整块缺失 → 空补丁（不崩）。
    func testResultsMissingYieldsEmptyPatch() throws {
        let json = #"{"status":"OK"}"#.data(using: .utf8)!
        let dto = try JSONDecoder().decode(SunriseSunsetResponse.self, from: json)
        let patch = SunriseSunsetMapper.map(dto, now: now)

        XCTAssertNil(patch.sunrise)
        XCTAssertNil(patch.sunset)
        XCTAssertNil(patch.solarNoon)
    }

    /// status != "OK" → 回落空补丁。
    func testStatusNotOKYieldsEmptyPatch() throws {
        let json = #"{"results":{"sunrise":"2026-09-19T21:58:29+00:00"},"status":"INVALID"}"#.data(using: .utf8)!
        let dto = try JSONDecoder().decode(SunriseSunsetResponse.self, from: json)
        let patch = SunriseSunsetMapper.map(dto, now: now)

        XCTAssertNil(patch.sunrise, "status != OK 必须回落空补丁")
    }

    /// 元素异常（results 期望对象却给字符串）→ 解码抛错（服务会 catch 回落空补丁）。
    func testMalformedResultsThrowsDecode() {
        let json = #"{"results":"notanobject","status":"OK"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(SunriseSunsetResponse.self, from: json))
    }

    /// 时间归一不依赖设备时区：同一 UTC 串在任何环境下归一为同一绝对时刻。
    func testNormalizedTimeIsAbsoluteNotDeviceDependent() throws {
        let json = #"{"results":{"sunrise":"2026-09-19T21:58:29+00:00"},"status":"OK"}"#.data(using: .utf8)!
        let dto = try JSONDecoder().decode(SunriseSunsetResponse.self, from: json)
        let patch = SunriseSunsetMapper.map(dto, now: now)

        let fmt = ISO8601DateFormatter()
        fmt.timeZone = TimeZone(identifier: "UTC")
        let expected = fmt.date(from: "2026-09-19T21:58:29+00:00")
        XCTAssertEqual(patch.sunrise, expected)
    }
}

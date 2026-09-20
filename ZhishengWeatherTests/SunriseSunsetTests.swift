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
//  T10 泛化后：补丁不再是「每个字段一个属性」，取值一律走**带类型**的访问器
//  （`instant(_:)` / `seconds(_:)`），未装载的字段返回 nil（缺失，不是 0）。
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

        XCTAssertNotNil(patch.instant(.sunrise))
        XCTAssertNotNil(patch.instant(.sunset))
        XCTAssertNotNil(patch.instant(.solarNoon))
        XCTAssertEqual(patch.seconds(.daylightDuration), 44329.0)

        // 绝对时刻：UTC 2026-09-19 21:58:29（与设备时区无关）。
        let fmt = ISO8601DateFormatter()
        fmt.timeZone = TimeZone(identifier: "UTC")
        let expected = fmt.date(from: "2026-09-19T21:58:29+00:00")
        XCTAssertEqual(patch.instant(.sunrise), expected)
    }

    /// 单字段缺失 → 解码不抛错，缺失字段为 nil。
    func testMissingFieldDecodesWithoutThrowing() throws {
        let json = #"{"results":{"sunrise":"2026-09-19T21:58:29+00:00","day_length":44329},"status":"OK"}"#.data(using: .utf8)!
        let dto = try JSONDecoder().decode(SunriseSunsetResponse.self, from: json)
        let patch = SunriseSunsetMapper.map(dto, now: now)

        XCTAssertNotNil(patch.instant(.sunrise))
        XCTAssertNil(patch.instant(.sunset), "缺失字段必须 nil，不崩")
        XCTAssertNil(patch.instant(.solarNoon))
    }

    /// results 整块缺失 → 空补丁（不崩）。
    func testResultsMissingYieldsEmptyPatch() throws {
        let json = #"{"status":"OK"}"#.data(using: .utf8)!
        let dto = try JSONDecoder().decode(SunriseSunsetResponse.self, from: json)
        let patch = SunriseSunsetMapper.map(dto, now: now)

        XCTAssertNil(patch.instant(.sunrise))
        XCTAssertNil(patch.instant(.sunset))
        XCTAssertNil(patch.instant(.solarNoon))
    }

    /// status != "OK" → 回落空补丁。
    func testStatusNotOKYieldsEmptyPatch() throws {
        let json = #"{"results":{"sunrise":"2026-09-19T21:58:29+00:00"},"status":"INVALID"}"#.data(using: .utf8)!
        let dto = try JSONDecoder().decode(SunriseSunsetResponse.self, from: json)
        let patch = SunriseSunsetMapper.map(dto, now: now)

        XCTAssertNil(patch.instant(.sunrise), "status != OK 必须回落空补丁")
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
        XCTAssertEqual(patch.instant(.sunrise), expected)
    }

    /// T10：`day_length: 0`（极夜）是**有效值**，不是「缺失」——
    /// 稀疏语义必须把「未命中」与「值为 0」严格区分开。
    func testZeroDayLengthIsPresentNotMissing() throws {
        let json = #"{"results":{"day_length":0},"status":"OK"}"#.data(using: .utf8)!
        let dto = try JSONDecoder().decode(SunriseSunsetResponse.self, from: json)
        let patch = SunriseSunsetMapper.map(dto, now: now)

        XCTAssertFalse(patch.isMissing(.daylightDuration), "昼长 0 是有效值，不是缺失")
        XCTAssertEqual(patch.seconds(.daylightDuration), 0.0)
        XCTAssertTrue(patch.isMissing(.sunrise), "未返回的字段才叫缺失")
    }

    /// **反向守卫**：源声明的必填集必须能被「正常响应」**全部覆盖**。
    ///
    /// 为什么需要：`requiredFields` 里若写了一个 mapper **永远不写**的字段，
    /// 该源会在连续 3 次轮询后被 EV-1 **误摘** —— 自己把自己摘掉，而且**静默**
    /// （设置页显示「已摘除 · 原因 EV-1」，看起来像对端故障，实际是本地声明写错了）。
    /// 本守卫锚的是**性质**（正常响应 ⊇ 必填集），不锚具体字段名：
    /// 将来给本源加必填字段时，这条会先红，逼作者同时把「正常响应」补全，
    /// 而不是默默把自己摘掉。
    func testFullResponseCoversEveryRequiredField() throws {
        let json = #"""
        {"results":{"sunrise":"2026-09-19T21:58:29+00:00","sunset":"2026-09-20T10:17:18+00:00","solar_noon":"2026-09-20T04:07:54+00:00","day_length":44329},"status":"OK","tzid":"UTC"}
        """#.data(using: .utf8)!
        let dto = try JSONDecoder().decode(SunriseSunsetResponse.self, from: json)
        let patch = SunriseSunsetMapper.map(dto, now: now)

        let declared = SunriseSunsetService().requiredFields
        XCTAssertFalse(declared.isEmpty, "参与自动摘除的源必须有必填集（否则 EV-1 恒不触发）")
        let stillMissing = declared.filter { patch.isMissing($0) }
        XCTAssertTrue(stillMissing.isEmpty,
                      "正常响应下仍缺的必填字段：\(stillMissing) —— 这些字段一旦列入 requiredFields，"
                      + "本源会在 3 次轮询后被 EV-1 **误摘**（静默自伤）")
    }
}

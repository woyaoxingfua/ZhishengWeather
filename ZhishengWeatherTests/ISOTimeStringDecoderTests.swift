//
//  ISOTimeStringDecoderTests.swift
//  ZhishengWeatherTests
//
//  ISO 本地墙钟字符串独立解码器的边界用例（ARCH-A1 §5 测试设计，不联网）：
//   - 正常解析（HH:mm 形态）
//   - offset 正 / 负两向正确
//   - 无 T 分隔 / 非数字 / 空串 → nil
//   - 跨日墙钟 + 大 offset
//   - 秒段宽容、非法日期（13 月）→ nil
//
//  ⚠️ 本解码器与 epoch 解码路径完全隔离（PRD R3 / ARCH-A1 §1.4 铁律 1）；
//  本文件只测字符串路径，不触碰 `Date(timeIntervalSince1970:)` 以外的
//  epoch 字段语义。
//

import XCTest
@testable import ZhishengWeather

final class ISOTimeStringDecoderTests: XCTestCase {

    // MARK: - 正常解析

    /// 正常值：北京时间（+8h）05:53 日出 → 当日 UTC 前夜 21:53。
    func testDateWhenNormalBeijingSunriseString() throws {
        let date = try XCTUnwrap(ISOTimeStringDecoder.date(
            from: "2026-09-11T05:53", utcOffsetSeconds: 28_800))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 28_800)!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 9)
        XCTAssertEqual(components.day, 11)
        XCTAssertEqual(components.hour, 5)
        XCTAssertEqual(components.minute, 53)
    }

    /// offset 正向：墙钟 +8h 与 epoch 的关系（用 epoch 侧校验绝对时刻）。
    func testDateWhenPositiveOffsetMatchesEpoch() throws {
        // 2026-09-11 00:00 (+08:00) = 2026-09-10 16:00 UTC = epoch 1_786_396_800。
        let date = try XCTUnwrap(ISOTimeStringDecoder.date(
            from: "2026-09-11T00:00", utcOffsetSeconds: 28_800))
        XCTAssertEqual(date.timeIntervalSince1970, 1_786_396_800, accuracy: 1.0)
    }

    /// offset 负向：纽约（-5h）墙钟 → UTC = 墙钟 + 5h。
    func testDateWhenNegativeOffsetMatchesEpoch() throws {
        // 2026-09-11 00:00 (-05:00) = 2026-09-11 05:00 UTC = epoch 1_786_458_000。
        let date = try XCTUnwrap(ISOTimeStringDecoder.date(
            from: "2026-09-11T00:00", utcOffsetSeconds: -18_000))
        XCTAssertEqual(date.timeIntervalSince1970, 1_786_458_000, accuracy: 1.0)
    }

    /// 跨日墙钟 + 大 offset：+14h（基里蒂马蒂）23:50 → UTC 仍是同一天 09:50。
    func testDateWhenLateNightWithLargePositiveOffset() throws {
        let date = try XCTUnwrap(ISOTimeStringDecoder.date(
            from: "2026-09-11T23:50", utcOffsetSeconds: 50_400))
        // 2026-09-11 23:50 +14:00 = 2026-09-11 09:50 UTC。
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.day, .hour, .minute], from: date)
        XCTAssertEqual(components.day, 11)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 50)
    }

    /// 秒段宽容："T05:53:30" 亦解析成功且秒值正确。
    func testDateWhenSecondsSegmentPresent() throws {
        let date = try XCTUnwrap(ISOTimeStringDecoder.date(
            from: "2026-09-11T05:53:30", utcOffsetSeconds: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        XCTAssertEqual(components.hour, 5)
        XCTAssertEqual(components.minute, 53)
        XCTAssertEqual(components.second, 30)
    }

    // MARK: - 失败路径（一律 nil，不抛错不崩）

    /// 无 T 分隔的纯日期串 → nil。
    func testNilWhenSeparatorMissing() {
        XCTAssertNil(ISOTimeStringDecoder.date(from: "2026-09-11", utcOffsetSeconds: 0))
    }

    /// 非数字分量 → nil。
    func testNilWhenComponentNotNumeric() {
        XCTAssertNil(ISOTimeStringDecoder.date(from: "2026-XX-11T05:53", utcOffsetSeconds: 0))
        XCTAssertNil(ISOTimeStringDecoder.date(from: "2026-09-11Taa:53", utcOffsetSeconds: 0))
    }

    /// 空串 / 纯空白 → nil。
    func testNilWhenStringEmptyOrWhitespace() {
        XCTAssertNil(ISOTimeStringDecoder.date(from: "", utcOffsetSeconds: 0))
        XCTAssertNil(ISOTimeStringDecoder.date(from: "   ", utcOffsetSeconds: 0))
    }

    /// 非法日期（13 月 / 32 日）→ Calendar 判 nil（有效性不由本项目裁定）。
    func testNilWhenDateComponentsInvalid() {
        XCTAssertNil(ISOTimeStringDecoder.date(from: "2026-13-01T05:53", utcOffsetSeconds: 0))
        XCTAssertNil(ISOTimeStringDecoder.date(from: "2026-09-32T05:53", utcOffsetSeconds: 0))
    }

    /// 时段缺分（只有小时）→ nil。
    func testNilWhenTimePartIncomplete() {
        XCTAssertNil(ISOTimeStringDecoder.date(from: "2026-09-11T05", utcOffsetSeconds: 0))
    }

    /// 闰日格式：2024-02-29 合法（闰年）。
    func testDateWhenLeapDay() throws {
        let date = try XCTUnwrap(ISOTimeStringDecoder.date(
            from: "2024-02-29T06:00", utcOffsetSeconds: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.month, .day], from: date)
        XCTAssertEqual(components.month, 2)
        XCTAssertEqual(components.day, 29)
    }
}

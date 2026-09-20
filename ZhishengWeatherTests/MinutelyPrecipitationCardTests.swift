//
//  MinutelyPrecipitationCardTests.swift
//  ZhishengWeatherTests
//
//  短时降水卡的**概率文案**（P2 / AC-A4 / AC-A5）——纯格式化，不渲染、不联网。
//
//  关键纪律：
//   - 概率 nil（服务端未返回 / 元素 null）→ **不标概率**，绝不冒充 `0%`；
//   - `0%` 是合法读数，必须照原样显示，与 nil 严格区分。
//

import XCTest
@testable import ZhishengWeather

final class MinutelyPrecipitationCardTests: XCTestCase {

    /// AC-A5：概率缺失 → 空串（该柱不标概率），绝不显示 0%。
    func testNilProbabilityRendersNoLabel() {
        XCTAssertEqual(MinutelyPrecipitationCard.probabilityLabel(nil), "",
                       "AC-A5：nil 必须不标概率，绝不冒充 0%")
        XCTAssertNotEqual(MinutelyPrecipitationCard.probabilityLabel(nil), "0%")
    }

    /// `0%` 与 nil 必须区分：真实 0% 照原样显示。
    func testZeroProbabilityRendersZeroPercent() {
        XCTAssertEqual(MinutelyPrecipitationCard.probabilityLabel(0), "0%",
                       "0% 是合法读数，必须显示，不得与 nil 混同")
    }

    func testRoundsToIntegerPercent() {
        XCTAssertEqual(MinutelyPrecipitationCard.probabilityLabel(85.4), "85%")
        XCTAssertEqual(MinutelyPrecipitationCard.probabilityLabel(85.6), "86%")
        XCTAssertEqual(MinutelyPrecipitationCard.probabilityLabel(100), "100%")
        XCTAssertEqual(MinutelyPrecipitationCard.probabilityLabel(0.4), "0%")
    }
}

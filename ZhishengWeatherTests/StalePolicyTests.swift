//
//  StalePolicyTests.swift
//  ZhishengWeatherTests
//
//  陈旧判定的**边界**单测（本轮要求）：阈值恰好 / 略小 / 略大，逐点钉死。
//

import XCTest
@testable import ZhishengWeather

final class StalePolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let threshold: TimeInterval = 30 * 60

    func testDefaultThresholdIsThirtyMinutes() {
        XCTAssertEqual(StalePolicy.defaultThreshold, 30 * 60)
    }

    /// 恰好等于阈值 → **不算**陈旧（判定式为严格大于）。
    func testExactlyAtThresholdIsNotStale() {
        let updated = now.addingTimeInterval(-threshold)
        XCTAssertFalse(StalePolicy.isStale(lastUpdated: updated, now: now, threshold: threshold))
    }

    /// 恰好小于阈值 1 秒 → 不陈旧。
    func testJustUnderThresholdIsNotStale() {
        let updated = now.addingTimeInterval(-(threshold - 1))
        XCTAssertFalse(StalePolicy.isStale(lastUpdated: updated, now: now, threshold: threshold))
    }

    /// 恰好大于阈值 1 秒 → 陈旧。
    func testJustOverThresholdIsStale() {
        let updated = now.addingTimeInterval(-(threshold + 1))
        XCTAssertTrue(StalePolicy.isStale(lastUpdated: updated, now: now, threshold: threshold))
    }

    /// 很新的数据 → 不陈旧。
    func testFreshDataIsNotStale() {
        let updated = now.addingTimeInterval(-60)
        XCTAssertFalse(StalePolicy.isStale(lastUpdated: updated, now: now, threshold: threshold))
    }

    /// 无时间戳 → 视为陈旧（无从证明新鲜）。
    func testNilTimestampIsStale() {
        XCTAssertTrue(StalePolicy.isStale(lastUpdated: nil, now: now, threshold: threshold))
    }

    func testAgeReturnsElapsedSeconds() {
        let age = StalePolicy.age(lastUpdated: now.addingTimeInterval(-120), now: now)
        XCTAssertEqual(age ?? -1, 120, accuracy: 0.001)
    }

    func testAgeIsNilWithoutTimestamp() {
        XCTAssertNil(StalePolicy.age(lastUpdated: nil, now: now))
    }
}

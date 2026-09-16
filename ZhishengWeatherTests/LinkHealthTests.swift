//
//  LinkHealthTests.swift
//  ZhishengWeatherTests
//
//  数据链路健康：状态派生（四态 + 正常/陈旧边界）+ 记录器（尝试与成败分离、保留错误信息）
//  + 手写 JSON fixture 解码（**不**只做「编码后再解码」的同源往返）。
//  纯构造不联网。
//

import XCTest
@testable import ZhishengWeather

final class LinkHealthTests: XCTestCase {

    /// 固定基准时刻（秒，timeIntervalSinceReferenceDate），保证可确定性。
    private let base = Date(timeIntervalSinceReferenceDate: 700_000_000)

    /// 新鲜度窗口取 900s（与主 App 的 15 分钟一致，便于心算）。
    private let window: TimeInterval = 900

    private func record(attempt: Date? = nil,
                        success: Date? = nil,
                        error: String? = nil) -> LinkHealth {
        LinkHealth(identifier: .forecast, displayName: LinkIdentifier.forecast.displayName,
                   lastAttemptAt: attempt, lastSuccessAt: success, lastErrorMessage: error)
    }

    // MARK: - 状态派生：四态

    func testStateNeverAttemptedWhenNoAttempt() {
        let r = record()
        XCTAssertEqual(r.state(now: base, freshnessWindow: window), .neverAttempted)
    }

    /// 只尝试过、从未成功 → 失败（**绝不**判为正常）。
    func testStateFailedWhenAttemptWithoutAnySuccess() {
        let r = record(attempt: base, success: nil, error: "boom")
        XCTAssertEqual(r.state(now: base, freshnessWindow: window), .failed)
    }

    /// 先成功后失败（最近一次尝试晚于最后一次成功）→ 失败。
    func testStateFailedWhenLatestAttemptFailedAfterSuccess() {
        let r = record(attempt: base.addingTimeInterval(60),
                       success: base,
                       error: "boom")
        XCTAssertEqual(r.state(now: base.addingTimeInterval(60), freshnessWindow: window), .failed)
    }

    /// 边界：`now - lastSuccessAt == window`（900s）→ **正常**（含端点）。
    /// 算术：now = base + 900，age = 900 = window ⇒ healthy。
    func testStateHealthyAtBoundaryInclusive() {
        let r = record(attempt: base, success: base)
        XCTAssertEqual(r.state(now: base.addingTimeInterval(window), freshnessWindow: window), .healthy)
    }

    /// 刚过边界：`now - lastSuccessAt == window + 1` → **陈旧**。
    /// 算术：now = base + 901，age = 901 > 900 ⇒ stale。
    func testStateStaleJustPastBoundary() {
        let r = record(attempt: base, success: base)
        XCTAssertEqual(r.state(now: base.addingTimeInterval(window + 1), freshnessWindow: window), .stale)
    }

    /// 「成功但已很旧」→ 陈旧（非失败）：最近一次尝试即成功，只是时间久。
    func testStateStaleWhenSuccessfulButOld() {
        let r = record(attempt: base, success: base)
        XCTAssertEqual(r.state(now: base.addingTimeInterval(3600), freshnessWindow: window), .stale)
    }

    // MARK: - 记录器：尝试与成败分离 / 保留错误

    func testRecorderRecordsAttemptSeparatelyFromOutcome() async {
        let recorder = LinkHealthRecorder()
        await recorder.recordAttempt(.airQuality, at: base)

        let snap = await recorder.snapshot()
        let air = try? XCTUnwrap(snap.first { $0.identifier == .airQuality })
        XCTAssertNotNil(air?.lastAttemptAt, "尝试时刻必须被记录")
        XCTAssertNil(air?.lastSuccessAt, "仅尝试、未成功 → 无成功时刻")
        XCTAssertEqual(air?.state(now: base, freshnessWindow: window), .failed,
                       "只尝试未成功 → 失败（不是正常，也不是从未尝试）")
    }

    func testRecorderRetainsLastErrorMessage() async {
        let recorder = LinkHealthRecorder()
        await recorder.recordFailure(.forecast, at: base, message: "网络错误：超时")

        let snap = await recorder.snapshot()
        let forecast = snap.first { $0.identifier == .forecast }
        XCTAssertEqual(forecast?.lastErrorMessage, "网络错误：超时")
        XCTAssertEqual(forecast?.state(now: base, freshnessWindow: window), .failed)
    }

    func testRecorderSuccessDoesNotClearPriorErrorMessage() async {
        let recorder = LinkHealthRecorder()
        await recorder.recordFailure(.ensemble, at: base, message: "boom")
        await recorder.recordSuccess(.ensemble, at: base.addingTimeInterval(30))

        let snap = await recorder.snapshot()
        let ensemble = snap.first { $0.identifier == .ensemble }
        XCTAssertEqual(ensemble?.lastErrorMessage, "boom", "错误信息保留以便回溯")
        XCTAssertEqual(ensemble?.state(now: base.addingTimeInterval(30), freshnessWindow: window), .healthy)
    }

    func testRecorderSnapshotCoversAllLinksInDeclarationOrder() async {
        let recorder = LinkHealthRecorder()
        await recorder.recordSuccess(.forecast, at: base)

        let snap = await recorder.snapshot()
        XCTAssertEqual(snap.map(\.identifier), LinkIdentifier.allCases,
                       "面板须覆盖全部链路且顺序稳定")
        XCTAssertEqual(snap.count, 5)
        // 未记录的链路 = 从未尝试（而非缺行）。
        let untouched = snap.filter { $0.identifier != .forecast }
        XCTAssertTrue(untouched.allSatisfy { $0.lastAttemptAt == nil })
    }

    // MARK: - 手写 JSON fixture（避免与实现同源的「编码后再解码」往返）

    func testDecodesHandWrittenFixtureWithAllKeys() throws {
        let json = """
        {
          "identifier": "forecast",
          "displayName": "天气预报",
          "lastAttemptAt": 700000000,
          "lastSuccessAt": 700000000,
          "lastErrorMessage": "网络错误：超时"
        }
        """
        let decoded = try JSONDecoder().decode(LinkHealth.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.identifier, .forecast)
        XCTAssertEqual(decoded.displayName, "天气预报")
        XCTAssertEqual(decoded.lastAttemptAt, base)
        XCTAssertEqual(decoded.lastSuccessAt, base)
        XCTAssertEqual(decoded.lastErrorMessage, "网络错误：超时")
    }

    func testDecodesHandWrittenFixtureWithMissingOptionalKeys() throws {
        // 只给必需键：三个 Optional 缺键 → 解码为 nil（合成 Codable，缺键不炸）。
        let json = """
        { "identifier": "geocoding", "displayName": "城市搜索" }
        """
        let decoded = try JSONDecoder().decode(LinkHealth.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.identifier, .geocoding)
        XCTAssertNil(decoded.lastAttemptAt)
        XCTAssertNil(decoded.lastSuccessAt)
        XCTAssertNil(decoded.lastErrorMessage)
        XCTAssertEqual(decoded.state(now: base, freshnessWindow: window), .neverAttempted)
    }
}

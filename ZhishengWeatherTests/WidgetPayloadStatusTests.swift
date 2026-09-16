//
//  WidgetPayloadStatusTests.swift
//  ZhishengWeatherTests
//
//  Widget 载荷解析的纯单测（本轮要求 5/6）：容器不可用 / 缺失 / 损坏 /
//  归属不匹配 / 过旧 / 新鲜 —— 六条分支逐条断言。
//
//  Widget target 不被测试 bundle 引入，故判定下沉到 Core 后在此直接测。
//

import XCTest
@testable import ZhishengWeather

final class WidgetPayloadStatusTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let threshold: TimeInterval = 30 * 60

    private func makePayload(updatedAt: Date) -> SharedWeatherPayload {
        let snapshot = WeatherSnapshot(location: .beijing,
                                       temperature: 23, apparentTemperature: 22,
                                       weatherCode: 1, windSpeed: 2, windDirection: 90,
                                       humidity: 50, isDay: true, hourly: [],
                                       dailyHigh: 25, dailyLow: 15,
                                       fetchedAt: updatedAt)
        return SharedWeatherPayload(snapshot: snapshot, updatedAt: updatedAt)
    }

    /// 容器不可用优先于一切：即便有「好载荷」，也不得当成正常数据。
    func testContainerUnavailableWinsOverLoadedPayload() {
        let resolution = WidgetPayloadResolver.resolve(
            containerAvailable: false,
            loadResult: .loaded(makePayload(updatedAt: now)),
            ownershipMatches: true,
            now: now,
            staleThreshold: threshold)

        XCTAssertNil(resolution.payload)
        XCTAssertEqual(resolution.status, .unavailable)
    }

    func testMissingKeyYieldsMissing() {
        let resolution = WidgetPayloadResolver.resolve(
            containerAvailable: true, loadResult: .missing,
            ownershipMatches: false, now: now, staleThreshold: threshold)

        XCTAssertNil(resolution.payload)
        XCTAssertEqual(resolution.status, .missing)
    }

    /// 键存在但解码失败 → 必须与「暂无数据」区分开，如实说不可用。
    func testCorruptPayloadYieldsUnavailable() {
        let resolution = WidgetPayloadResolver.resolve(
            containerAvailable: true, loadResult: .corrupt,
            ownershipMatches: true, now: now, staleThreshold: threshold)

        XCTAssertNil(resolution.payload)
        XCTAssertEqual(resolution.status, .unavailable)
    }

    /// 归属不匹配 → 不下发（R-C2 / AC-C6：绝不拿别城数据冒充）。
    func testOwnershipMismatchDropsPayload() {
        let resolution = WidgetPayloadResolver.resolve(
            containerAvailable: true,
            loadResult: .loaded(makePayload(updatedAt: now)),
            ownershipMatches: false,
            now: now,
            staleThreshold: threshold)

        XCTAssertNil(resolution.payload)
        XCTAssertEqual(resolution.status, .missing)
    }

    func testFreshOwnedPayloadIsAvailable() {
        let payload = makePayload(updatedAt: now.addingTimeInterval(-60))
        let resolution = WidgetPayloadResolver.resolve(
            containerAvailable: true, loadResult: .loaded(payload),
            ownershipMatches: true, now: now, staleThreshold: threshold)

        XCTAssertEqual(resolution.payload, payload)
        XCTAssertEqual(resolution.status, .available)
    }

    /// 过旧：**仍下发数据**（继续展示），但状态标为 stale。
    func testStaleOwnedPayloadKeepsDataButIsFlagged() {
        let payload = makePayload(updatedAt: now.addingTimeInterval(-(threshold + 1)))
        let resolution = WidgetPayloadResolver.resolve(
            containerAvailable: true, loadResult: .loaded(payload),
            ownershipMatches: true, now: now, staleThreshold: threshold)

        XCTAssertEqual(resolution.payload, payload, "过旧也必须继续展示缓存数据，只是加标注")
        XCTAssertEqual(resolution.status, .stale)
    }
}

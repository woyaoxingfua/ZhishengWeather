//
//  SpotlightIndexerTests.swift
//  ZhishengWeatherTests
//
//  索引器单测（Spy 注入，**不触碰**真实 CSSearchableIndex —— 那会污染
//  设备 / 模拟器的系统索引）：
//   - 索引不可用时**直接跳过**（模拟器 / 受限环境）：零系统调用、不抛错；
//   - 可用时：先按域清空（清掉已删城市的陈旧条目）再写入当前集合；
//   - 系统写入失败：错误上抛（不静默），交由调用方决定是否提示；
//   - 写入的内容由 Core 组装（有无温度看快照），本处只验证搬运条数。
//

import XCTest
@testable import ZhishengWeather

/// 可编程 Spy：记录调用序列，可控制可用性与失败。
private final class SpySearchIndexWriter: SearchIndexWriting, @unchecked Sendable {

    var available: Bool = true
    var failNext: Bool = false

    private(set) var indexedItems: [WeatherSpotlightItem] = []
    private(set) var deletedIdentifiers: [String] = []
    private(set) var deletedDomains: [String] = []

    var isIndexingAvailable: Bool { available }

    func indexSearchableItems(_ items: [WeatherSpotlightItem]) async throws {
        if failNext { throw SpyIndexError.simulated }
        indexedItems = items
    }

    func deleteSearchableItems(withIdentifiers identifiers: [String]) async throws {
        if failNext { throw SpyIndexError.simulated }
        deletedIdentifiers.append(contentsOf: identifiers)
    }

    func deleteSearchableItems(withDomainIdentifiers domainIdentifiers: [String]) async throws {
        if failNext { throw SpyIndexError.simulated }
        deletedDomains.append(contentsOf: domainIdentifiers)
    }

    enum SpyIndexError: Error {
        case simulated
    }
}

final class SpotlightIndexerTests: XCTestCase {

    // MARK: - Helpers

    private func city(_ name: String, lat: Double, lon: Double) -> City {
        City(name: name, latitude: lat, longitude: lon, isCurrentLocation: false)
    }

    private func snapshot(temperature: Double = 20) -> WeatherSnapshot {
        WeatherSnapshot(location: .beijing,
                        temperature: temperature,
                        apparentTemperature: temperature,
                        weatherCode: 1,
                        windSpeed: 2,
                        windDirection: 90,
                        humidity: 50,
                        isDay: true,
                        hourly: [HourlyPoint(time: Date(),
                                             temperature: temperature,
                                             weatherCode: 1)],
                        dailyHigh: 25,
                        dailyLow: 15,
                        fetchedAt: Date())
    }

    // MARK: - 不可用 → 跳过

    func testIndexingUnavailableSkipsAllSystemCalls() async throws {
        let spy = SpySearchIndexWriter()
        spy.available = false
        let indexer = SpotlightIndexer(writer: spy)

        // 跳过是正确行为而非故障：不抛错，调用方无需处理。
        try await indexer.index(cities: [city("杭州", lat: 30.25, lon: 120.17)],
                                snapshotByCityID: [:])

        XCTAssertTrue(spy.indexedItems.isEmpty, "不可用时绝不做写入调用")
        XCTAssertTrue(spy.deletedDomains.isEmpty, "不可用时绝不做删除调用")
    }

    // MARK: - 可用 → 先清域再写入

    func testIndexClearsDomainThenWritesCurrentCities() async throws {
        let spy = SpySearchIndexWriter()
        let indexer = SpotlightIndexer(writer: spy)
        let hangzhou: City = city("杭州", lat: 30.25, lon: 120.17)
        let beijing: City = city("北京", lat: 39.9042, lon: 116.4074)

        try await indexer.index(cities: [hangzhou, beijing],
                                snapshotByCityID: [hangzhou.id: snapshot()])

        XCTAssertEqual(spy.deletedDomains, [WeatherSpotlight.domainIdentifier],
                       "写入前先清域，避免已删城市留下点了没反应的陈旧条目")
        XCTAssertEqual(spy.indexedItems.count, 2)
        XCTAssertEqual(spy.indexedItems.map { $0.cityID }, [hangzhou.id, beijing.id])
    }

    func testIndexEmptyCityListDoesNotTouchSystemIndex() async throws {
        let spy = SpySearchIndexWriter()
        let indexer = SpotlightIndexer(writer: spy)

        try await indexer.index(cities: [], snapshotByCityID: [:])

        XCTAssertTrue(spy.deletedDomains.isEmpty)
        XCTAssertTrue(spy.indexedItems.isEmpty)
    }

    // MARK: - 失败上抛（不静默）

    func testIndexFailureIsThrownToCaller() async {
        let spy = SpySearchIndexWriter()
        spy.failNext = true
        let indexer = SpotlightIndexer(writer: spy)

        do {
            try await indexer.index(cities: [city("杭州", lat: 30.25, lon: 120.17)],
                                    snapshotByCityID: [:])
            XCTFail("系统写入失败时必须上抛，不能静默吞掉")
        } catch {
            // 调用方（ContentView）只打印：索引失败绝不影响取数主链路。
            XCTAssertTrue(error is SpySearchIndexWriter.SpyIndexError)
        }
    }

    // MARK: - 删除

    func testRemoveAllClearsOwnDomainOnly() async throws {
        let spy = SpySearchIndexWriter()
        let indexer = SpotlightIndexer(writer: spy)

        try await indexer.removeAll()

        XCTAssertEqual(spy.deletedDomains, [WeatherSpotlight.domainIdentifier])
    }

    func testRemoveIdentifiersSkipsWhenUnavailable() async throws {
        let spy = SpySearchIndexWriter()
        spy.available = false
        let indexer = SpotlightIndexer(writer: spy)

        try await indexer.remove(identifiers: ["com.zhisheng.weather.city.39.90,116.41"])

        XCTAssertTrue(spy.deletedIdentifiers.isEmpty, "不可用时删除也应整体跳过")
    }
}

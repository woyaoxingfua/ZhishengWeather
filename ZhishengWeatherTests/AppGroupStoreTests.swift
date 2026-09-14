//
//  AppGroupStoreTests.swift
//  ZhishengWeatherTests
//
//  注入临时 suite（测试 bundle 无 App Group 权限）：
//  往返一致性、updatedAt、clear、空态，以及**损坏 JSON 必须返回 nil 而非崩溃**（硬要求）。
//

import XCTest
@testable import ZhishengWeather

final class AppGroupStoreTests: XCTestCase {

    private var suiteName: String = ""
    private var defaults: UserDefaults?
    private var store: AppGroupStore?

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 临时 suite：避免依赖真实 App Group entitlement。
        // 必须确保拿到真实 suite（否则 AppGroupStore 会回退 .standard，污染全局域）。
        let name = "zs.test.\(UUID().uuidString)"
        suiteName = name
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name),
                                     "无法创建临时 UserDefaults suite")
        self.defaults = defaults
        self.store = AppGroupStore(defaults: defaults)
    }

    override func tearDown() {
        if let defaults, !suiteName.isEmpty {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        store = nil
        suiteName = ""
        super.tearDown()
    }

    // MARK: - 共享常量（P0-7 AC①）

    func testAppGroupConstants() {
        XCTAssertEqual(AppGroup.identifier, "group.com.zhisheng.weather")
        XCTAssertFalse(AppGroup.payloadKey.isEmpty)
    }

    // MARK: - 往返

    func testSaveAndLoadRoundTrip() throws {
        let store = try XCTUnwrap(store)
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_500)
        let snapshot = Self.sampleSnapshot(fetchedAt: fetchedAt)
        try store.save(SharedWeatherPayload(snapshot: snapshot, updatedAt: updatedAt))

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.snapshot.temperature, snapshot.temperature, accuracy: 0.001)
        XCTAssertEqual(loaded.snapshot.location.name, "北京")
        XCTAssertEqual(loaded.snapshot.hourly.count, snapshot.hourly.count)
        XCTAssertEqual(loaded.snapshot.hourly.first?.time, fetchedAt)
        XCTAssertEqual(loaded.snapshot.dailyHigh, snapshot.dailyHigh, accuracy: 0.001)
        XCTAssertEqual(loaded.updatedAt.timeIntervalSince1970, updatedAt.timeIntervalSince1970, accuracy: 1)
    }

    func testSaveSnapshotAtDate() throws {
        let store = try XCTUnwrap(store)
        let snapshot = Self.sampleSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let writtenAt = Date(timeIntervalSince1970: 1_700_003_600)
        try store.save(snapshot: snapshot, at: writtenAt)

        let updatedAt = try XCTUnwrap(store.updatedAt)
        XCTAssertEqual(updatedAt.timeIntervalSince1970, writtenAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertNotNil(store.loadSnapshot())
    }

    func testSaveRoundTripsEmptyHourly() throws {
        let store = try XCTUnwrap(store)
        let snapshot = Self.sampleSnapshot(fetchedAt: Date(), hourly: [])
        try store.save(snapshot: snapshot, at: Date())

        let loaded = try XCTUnwrap(store.loadSnapshot())
        XCTAssertTrue(loaded.hourly.isEmpty)
        XCTAssertEqual(loaded.dailyHigh, snapshot.dailyHigh, accuracy: 0.001)
    }

    func testSaveTwiceKeepsLatest() throws {
        let store = try XCTUnwrap(store)
        try store.save(snapshot: Self.sampleSnapshot(fetchedAt: Date(), temperature: 10),
                       at: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save(snapshot: Self.sampleSnapshot(fetchedAt: Date(), temperature: 30),
                       at: Date(timeIntervalSince1970: 1_700_007_200))

        let loaded = try XCTUnwrap(store.loadSnapshot())
        XCTAssertEqual(loaded.temperature, 30, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(store.updatedAt).timeIntervalSince1970, 1_700_007_200, accuracy: 1)
    }

    // MARK: - 损坏数据（硬要求：返回 nil，不崩）

    func testLoadReturnsNilForCorruptedJSON() throws {
        let store = try XCTUnwrap(store)
        let defaults = try XCTUnwrap(defaults)
        defaults.set(Data("{ this is not valid json".utf8), forKey: AppGroup.payloadKey)

        XCTAssertNil(store.load())
        XCTAssertNil(store.loadSnapshot())
        XCTAssertNil(store.updatedAt)
    }

    func testLoadReturnsNilForTruncatedJSON() throws {
        let store = try XCTUnwrap(store)
        let defaults = try XCTUnwrap(defaults)
        defaults.set(Data(#"{"snapshot": {"temperature": 1.0"#.utf8), forKey: AppGroup.payloadKey)

        XCTAssertNil(store.load(), "截断的 JSON 必须安全回退为 nil")
    }

    func testLoadReturnsNilForValidJSONWithWrongShape() throws {
        let store = try XCTUnwrap(store)
        let defaults = try XCTUnwrap(defaults)
        defaults.set(Data(#"{"foo": 1, "bar": [2, 3]}"#.utf8), forKey: AppGroup.payloadKey)

        XCTAssertNil(store.load(), "结构不匹配的合法 JSON 必须安全回退为 nil")
    }

    func testLoadReturnsNilWhenStoredValueIsNotData() throws {
        let store = try XCTUnwrap(store)
        let defaults = try XCTUnwrap(defaults)
        defaults.set("a plain string, not data", forKey: AppGroup.payloadKey)

        XCTAssertNil(store.load())
    }

    func testCorruptedPayloadCanBeOverwrittenByGoodOne() throws {
        let store = try XCTUnwrap(store)
        let defaults = try XCTUnwrap(defaults)
        defaults.set(Data("garbage".utf8), forKey: AppGroup.payloadKey)
        XCTAssertNil(store.load())

        try store.save(snapshot: Self.sampleSnapshot(fetchedAt: Date()), at: Date())
        XCTAssertNotNil(store.load())
    }

    // MARK: - 清空

    func testClearRemovesPayload() throws {
        let store = try XCTUnwrap(store)
        let snapshot = Self.sampleSnapshot(fetchedAt: Date())
        try store.save(snapshot: snapshot, at: Date())
        XCTAssertNotNil(store.load())

        store.clear()

        XCTAssertNil(store.load())
        XCTAssertNil(store.loadSnapshot())
        XCTAssertNil(store.updatedAt)
    }

    func testClearIsIdempotent() throws {
        let store = try XCTUnwrap(store)
        store.clear()
        store.clear()
        XCTAssertNil(store.load())
    }

    // MARK: - 空态与隔离

    func testLoadReturnsNilWhenEmpty() throws {
        let store = try XCTUnwrap(store)
        XCTAssertNil(store.load())
        XCTAssertNil(store.loadSnapshot())
        XCTAssertNil(store.updatedAt)
    }

    func testStoresInDifferentSuitesAreIsolated() throws {
        let store = try XCTUnwrap(store)
        try store.save(snapshot: Self.sampleSnapshot(fetchedAt: Date()), at: Date())
        XCTAssertNotNil(store.load())

        let otherName = "zs.test.other.\(UUID().uuidString)"
        let otherDefaults = UserDefaults(suiteName: otherName)
        defer { otherDefaults?.removePersistentDomain(forName: otherName) }
        let other = AppGroupStore(defaults: otherDefaults)

        XCTAssertNil(other.load(), "不同 suite 之间不应串数据")
    }

    // MARK: - F-B：城市目录持久化（独立双 key，D-1）
    //  读取结果三分支裁定：missing（键缺失）/ corrupt（坏 JSON）/ loaded（解码成功）

    func testCitiesRoundTrip() throws {
        let store = try XCTUnwrap(store)
        let cities = [
            City.beijingDefault,
            City(name: "杭州", latitude: 30.25, longitude: 120.17, isCurrentLocation: false,
                 country: "中国", admin1: "浙江", timeZoneIdentifier: "Asia/Shanghai")
        ]
        try store.saveCities(cities)

        guard case .loaded(let loaded) = store.loadCities() else {
            return XCTFail("已合法写入的数据必须以 .loaded 读回")
        }
        XCTAssertEqual(loaded, cities, "城市列表必须往返等值（含可选字段）")
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[1].admin1, "浙江")
        XCTAssertEqual(loaded[1].timeZoneIdentifier, "Asia/Shanghai")
    }

    func testSelectedCityIDRoundTrip() throws {
        let store = try XCTUnwrap(store)
        try store.saveSelectedCityID("39.90,116.41")

        XCTAssertEqual(store.selectedCityID, "39.90,116.41")
    }

    func testMissingKeyYieldsMissingResult() throws {
        let store = try XCTUnwrap(store)
        // 临时 suite 无键 → .missing（未初始化语义，调用方应立即落盘初始目录）。
        XCTAssertEqual(store.loadCities(), .missing)
        XCTAssertNil(store.selectedCityID)
    }

    func testCorruptCitiesJSONYieldsCorruptResultAndDoesNotBreakSave() throws {
        let store = try XCTUnwrap(store)
        let defaults = try XCTUnwrap(defaults)
        // 先写入合法数据。
        let cities = [City.beijingDefault]
        try store.saveCities(cities)

        // 再写坏 JSON（模拟半截写入/损坏）→ 属于 corrupt，而非 missing。
        defaults.set(Data("[{ not valid json".utf8), forKey: AppGroup.citiesKey)
        XCTAssertEqual(store.loadCities(), .corrupt, "坏 JSON 必须判为 corrupt，绝不清空/崩溃")

        // 重新合法写入后必须恢复正常（"不要因解码失败而清空用户数据"的数据面保证）。
        try store.saveCities(cities)
        guard case .loaded(let restored) = store.loadCities() else {
            return XCTFail("重新写入的合法数据必须以 .loaded 读回")
        }
        XCTAssertEqual(restored, cities)
    }

    func testLoadCitiesDistinguishesMissingFromCorrupt() throws {
        let store = try XCTUnwrap(store)
        let defaults = try XCTUnwrap(defaults)

        // ① 键缺失 → .missing。
        defaults.removeObject(forKey: AppGroup.citiesKey)
        XCTAssertEqual(store.loadCities(), .missing)

        // ② 键存在但为坏 JSON → .corrupt（半截写入）。
        defaults.set(Data("[{ not valid json".utf8), forKey: AppGroup.citiesKey)
        XCTAssertEqual(store.loadCities(), .corrupt)

        // ③ 键存在、JSON 合法但形状不匹配（非 [City]）→ 同样判为 .corrupt。
        defaults.set(Data(#"{"foo": 1, "bar": [2, 3]}"#.utf8), forKey: AppGroup.citiesKey)
        XCTAssertEqual(store.loadCities(), .corrupt)

        // ④ 合法数据 → .loaded 且等值。
        let cities = [City.beijingDefault]
        try store.saveCities(cities)
        XCTAssertEqual(store.loadCities(), .loaded(cities))
    }

    func testCorruptCitiesLoadDoesNotModifyStoredBytes() throws {
        let store = try XCTUnwrap(store)
        let defaults = try XCTUnwrap(defaults)
        // 裁定的"字节保全"：corrupt 读取路径绝不改写既有字节。
        let corruptBytes = Data("[{ not valid json".utf8)
        defaults.set(corruptBytes, forKey: AppGroup.citiesKey)

        XCTAssertEqual(store.loadCities(), .corrupt)
        XCTAssertEqual(defaults.data(forKey: AppGroup.citiesKey), corruptBytes,
                       "读取路径绝不改写既有字节（留待用户显式操作时修正）")
    }

    // MARK: - PendingForceRefresh 标志位（A1-7 Widget 强刷）

    func testConsumeWithoutMarkReturnsFalse() throws {
        let store = try XCTUnwrap(store)
        XCTAssertFalse(store.consumePendingForceRefresh(), "未标记时消费应为 false")
    }

    func testMarkThenConsumeReturnsTrueExactlyOnce() throws {
        let store = try XCTUnwrap(store)
        store.markPendingForceRefresh()
        XCTAssertTrue(store.consumePendingForceRefresh(), "标记后首次消费应为 true")
        XCTAssertFalse(store.consumePendingForceRefresh(), "消费一次后应被清除，再次消费为 false")
        XCTAssertFalse(store.consumePendingForceRefresh(), "连续多次消费保持 false（幂等）")
    }

    func testMarkUsesIndependentKeyAndDoesNotDisturbExistingData() throws {
        let store = try XCTUnwrap(store)
        // 标志位使用独立 key，不应污染 payload / cities / selectedCityID 既有数据。
        let snapshot = Self.sampleSnapshot(fetchedAt: Date())
        try store.save(snapshot: snapshot, at: Date())
        try store.saveCities([City.beijingDefault])
        try store.saveSelectedCityID(City.beijingDefault.id)

        store.markPendingForceRefresh()
        XCTAssertTrue(store.consumePendingForceRefresh())

        XCTAssertNotNil(store.loadSnapshot(), "标志位写入/消费不应清除天气载荷")
        guard case .loaded = store.loadCities() else {
            return XCTFail("标志位不应清除城市列表")
        }
        XCTAssertEqual(store.selectedCityID, City.beijingDefault.id)
    }

    // MARK: - 写后回读校验（防静默失败，A1 修复批）

    func testSavePayloadRoundTripWithVerification() throws {
        let store = try XCTUnwrap(store)
        let snapshot = Self.sampleSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNoThrow(try store.save(snapshot: snapshot, at: Date()),
                         "写后回读校验应成功（内存 suite 立即可读回）")
        XCTAssertNotNil(store.loadSnapshot())
    }

    func testSaveCitiesRoundTripWithVerification() throws {
        let store = try XCTUnwrap(store)
        let cities = [City.beijingDefault,
                      City(name: "杭州", latitude: 30.25, longitude: 120.17, isCurrentLocation: false)]
        XCTAssertNoThrow(try store.saveCities(cities))
        guard case .loaded(let loaded) = store.loadCities() else {
            return XCTFail("城市列表写后回读应成功")
        }
        XCTAssertEqual(loaded, cities)
    }

    func testSaveSelectedCityIDRoundTripWithVerification() throws {
        let store = try XCTUnwrap(store)
        XCTAssertNoThrow(try store.saveSelectedCityID("39.90,116.41"))
        XCTAssertEqual(store.selectedCityID, "39.90,116.41")
    }

    // MARK: - Helpers

    private static func sampleSnapshot(fetchedAt: Date,
                                       temperature: Double = 23.4,
                                       hourly: [HourlyPoint]? = nil) -> WeatherSnapshot {
        let points = hourly ?? [
            HourlyPoint(time: fetchedAt, temperature: 23.4, weatherCode: 2),
            HourlyPoint(time: fetchedAt.addingTimeInterval(3_600), temperature: 22.1, weatherCode: 3)
        ]
        return WeatherSnapshot(
            location: .beijing,
            temperature: temperature,
            apparentTemperature: 21.0,
            weatherCode: 2,
            windSpeed: 3.2,
            windDirection: 135,
            humidity: 58,
            isDay: true,
            hourly: points,
            dailyHigh: 26.1,
            dailyLow: 15.2,
            fetchedAt: fetchedAt
        )
    }
}

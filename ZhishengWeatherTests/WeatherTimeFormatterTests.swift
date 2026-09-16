//
//  WeatherTimeFormatterTests.swift
//  ZhishengWeatherTests
//
//  D-4（异地城市时区）：时区裁定 + 格式化决策的纯单测。
//   - IANA 标识 → TimeZone；nil / 非法标识 → 设备时区；
//   - 城市 → 时区；无选中城市 → 设备时区；
//   - 同一绝对时刻在 上海 / 纽约 下渲染结果必须不同（时区生效）；
//   - 格式器按 (格式, 时区) 缓存复用（禁止逐行新建）；
//   - VM 派生属性 selectedTimeZone 随选中城市变化（方案 b）。
//

import XCTest
@testable import ZhishengWeather

@MainActor
final class WeatherTimeFormatterTests: XCTestCase {

    // MARK: - 纯裁定：IANA 标识 → TimeZone

    func testResolveTimeZoneUsesValidIdentifier() {
        XCTAssertEqual(WeatherTimeFormatter.resolveTimeZone(identifier: "Asia/Shanghai").identifier,
                       "Asia/Shanghai")
        XCTAssertEqual(WeatherTimeFormatter.resolveTimeZone(identifier: "America/New_York").identifier,
                       "America/New_York")
    }

    func testResolveTimeZoneFallsBackToCurrentForNilOrInvalid() {
        XCTAssertEqual(WeatherTimeFormatter.resolveTimeZone(identifier: nil).identifier,
                       TimeZone.current.identifier,
                       "缺省时区 → 设备时区（保持既有行为）")
        XCTAssertEqual(WeatherTimeFormatter.resolveTimeZone(identifier: "Not/ARealZone").identifier,
                       TimeZone.current.identifier,
                       "非法 IANA 标识 → 设备时区，绝不崩")
    }

    func testTimeZoneForCityUsesCityIdentifierAndNilFallsBack() {
        let foreign = City(name: "纽约", latitude: 40.71, longitude: -74.01,
                           isCurrentLocation: false, timeZoneIdentifier: "America/New_York")
        XCTAssertEqual(WeatherTimeFormatter.timeZone(for: foreign).identifier, "America/New_York",
                       "城市时区必须取自 City.timeZoneIdentifier")

        let beijingWithoutTZ = City(name: "北京", latitude: 39.90, longitude: 116.41,
                                    isCurrentLocation: false)
        XCTAssertEqual(WeatherTimeFormatter.timeZone(for: beijingWithoutTZ).identifier,
                       TimeZone.current.identifier,
                       "城市无时区字段 → 设备时区")

        XCTAssertEqual(WeatherTimeFormatter.timeZone(for: nil).identifier,
                       TimeZone.current.identifier,
                       "无选中城市 → 设备时区")
    }

    // MARK: - 格式化决策：同一时刻在不同时区渲染结果必须不同

    func testFormattingDecisionVariesByTimeZone() throws {
        // 固定绝对时刻（epoch），避开"当前时间"依赖，保证可重复。
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))

        let sh = WeatherTimeFormatter.string(from: date, format: "HH:mm", timeZone: shanghai)
        let ny = WeatherTimeFormatter.string(from: date, format: "HH:mm", timeZone: newYork)

        XCTAssertNotEqual(sh, ny, "同一时刻在 上海 / 纽约 下的小时渲染必须不同（时区生效）")
        XCTAssertEqual(sh.count, 5)
        XCTAssertEqual(ny.count, 5)
    }

    func testStringWithResolvedNilMatchesDeviceTimeZone() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let direct = WeatherTimeFormatter.string(from: date, format: "HH:mm", timeZone: .current)
        let viaNil = WeatherTimeFormatter.string(
            from: date, format: "HH:mm",
            timeZone: WeatherTimeFormatter.resolveTimeZone(identifier: nil))
        XCTAssertEqual(direct, viaNil, "resolveTimeZone(nil) 必须等价于设备时区")
    }

    // MARK: - 格式器缓存（禁止逐行新建）

    func testFormatterCacheReusesInstances() throws {
        let tz = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let a = WeatherTimeFormatter.formatter(format: "HH:mm", timeZone: tz)
        let b = WeatherTimeFormatter.formatter(format: "HH:mm", timeZone: tz)
        XCTAssertTrue(a === b, "同一 (格式, 时区) 必须复用同一 DateFormatter 实例")
    }

    /// 缓存键必须是**解析后的时区标识**，而不是 `.current` 这类哨兵字面量：
    /// 以 `.current` 取值与显式构造同一标识的时区，必须命中**同一实例**。
    /// 同时缓存实例持有的时区必须是解析后的具体值。
    func testFormatterCacheKeyUsesResolvedTimeZoneIdentifier() throws {
        let viaCurrent = WeatherTimeFormatter.formatter(format: "HH:mm", timeZone: .current)
        let explicit = try XCTUnwrap(TimeZone(identifier: TimeZone.current.identifier))
        let viaExplicit = WeatherTimeFormatter.formatter(format: "HH:mm", timeZone: explicit)

        XCTAssertTrue(viaCurrent === viaExplicit,
                      "键 = 解析后标识；同一标识必命中同一实例")
        XCTAssertEqual(viaCurrent.timeZone.identifier, TimeZone.current.identifier,
                       "缓存实例持有解析后的具体时区（非自动更新哨兵）")
    }

    /// 键含「格式」维度：同一时区、不同格式 → 不同实例。
    func testFormatterCacheKeyIncludesFormat() throws {
        let tz = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let hourMinute = WeatherTimeFormatter.formatter(format: "HH:mm", timeZone: tz)
        let monthDay = WeatherTimeFormatter.formatter(format: "M月d日", timeZone: tz)
        XCTAssertFalse(hourMinute === monthDay, "不同格式必须各自独立缓存")
    }

    /// 键含「时区」维度：同一格式、不同时区 → 不同实例（否则会串时区渲染）。
    func testFormatterCacheSeparatesDifferentTimeZones() throws {
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let sh = WeatherTimeFormatter.formatter(format: "HH:mm", timeZone: shanghai)
        let ny = WeatherTimeFormatter.formatter(format: "HH:mm", timeZone: newYork)
        XCTAssertFalse(sh === ny, "不同时区必须各自独立缓存")
        XCTAssertEqual(sh.timeZone.identifier, "Asia/Shanghai")
        XCTAssertEqual(ny.timeZone.identifier, "America/New_York")
    }

    // MARK: - VM 派生属性 selectedTimeZone（方案 b）

    func testViewModelSelectedTimeZoneFollowsSelectedCity() throws {
        let suiteName = "zs.test.tz.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppGroupStore(defaults: defaults)

        let newYork = City(name: "纽约", latitude: 40.71, longitude: -74.01,
                           isCurrentLocation: false, timeZoneIdentifier: "America/New_York")
        try store.saveCities([City.beijingDefault, newYork])
        try store.saveSelectedCityID(newYork.id)

        let vm = WeatherViewModel(store: store)
        XCTAssertEqual(vm.selectedTimeZone.identifier, "America/New_York",
                       "selectedTimeZone 必须跟随选中城市")
    }

    func testViewModelSelectedTimeZoneFallsBackWhenCityHasNoTimeZone() throws {
        let suiteName = "zs.test.tz2.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppGroupStore(defaults: defaults)

        try store.saveCities([City.beijingDefault])   // 北京无时区字段
        try store.saveSelectedCityID(City.beijingDefault.id)

        let vm = WeatherViewModel(store: store)
        XCTAssertEqual(vm.selectedTimeZone.identifier, TimeZone.current.identifier,
                       "城市无时区 → 设备时区（既有行为）")
    }

    // MARK: - D-4 app 侧接线：两个城市时区 → 同一时刻渲染不同（经 VM 透传）

    /// 同一绝对时刻，经两个不同城市选中态派生的 `selectedTimeZone` 渲染，结果必须不同
    /// ——即 App 侧（逐小时条 / 逐日行 / 设置页）改走 VM 透传的时区后，异地城市时间才正确。
    func testSameInstantFormatsDifferentlyAcrossCityTimeZonesViaViewModel() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let shanghai = City(name: "上海", latitude: 31.23, longitude: 121.47,
                            isCurrentLocation: false, timeZoneIdentifier: "Asia/Shanghai")
        let newYork = City(name: "纽约", latitude: 40.71, longitude: -74.01,
                           isCurrentLocation: false, timeZoneIdentifier: "America/New_York")

        let shSuite = "zs.test.tz.sh.\(UUID().uuidString)"
        let nySuite = "zs.test.tz.ny.\(UUID().uuidString)"
        let shDefaults = try XCTUnwrap(UserDefaults(suiteName: shSuite))
        let nyDefaults = try XCTUnwrap(UserDefaults(suiteName: nySuite))
        defer {
            shDefaults.removePersistentDomain(forName: shSuite)
            nyDefaults.removePersistentDomain(forName: nySuite)
        }

        let shStore = AppGroupStore(defaults: shDefaults)
        try shStore.saveCities([City.beijingDefault, shanghai])
        try shStore.saveSelectedCityID(shanghai.id)

        let nyStore = AppGroupStore(defaults: nyDefaults)
        try nyStore.saveCities([City.beijingDefault, newYork])
        try nyStore.saveSelectedCityID(newYork.id)

        let vmShanghai = WeatherViewModel(store: shStore)
        let vmNewYork = WeatherViewModel(store: nyStore)

        XCTAssertEqual(vmShanghai.selectedTimeZone.identifier, "Asia/Shanghai")
        XCTAssertEqual(vmNewYork.selectedTimeZone.identifier, "America/New_York")

        let sh = WeatherTimeFormatter.string(from: date, format: "HH:mm",
                                             timeZone: vmShanghai.selectedTimeZone)
        let ny = WeatherTimeFormatter.string(from: date, format: "HH:mm",
                                             timeZone: vmNewYork.selectedTimeZone)

        XCTAssertNotEqual(sh, ny,
                          "同一时刻在两个城市时区下渲染必须不同（D-4 app 侧接线）")
    }
}

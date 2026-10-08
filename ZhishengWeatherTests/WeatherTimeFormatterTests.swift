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

    // MARK: - ISO8601 容错解析（2026-10-08 新增）

    /// 🔴🔴 **本次事故的成因就是这条路径此前零覆盖**：
    ///和风下发的 `forecastTime` / `forecastStartTime` **实测是无秒的**
    ///（`2026-10-08T15:00Z` / `2026-10-07T16:00Z`），
    /// 而 `ISO8601DateFormatter` + `.withInternetDateTime` **要求有秒**
    /// → 解析失败 → 卡片如实退回原始串 → **用户看到 `2026-10-08T15:00Z` 而非 `23:00`**。
    /// 且逐日卡的 `dayText` **一直在犯同一个错**，只是从没有用例碰过它。
    /// → 故此处对每种候选形态**逐一钉死**，防回归。
    ///
    /// ⚠️ 期望时刻统一用 UTC 解读（2026-10-08 15:00Z == 15:00 UTC）。
    func testParseISO8601AcceptsNoSecondsForm() throws {
        let parsed = try XCTUnwrap(WeatherTimeFormatter.parseISO8601("2026-10-08T15:00Z"),
                                   "🔴 实测形态（无秒）必须能解析")
        XCTAssertEqual(WeatherTimeFormatter.string(from: parsed, format: "HH:mm",
                                                   timeZone: TimeZone(secondsFromGMT: 0)!),
                       "15:00")
    }

    /// 带秒形态（逐日 / 其他源可能给全秒）同样必须能解析。
    func testParseISO8601AcceptsWithSecondsForm() throws {
        let parsed = try XCTUnwrap(WeatherTimeFormatter.parseISO8601("2026-10-08T15:00:00Z"))
        XCTAssertEqual(WeatherTimeFormatter.string(from: parsed, format: "HH:mm",
                                                   timeZone: TimeZone(secondsFromGMT: 0)!),
                       "15:00")
    }

    /// 🔴 **同一串必须解析成同一时刻**（回退链不得引入歧义）：
    ///   无秒与带秒两种写法指的是同一个绝对时刻。
    func testParseISO8601NoSecondsAndWithSecondsAgree() throws {
        let a = try XCTUnwrap(WeatherTimeFormatter.parseISO8601("2026-10-08T15:00Z"))
        let b = try XCTUnwrap(WeatherTimeFormatter.parseISO8601("2026-10-08T15:00:00Z"))
        XCTAssertEqual(a.timeIntervalSince1970, b.timeIntervalSince1970, accuracy: 0.001,
                       "两种写法必须解析成同一绝对时刻，否则同一小时会显示成两个时刻")
    }

    /// 带毫秒形态（`.withFractionalSeconds` 单独用反而解析不了无秒形态，故用回退链）。
    func testParseISO8601AcceptsFractionalSecondsForm() throws {
        let parsed = try XCTUnwrap(WeatherTimeFormatter.parseISO8601("2026-10-08T15:00:00.123Z"))
        XCTAssertEqual(WeatherTimeFormatter.string(from: parsed, format: "HH:mm",
                                                   timeZone: TimeZone(secondsFromGMT: 0)!),
                       "15:00")
    }

    /// 数字时区偏移形态（`+08:00`）。
    ///
    /// 🔴 **断言方向曾写反过**（lead 复核时用Python 验算发现）：
    /// `12:00+00:00` 与 `12:00+08:00` 指向的是**相差 8 小时**的两个时刻，
    /// 绝不能断言它们相等（`datetime.fromisoformat` 实测差28800 秒）。
    /// 正确的不变量是：偏移量被**如实计入**，而非被丢弃或反转。
    func testParseISO8601NumericOffsetIsNotIgnored() throws {
        let utcNoon = try XCTUnwrap(WeatherTimeFormatter.parseISO8601("2026-10-08T12:00+00:00"))
        let shanghaiNoon = try XCTUnwrap(WeatherTimeFormatter.parseISO8601("2026-10-08T12:00+08:00"))
        // ⚠️ 曾把断言方向写反过一次（CI run#37761541961 实测失败）：
        // 消息说「必须差 28800」而断言却用了 `XCTAssertEqual(a, b, accuracy:)`，
        // 等于要求两者相等 —— 与自己的意图相反。
        // 正确写法：先断言**差值**是 28800，再单独说明偏移被如实计入。
        XCTAssertEqual(utcNoon.timeIntervalSince1970 - shanghaiNoon.timeIntervalSince1970,
                       28800, accuracy: 0.001,
                       "北京 12:00 比 UTC 12:00 早 8 小时，故 UTC 时间戳应大 28800 秒"
                       + "（实测差 28800 说明偏移被如实计入，未被丢弃或反转）")
    }

    /// `Z` 与 `+00:00` 是**同一个时刻**的两种写法（这条才是真正的等价断言）。
    func testParseISO8601ZuluEqualsPlusZero() throws {
        let zulu = try XCTUnwrap(WeatherTimeFormatter.parseISO8601("2026-10-08T12:00Z"))
        let plusZero = try XCTUnwrap(WeatherTimeFormatter.parseISO8601("2026-10-08T12:00+00:00"))
        XCTAssertEqual(zulu.timeIntervalSince1970, plusZero.timeIntervalSince1970, accuracy: 0.001,
                       "`Z` 与 `+00:00` 都表示 UTC，必须解析成同一绝对时刻")
    }

    /// 解析不了 → **nil**（调用方据此如实退回原始串，绝不编造时刻）。
    func testParseISO8601ReturnsNilForGarbage() {
        XCTAssertNil(WeatherTimeFormatter.parseISO8601("不是时间"))
        XCTAssertNil(WeatherTimeFormatter.parseISO8601(""))
        XCTAssertNil(WeatherTimeFormatter.parseISO8601("   "))
    }
}

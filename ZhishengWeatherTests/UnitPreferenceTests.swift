//
//  UnitPreferenceTests.swift
//  ZhishengWeatherTests
//
//  A3-4 单位换算（AC-A3-8）：℃↔℉、m/s↔km/h。
//  D-2 单位换算：hPa↔mmHg/inHg（独立气压单位）。
//  期望值手算：77℉ = 25×9/5+32；km/h = m/s×3.6；
//  1013.25 hPa = 760.00 mmHg = 29.9213 inHg（定义值锚点）。
//
//  隔离纪律（对齐 AppIconSwitcherTests）：**每个用例只读写自己的独立 suite**
//  （`zs.test.unit.<UUID>`），tearDown 清空该 suite。绝不写 `UserDefaults.standard`，
//  更不写真实 App Group 共享容器——测试进程无该 entitlement 时会静默回落私有
//  容器，断言可能因错误的原因通过，而且会污染 App 与 Widget 共用的真数据。
//

import XCTest
@testable import ZhishengWeather

final class UnitPreferenceTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    /// 被测对象：读与写绑**同一个**注入 store。
    private var preference: UnitPreference!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "zs.test.unit.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        preference = UnitPreference(defaults: defaults)
    }

    override func tearDown() {
        // 清空整个 suite，避免跨用例 / 跨运行残留。
        if let defaults, let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        preference = nil
        super.tearDown()
    }

    // MARK: - 温度换算

    func testCelsiusPassthrough() {
        XCTAssertEqual(preference.displayTemperature(celsius: 25.0), 25.0)
    }

    func testFahrenheitConversion() {
        preference.setTemperatureUnit("fahrenheit")
        // 25℃ = 77℉。
        XCTAssertEqual(preference.displayTemperature(celsius: 25.0), 77.0, accuracy: 0.001)
        // 0℃ = 32℉。
        XCTAssertEqual(preference.displayTemperature(celsius: 0.0), 32.0, accuracy: 0.001)
        // -40 双温等同点。
        XCTAssertEqual(preference.displayTemperature(celsius: -40.0), -40.0, accuracy: 0.001)
    }

    func testTemperatureSymbol() {
        XCTAssertEqual(preference.temperatureSymbol(), "℃")
        preference.setTemperatureUnit("fahrenheit")
        XCTAssertEqual(preference.temperatureSymbol(), "℉")
    }

    // MARK: - 风速换算

    func testWindSpeedMsPassthrough() {
        XCTAssertEqual(preference.displayWindSpeed(ms: 3.2), 3.2)
        XCTAssertEqual(preference.windSpeedSymbol(), "m/s")
    }

    func testWindSpeedKmhConversion() {
        preference.setWindSpeedUnit("kmh")
        // 3.2 m/s × 3.6 = 11.52 km/h。
        XCTAssertEqual(preference.displayWindSpeed(ms: 3.2), 11.52, accuracy: 0.001)
        XCTAssertEqual(preference.windSpeedSymbol(), "km/h")
    }

    // MARK: - 气压换算（D-2）

    /// hPa 恒等：默认单位下不做换算（不回归既有 hPa 展示）。
    func testPressureHPaIdentity() {
        preference.setPressureUnit("hpa")
        XCTAssertEqual(preference.displayPressure(hPa: 1013.25), 1013.25, accuracy: 1e-9)
        XCTAssertEqual(preference.pressureSymbol(), "hPa")
    }

    /// 独立换算锚点：1013.25 hPa = 760.00 mmHg（定义值，独立于实现）。
    func testPressureMmHgConversion() {
        preference.setPressureUnit("mmhg")
        // 1 mmHg = 1.33322387415 hPa → 1013.25 / 1.33322387415 ≈ 760.00。
        XCTAssertEqual(preference.displayPressure(hPa: 1013.25), 760.00, accuracy: 0.01)
        XCTAssertEqual(preference.pressureSymbol(), "mmHg")
    }

    /// 独立换算锚点：1013.25 hPa = 29.9213 inHg（定义值，独立于实现）。
    func testPressureInHgConversion() {
        preference.setPressureUnit("inhg")
        // 1 inHg = 33.86389 hPa → 1013.25 / 33.86389 ≈ 29.9213。
        XCTAssertEqual(preference.displayPressure(hPa: 1013.25), 29.9213, accuracy: 1e-3)
        XCTAssertEqual(preference.pressureSymbol(), "inHg")
    }

    /// 小数位纯函数：hPa 1 位 / mmHg 0 位 / inHg 2 位。
    func testPressureFractionDigits() {
        XCTAssertEqual(UnitPreference.pressureFractionDigits(for: "hpa"), 1)
        XCTAssertEqual(UnitPreference.pressureFractionDigits(for: "mmhg"), 0)
        XCTAssertEqual(UnitPreference.pressureFractionDigits(for: "inhg"), 2)
    }

    /// 缺失键 → 默认 "hpa"（在**自己的 suite** 里删键，不碰共享容器）。
    func testPressureUnitAbsentKeyYieldsHPa() {
        defaults.removeObject(forKey: UnitPreference.pressureKey)
        XCTAssertEqual(preference.pressureUnit(), "hpa")
    }

    /// 未知存储值（如 "bar"）→ 回退 "hpa"，绝不渲染无意义数值。
    func testUnknownPressureUnitFallsBackToHPa() {
        XCTAssertEqual(UnitPreference.normalizedPressureUnit("bar"), "hpa")
        preference.setPressureUnit("bar")
        XCTAssertEqual(preference.pressureUnit(), "hpa")
        XCTAssertEqual(preference.pressureSymbol(), "hPa")
    }

    /// 往返（同 suite 两个实例）：App 写 → Widget 读，同 key 同 store。
    ///
    /// 隔离纪律：写入只落注入的 suite；`UserDefaults.standard` 必须逐字不变
    /// ——这正是「读注入、写硬编码」缺陷（CI run 35206149080）的回归守卫。
    func testPressureUnitRoundTripsThroughInjectedStore() {
        let standardBefore = UserDefaults.standard.string(forKey: UnitPreference.pressureKey)

        preference.setPressureUnit("inhg")
        XCTAssertEqual(preference.pressureUnit(), "inhg")

        // 第二个实例绑同一 suite（模拟 Widget 侧按同 key 读取）。
        let reader = UnitPreference(defaults: defaults)
        XCTAssertEqual(reader.pressureUnit(), "inhg")
        XCTAssertEqual(defaults.string(forKey: UnitPreference.pressureKey), "inhg")

        // 注入缝完整：写只进注入 store，standard 一位都没动。
        XCTAssertEqual(UserDefaults.standard.string(forKey: UnitPreference.pressureKey),
                       standardBefore,
                       "写入不得落到 UserDefaults.standard")
    }

    /// 独立 suite 往返：key 名稳定，写入值可被同 key 读回并正确归一化。
    func testPressureKeyRoundTripsThroughDedicatedSuite() throws {
        let roundTripSuite = "zs.test.unit.key.\(UUID().uuidString)"
        let roundTripDefaults = try XCTUnwrap(UserDefaults(suiteName: roundTripSuite))
        defer { roundTripDefaults.removePersistentDomain(forName: roundTripSuite) }

        roundTripDefaults.set("mmhg", forKey: UnitPreference.pressureKey)
        XCTAssertEqual(roundTripDefaults.string(forKey: UnitPreference.pressureKey), "mmhg")
        XCTAssertEqual(UnitPreference.normalizedPressureUnit(
            roundTripDefaults.string(forKey: UnitPreference.pressureKey)), "mmhg")
    }

    /// 两个独立 suite 互不串味（注入的 store 真的被当作唯一数据源）。
    func testDedicatedSuitesDoNotLeakIntoEachOther() throws {
        let otherSuite = "zs.test.unit.other.\(UUID().uuidString)"
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherSuite))
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }

        preference.setPressureUnit("mmhg")
        XCTAssertEqual(preference.pressureUnit(), "mmhg")

        let other = UnitPreference(defaults: otherDefaults)
        XCTAssertEqual(other.pressureUnit(), "hpa", "另一个 suite 不得读到本 suite 的值")
        XCTAssertNil(otherDefaults.string(forKey: UnitPreference.pressureKey))
    }
}

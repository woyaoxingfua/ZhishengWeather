//
//  UnitPreferenceTests.swift
//  ZhishengWeatherTests
//
//  A3-4 单位换算（AC-A3-8）：℃↔℉、m/s↔km/h。
//  D-2 单位换算：hPa↔mmHg/inHg（独立气压单位）。
//  期望值手算：77℉ = 25×9/5+32；km/h = m/s×3.6；
//  1013.25 hPa = 760.00 mmHg = 29.9213 inHg（定义值锚点）。
//

import XCTest
@testable import ZhishengWeather

final class UnitPreferenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // UnitPreference 走共享容器（AppGroup suite）；CI simulator 有完整
        // entitlement，直接读写真键；tearDown 恢复默认值防跨用例污染。
        UnitPreference.setTemperatureUnit("celsius")
        UnitPreference.setWindSpeedUnit("ms")
        UnitPreference.setPressureUnit("hpa")
    }

    override func tearDown() {
        UnitPreference.setTemperatureUnit("celsius")
        UnitPreference.setWindSpeedUnit("ms")
        UnitPreference.setPressureUnit("hpa")
        super.tearDown()
    }

    // MARK: - 温度换算

    func testCelsiusPassthrough() {
        XCTAssertEqual(UnitPreference.displayTemperature(celsius: 25.0), 25.0)
    }

    func testFahrenheitConversion() {
        UnitPreference.setTemperatureUnit("fahrenheit")
        // 25℃ = 77℉。
        XCTAssertEqual(UnitPreference.displayTemperature(celsius: 25.0), 77.0, accuracy: 0.001)
        // 0℃ = 32℉。
        XCTAssertEqual(UnitPreference.displayTemperature(celsius: 0.0), 32.0, accuracy: 0.001)
        // -40 双温等同点。
        XCTAssertEqual(UnitPreference.displayTemperature(celsius: -40.0), -40.0, accuracy: 0.001)
    }

    func testTemperatureSymbol() {
        XCTAssertEqual(UnitPreference.temperatureSymbol(), "℃")
        UnitPreference.setTemperatureUnit("fahrenheit")
        XCTAssertEqual(UnitPreference.temperatureSymbol(), "℉")
    }

    // MARK: - 风速换算

    func testWindSpeedMsPassthrough() {
        XCTAssertEqual(UnitPreference.displayWindSpeed(ms: 3.2), 3.2)
        XCTAssertEqual(UnitPreference.windSpeedSymbol(), "m/s")
    }

    func testWindSpeedKmhConversion() {
        UnitPreference.setWindSpeedUnit("kmh")
        // 3.2 m/s × 3.6 = 11.52 km/h。
        XCTAssertEqual(UnitPreference.displayWindSpeed(ms: 3.2), 11.52, accuracy: 0.001)
        XCTAssertEqual(UnitPreference.windSpeedSymbol(), "km/h")
    }

    // MARK: - 气压换算（D-2）

    /// hPa 恒等：默认单位下不做换算（不回归既有 hPa 展示）。
    func testPressureHPaIdentity() {
        UnitPreference.setPressureUnit("hpa")
        XCTAssertEqual(UnitPreference.displayPressure(hPa: 1013.25), 1013.25, accuracy: 1e-9)
        XCTAssertEqual(UnitPreference.pressureSymbol(), "hPa")
    }

    /// 独立换算锚点：1013.25 hPa = 760.00 mmHg（定义值，独立于实现）。
    func testPressureMmHgConversion() {
        UnitPreference.setPressureUnit("mmhg")
        // 1 mmHg = 1.33322387415 hPa → 1013.25 / 1.33322387415 ≈ 760.00。
        XCTAssertEqual(UnitPreference.displayPressure(hPa: 1013.25), 760.00, accuracy: 0.01)
        XCTAssertEqual(UnitPreference.pressureSymbol(), "mmHg")
    }

    /// 独立换算锚点：1013.25 hPa = 29.9213 inHg（定义值，独立于实现）。
    func testPressureInHgConversion() {
        UnitPreference.setPressureUnit("inhg")
        // 1 inHg = 33.86389 hPa → 1013.25 / 33.86389 ≈ 29.9213。
        XCTAssertEqual(UnitPreference.displayPressure(hPa: 1013.25), 29.9213, accuracy: 1e-3)
        XCTAssertEqual(UnitPreference.pressureSymbol(), "inHg")
    }

    /// 小数位纯函数：hPa 1 位 / mmHg 0 位 / inHg 2 位。
    func testPressureFractionDigits() {
        XCTAssertEqual(UnitPreference.pressureFractionDigits(for: "hpa"), 1)
        XCTAssertEqual(UnitPreference.pressureFractionDigits(for: "mmhg"), 0)
        XCTAssertEqual(UnitPreference.pressureFractionDigits(for: "inhg"), 2)
    }

    /// 缺失键 → 默认 "hpa"。
    func testPressureUnitAbsentKeyYieldsHPa() {
        UserDefaults(suiteName: AppGroup.identifier)?.removeObject(forKey: UnitPreference.pressureKey)
        XCTAssertEqual(UnitPreference.pressureUnit(), "hpa")
    }

    /// 未知存储值（如 "bar"）→ 回退 "hpa"，绝不渲染无意义数值。
    func testUnknownPressureUnitFallsBackToHPa() {
        XCTAssertEqual(UnitPreference.normalizedPressureUnit("bar"), "hpa")
        UnitPreference.setPressureUnit("bar")
        XCTAssertEqual(UnitPreference.pressureUnit(), "hpa")
        XCTAssertEqual(UnitPreference.pressureSymbol(), "hPa")
    }

    /// 共享容器往返：App 写入的值 = Widget 读到的值（同 suite / 同 key）。
    func testPressureUnitRoundTripThroughSharedContainer() {
        UnitPreference.setPressureUnit("inhg")
        XCTAssertEqual(UnitPreference.pressureUnit(), "inhg")
        let shared = UserDefaults(suiteName: AppGroup.identifier)
        XCTAssertEqual(shared?.string(forKey: UnitPreference.pressureKey), "inhg")
    }

    /// 独立 suite 往返：key 名稳定，写入值可被同 key 读回并正确归一化。
    func testPressureKeyRoundTripsThroughDedicatedSuite() {
        let suiteName = "zs.weather.test.pressure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.set("mmhg", forKey: UnitPreference.pressureKey)
        // 模拟 Widget 侧用同一 key 跨进程读取共享容器。
        XCTAssertEqual(defaults?.string(forKey: UnitPreference.pressureKey), "mmhg")
        XCTAssertEqual(UnitPreference.normalizedPressureUnit(defaults?.string(forKey: UnitPreference.pressureKey)), "mmhg")
        defaults?.removePersistentDomain(forName: suiteName)
    }
}

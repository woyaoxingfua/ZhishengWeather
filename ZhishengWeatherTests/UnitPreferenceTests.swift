//
//  UnitPreferenceTests.swift
//  ZhishengWeatherTests
//
//  A3-4 单位换算（AC-A3-8）：℃↔℉、m/s↔km/h。
//  期望值手算：77℉ = 25×9/5+32；km/h = m/s×3.6。
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
    }

    override func tearDown() {
        UnitPreference.setTemperatureUnit("celsius")
        UnitPreference.setWindSpeedUnit("ms")
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
}

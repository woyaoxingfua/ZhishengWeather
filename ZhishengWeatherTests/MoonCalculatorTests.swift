//
//  MoonCalculatorTests.swift
//  ZhishengWeatherTests
//
//  月相算法（平均朔望月 + 已知新月锚点）：
//   - 常量/锚点自洽（2000-01-06 18:14 UTC、29.530588853d）
//   - illumination 边界 0 / 1、连续性与区间 [0,1]
//   - age 落在 [0, synodicMonth)
//   - 已知朔/上弦/满（2024-01-11 / 01-18 / 01-25）误差 ≤ 1 天
//   - 名称 ↔ SF Symbol 一致性
//
//  以上锚点经天文历法核对属实（2024-01-11 11:57Z 朔、01-18 03:52Z 上弦、01-25 17:54Z 满）。
//

import XCTest
@testable import ZhishengWeather

final class MoonCalculatorTests: XCTestCase {

    private let referenceNewMoon = Date(timeIntervalSince1970: MoonCalculator.referenceNewMoonEpoch)
    private let synodic = MoonCalculator.synodicMonth

    // MARK: - 常量与锚点自洽

    func testAnchorConstantsAreConsistent() throws {
        XCTAssertEqual(MoonCalculator.synodicMonth, 29.530588853, accuracy: 1e-9)
        // 2000-01-06 00:00 UTC = 946684800，+5d +18h14m = 947182440
        XCTAssertEqual(MoonCalculator.referenceNewMoonEpoch, 947_182_440, accuracy: 0.5)

        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute],
                                                 from: referenceNewMoon)
        XCTAssertEqual(components.year, 2000)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 6)
        XCTAssertEqual(components.hour, 18)
        XCTAssertEqual(components.minute, 14)
    }

    // MARK: - illumination 边界与区间

    func testIlluminationIsZeroAtNewMoonAnchor() {
        XCTAssertEqual(MoonCalculator.illumination(for: referenceNewMoon), 0, accuracy: 1e-9)
    }

    func testIlluminationIsOneAtHalfCycle() {
        let fullMoon = referenceNewMoon.addingTimeInterval(synodic / 2 * 86_400)
        XCTAssertEqual(MoonCalculator.illumination(for: fullMoon), 1, accuracy: 1e-9)
    }

    /// 环绕点（周期末尾 ↔ 下一周期开头）应连续趋近 0，不出现跳变或负值。
    func testIlluminationIsContinuousAcrossCycleBoundary() {
        let oneSecondBefore = referenceNewMoon.addingTimeInterval(-1)
        let oneSecondAfter = referenceNewMoon.addingTimeInterval(1)

        let before = MoonCalculator.illumination(for: oneSecondBefore)
        let after = MoonCalculator.illumination(for: oneSecondAfter)

        XCTAssertGreaterThanOrEqual(before, 0)
        XCTAssertGreaterThanOrEqual(after, 0)
        XCTAssertLessThan(before, 1e-6)
        XCTAssertLessThan(after, 1e-6)
    }

    func testIlluminationNeverLeavesUnitRange() {
        let stepsPerDay = 8
        let totalSteps = Int(synodic * Double(stepsPerDay)) * 3   // 覆盖 3 个完整朔望周期
        for step in 0...totalSteps {
            let date = referenceNewMoon.addingTimeInterval(Double(step) / Double(stepsPerDay) * 86_400)
            let value = MoonCalculator.illumination(for: date)
            XCTAssertFalse(value.isNaN, "step=\(step)")
            XCTAssertGreaterThanOrEqual(value, 0, "step=\(step)")
            XCTAssertLessThanOrEqual(value, 1, "step=\(step)")
        }
    }

    /// 锚点之前（负时间）也必须落在 [0,1]，负余数处理正确。
    func testIlluminationInUnitRangeBeforeAnchor() {
        for days in [-1.0, -40.0, -400.0, -9_125.0] {
            let value = MoonCalculator.illumination(for: referenceNewMoon.addingTimeInterval(days * 86_400))
            XCTAssertGreaterThanOrEqual(value, 0, "days=\(days)")
            XCTAssertLessThanOrEqual(value, 1, "days=\(days)")
        }
    }

    func testIlluminationGrowsThenShrinks() {
        let mid = synodic / 2
        let step = synodic / 100

        // 前半周期：严格递增
        var previous = MoonCalculator.illumination(for: referenceNewMoon)
        var age = step
        while age < mid {
            let value = MoonCalculator.illumination(for: referenceNewMoon.addingTimeInterval(age * 86_400))
            XCTAssertGreaterThan(value, previous, "前半周期应递增 age=\(age)")
            previous = value
            age += step
        }

        // 中点附近为峰值
        var peak = MoonCalculator.illumination(for: referenceNewMoon.addingTimeInterval(mid * 86_400))
        XCTAssertGreaterThanOrEqual(peak, previous)

        // 后半周期：严格递减
        age = mid + step
        while age < synodic {
            let value = MoonCalculator.illumination(for: referenceNewMoon.addingTimeInterval(age * 86_400))
            XCTAssertLessThan(value, peak, "后半周期应递减 age=\(age)")
            peak = value
            age += step
        }
    }

    // MARK: - age 区间

    func testAgeIsZeroAtAnchor() {
        XCTAssertEqual(MoonCalculator.age(for: referenceNewMoon), 0, accuracy: 1e-9)
    }

    func testAgeAlwaysWithinSynodicRange() {
        let offsets: [Double] = [-400.0, -29.7, -1.0, 0.0, 0.5,
                                 29.530588852, 29.530588854, 59.1, 365.25, 9_000.0]
        for offset in offsets {
            let date = referenceNewMoon.addingTimeInterval(offset * 86_400)
            let age = MoonCalculator.age(for: date)
            XCTAssertGreaterThanOrEqual(age, 0, "offset=\(offset)")
            XCTAssertLessThan(age, synodic, "offset=\(offset)")
        }
    }

    func testAgeJustBeforeCycleEnd() {
        let end = referenceNewMoon.addingTimeInterval((synodic - 1e-6) * 86_400)
        XCTAssertEqual(MoonCalculator.age(for: end), synodic - 1e-6, accuracy: 1e-4)
    }

    // MARK: - 已知朔望（误差 ≤ 1 天）

    func testKnownNewMoonDate() throws {
        // 真实新月：2024-01-11 11:57 UTC
        let date = try XCTUnwrap(Self.iso("2024-01-11T11:57:00Z"))
        XCTAssertEqual(MoonCalculator.phase(for: date).name, .newMoon)
        XCTAssertLessThan(MoonCalculator.illumination(for: date), 0.01)
    }

    func testKnownNewMoonWithinOneDay() throws {
        let date = try XCTUnwrap(Self.iso("2024-01-11T11:57:00Z"))
        XCTAssertLessThan(MoonCalculator.illumination(for: date.addingTimeInterval(-86_400)), 0.05)
        XCTAssertLessThan(MoonCalculator.illumination(for: date.addingTimeInterval(86_400)), 0.05)
    }

    func testKnownFirstQuarterDate() throws {
        // 真实上弦：2024-01-18 03:52 UTC
        let date = try XCTUnwrap(Self.iso("2024-01-18T03:52:00Z"))
        let phase = MoonCalculator.phase(for: date)
        XCTAssertEqual(phase.name, .firstQuarter)
        XCTAssertGreaterThan(phase.illumination, 0.30)
        XCTAssertLessThan(phase.illumination, 0.70)
    }

    func testKnownFullMoonDate() throws {
        // 真实满月：2024-01-25 17:54 UTC
        let date = try XCTUnwrap(Self.iso("2024-01-25T17:54:00Z"))
        XCTAssertEqual(MoonCalculator.phase(for: date).name, .fullMoon)
        XCTAssertGreaterThan(MoonCalculator.illumination(for: date), 0.99)
    }

    func testKnownFullMoonWithinOneDay() throws {
        let date = try XCTUnwrap(Self.iso("2024-01-25T17:54:00Z"))
        XCTAssertGreaterThan(MoonCalculator.illumination(for: date.addingTimeInterval(-86_400)), 0.96)
        XCTAssertGreaterThan(MoonCalculator.illumination(for: date.addingTimeInterval(86_400)), 0.96)
    }

    // MARK: - 名称 / 符号一致性

    func testPhaseSymbolMatchesPhaseName() throws {
        let date = try XCTUnwrap(Self.iso("2024-01-25T17:54:00Z"))
        let phase = MoonCalculator.phase(for: date)
        XCTAssertEqual(phase.symbolName, phase.name.symbolName)
        XCTAssertEqual(phase.name, .fullMoon)
        XCTAssertEqual(phase.symbolName, "moonphase.full.moon")
    }

    func testAllPhaseNamesHaveUniqueNonEmptySymbols() {
        let names: [MoonPhase.Name] = [.newMoon, .waxingCrescent, .firstQuarter, .waxingGibbous,
                                       .fullMoon, .waningGibbous, .lastQuarter, .waningCrescent]
        var symbols = Set<String>()
        for name in names {
            let symbol = name.symbolName
            XCTAssertFalse(symbol.isEmpty, "\(name.rawValue) 的 SF Symbol 为空")
            XCTAssertTrue(symbol.hasPrefix("moonphase."),
                          "\(name.rawValue) 的符号不是 moonphase.*：\(symbol)")
            symbols.insert(symbol)
        }
        XCTAssertEqual(symbols.count, names.count, "存在重复的月相符号")
    }

    func testIlluminationPercentRounding() {
        XCTAssertEqual(MoonCalculator.phase(for: referenceNewMoon).illuminationPercent, 0)
        let fullMoon = referenceNewMoon.addingTimeInterval(synodic / 2 * 86_400)
        XCTAssertEqual(MoonCalculator.phase(for: fullMoon).illuminationPercent, 100)
    }

    /// 名称分档应以四个象限点为中心（±1/16 周期）。
    func testPhaseNameBands() {
        func name(atFraction fraction: Double) -> MoonPhase.Name {
            let date = referenceNewMoon.addingTimeInterval(fraction * synodic * 86_400)
            return MoonCalculator.phase(for: date).name
        }
        XCTAssertEqual(name(atFraction: 0.00), .newMoon)
        XCTAssertEqual(name(atFraction: 0.02), .newMoon)
        XCTAssertEqual(name(atFraction: 0.24), .firstQuarter)
        XCTAssertEqual(name(atFraction: 0.50), .fullMoon)
        XCTAssertEqual(name(atFraction: 0.75), .lastQuarter)
        XCTAssertEqual(name(atFraction: 0.99), .newMoon)
    }

    // MARK: - Helpers

    private static func iso(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

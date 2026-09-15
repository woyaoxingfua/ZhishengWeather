//
//  MoonCalculatorMoonEventsTests.swift
//  ZhishengWeatherTests
//
//  月出月落引擎（A2-4，AC-A2-12/14）：
//   - 基准：2026-09-15 北京（39.9042,116.4074）月出 01:58 UTC / 月落 12:03 UTC
//     （Python 独立复算同款 Meeus 算法对拍 + 常识粗校：9 月中旬北京月出在上午时段）；
//   - 极地：2026-09-01~06 lat=85 连续无月出落日（Python 扫描确认 23 天无事件），
//     选 09-03 为 (nil, nil) 基准——月球赤纬负值期 85°N 终日不见月（真实天文形态，
//     非算法缺陷）；容差 ±10 分钟（ARCH-A2P1 §1.2 裁定）。
//   - 确定性：无 Date()，全部时刻由参数注入。
//

import XCTest
@testable import ZhishengWeather

final class MoonCalculatorMoonEventsTests: XCTestCase {

    /// 北京坐标。
    private let beijingLat = 39.9042
    private let beijingLon = 116.4074

    /// 2026-09-15 00:00 UTC。
    private var beijingDay: Date {
        Date(timeIntervalSince1970: 1_789_488_000)
    }

    // MARK: - 正常日（北京基准 ±10min）

    func testBeijingMoonRiseMatchesBaseline() throws {
        let (rise, set) = MoonCalculator.moonEvents(for: beijingDay,
                                                    latitude: beijingLat,
                                                    longitude: beijingLon)
        // 基准：01:58 UTC = 1_789_492_680（±600s 容差）。
        let expectedRise = 1_789_492_680.0
        let actualRise = try XCTUnwrap(rise)
        XCTAssertEqual(actualRise.timeIntervalSince1970, expectedRise, accuracy: 600,
                       "北京月出应 ≈ 01:58 UTC（±10min）")
    }

    func testBeijingMoonSetMatchesBaseline() throws {
        let (_, set) = MoonCalculator.moonEvents(for: beijingDay,
                                                 latitude: beijingLat,
                                                 longitude: beijingLon)
        // 基准：12:03 UTC = 1_789_535_? —— 12:03 UTC epoch = 1_789_488_000 + 43_380 = 1_789_531_380。
        let expectedSet = 1_789_531_380.0
        let actualSet = try XCTUnwrap(set)
        XCTAssertEqual(actualSet.timeIntervalSince1970, expectedSet, accuracy: 600,
                       "北京月落应 ≈ 12:03 UTC（±10min）")
    }

    func testRiseBeforeSetOnNormalDay() throws {
        let (rise, set) = MoonCalculator.moonEvents(for: beijingDay,
                                                    latitude: beijingLat,
                                                    longitude: beijingLon)
        XCTAssertLessThan(try XCTUnwrap(rise), try XCTUnwrap(set))
    }

    // MARK: - 极地边界（AC-A2-14：nil 不崩、不渲染坏时间）

    func testPolarDayReturnsNilPair() throws {
        // 2026-09-03 lat=85：Python 扫描确认全天无 -0.833° 穿越（月球赤纬负值期）。
        let polarDay = Date(timeIntervalSince1970: 1_787_846_400)  // 2026-09-03 00:00 UTC
        let (rise, set) = MoonCalculator.moonEvents(for: polarDay,
                                                    latitude: 85.0,
                                                    longitude: 0.0)
        XCTAssertNil(rise, "极地无事件日 rise 必须为 nil")
        XCTAssertNil(set, "极地无事件日 set 必须为 nil")
    }

    func testPolarDayDoesNotProduceEpochZeroGarbage() throws {
        // 防脏值：nil 之外绝不返回 1970-01-01 附近的坏 Date（AC-A2-14）。
        let polarDay = Date(timeIntervalSince1970: 1_787_846_400)
        let (rise, set) = MoonCalculator.moonEvents(for: polarDay,
                                                    latitude: 85.0,
                                                    longitude: 0.0)
        if let r = rise {
            XCTAssertGreaterThan(r.timeIntervalSince1970, 1_500_000_000,
                                 "月出不得为 1970 坏值")
        }
        if let s = set {
            XCTAssertGreaterThan(s.timeIntervalSince1970, 1_500_000_000,
                                 "月落不得为 1970 坏值")
        }
    }

    // MARK: - 确定性

    func testSameInputSameOutput() {
        let a = MoonCalculator.moonEvents(for: beijingDay, latitude: beijingLat, longitude: beijingLon)
        let b = MoonCalculator.moonEvents(for: beijingDay, latitude: beijingLat, longitude: beijingLon)
        XCTAssertEqual(a.rise, b.rise)
        XCTAssertEqual(a.set, b.set)
    }
}

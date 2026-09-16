//
//  MinutelyPrecipitationEngineTests.swift
//  ZhishengWeatherTests
//
//  B1-2 短时降水展示决策的纯单测（不联网、不涉视图）：
//   - 干窗判定 hasPrecipitation（nil / 空 / 全低于阈值 / 有一点达标）；
//   - 峰值 peakPrecipitation；
//   - 开始/停止时序 timing（正在下→窗内停 / 持续到末；稍后下→起止 / 持续到末）。
//

import XCTest
@testable import ZhishengWeather

final class MinutelyPrecipitationEngineTests: XCTestCase {

    /// 构造等间隔 15 分钟序列（基准时刻 + index×900s）。
    private func points(_ values: [Double]) -> [MinutelyPrecipitationPoint] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return values.enumerated().map { index, value in
            MinutelyPrecipitationPoint(time: base.addingTimeInterval(Double(index) * 900),
                                       precipitation: value)
        }
    }

    // MARK: - 干窗判定（决定整卡隐藏）

    func testHasPrecipitationNilAndEmptyAreDry() {
        XCTAssertFalse(MinutelyPrecipitationEngine.hasPrecipitation(nil))
        XCTAssertFalse(MinutelyPrecipitationEngine.hasPrecipitation([]))
    }

    func testHasPrecipitationFalseWhenAllBelowOrEqualThreshold() {
        XCTAssertFalse(MinutelyPrecipitationEngine.hasPrecipitation(points([0, 0, 0.005, 0.01])),
                       "等于阈值不算降水（须严格大于）")
    }

    func testHasPrecipitationTrueWhenAnyAboveThreshold() {
        XCTAssertTrue(MinutelyPrecipitationEngine.hasPrecipitation(points([0, 0.02, 0])))
    }

    // MARK: - 峰值

    func testPeakPrecipitationBoundaries() throws {
        XCTAssertNil(MinutelyPrecipitationEngine.peakPrecipitation(nil))
        XCTAssertNil(MinutelyPrecipitationEngine.peakPrecipitation([]))
        let peak = MinutelyPrecipitationEngine.peakPrecipitation(points([0, 1.5, 0.3]))
        XCTAssertEqual(try XCTUnwrap(peak), 1.5, accuracy: 1e-9)
    }

    // MARK: - 时序（可派生才给）

    func testTimingNilWhenNilEmptyOrDry() {
        XCTAssertNil(MinutelyPrecipitationEngine.timing(nil))
        XCTAssertNil(MinutelyPrecipitationEngine.timing([]))
        XCTAssertNil(MinutelyPrecipitationEngine.timing(points([0, 0, 0])))
    }

    func testTimingRainingNowStopsWithinWindow() throws {
        let list = points([0.5, 0.4, 0.0, 0.0])
        let timing = try XCTUnwrap(MinutelyPrecipitationEngine.timing(list))
        XCTAssertTrue(timing.isRainingNow)
        XCTAssertNil(timing.start, "已在雨中 → 无 start")
        XCTAssertEqual(try XCTUnwrap(timing.stop), list[2].time,
                       "首次转干窗起始即停止近似点")
    }

    func testTimingRainingNowPersistsToEnd() throws {
        let list = points([0.5, 0.4, 0.6, 0.2])
        let timing = try XCTUnwrap(MinutelyPrecipitationEngine.timing(list))
        XCTAssertTrue(timing.isRainingNow)
        XCTAssertNil(timing.start)
        XCTAssertNil(timing.stop, "全程湿 → 持续到窗口末")
    }

    func testTimingStartsLaterAndStops() throws {
        let list = points([0.0, 0.0, 1.0, 0.5, 0.0])
        let timing = try XCTUnwrap(MinutelyPrecipitationEngine.timing(list))
        XCTAssertFalse(timing.isRainingNow)
        XCTAssertEqual(try XCTUnwrap(timing.start), list[2].time)
        XCTAssertEqual(try XCTUnwrap(timing.stop), list[4].time)
    }

    func testTimingStartsLaterAndPersistsToEnd() throws {
        let list = points([0.0, 1.0, 0.5])
        let timing = try XCTUnwrap(MinutelyPrecipitationEngine.timing(list))
        XCTAssertFalse(timing.isRainingNow)
        XCTAssertEqual(try XCTUnwrap(timing.start), list[1].time)
        XCTAssertNil(timing.stop, "持续到窗口末 → 无 stop")
    }
}

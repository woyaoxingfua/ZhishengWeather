//
//  AirQualityTrendLayoutTests.swift
//  ZhishengWeatherTests
//
//  逐时 AQI 趋势曲线几何（P2 / D-C4，AC-C9 / AC-C10）——纯逻辑，不渲染、不联网。
//   ① AC-C10：nil 处**断开**，绝不生成跨越缺口的线段；
//   ② AC-C9：分段着色取两端中**较大 AQI** 所属档位（复用既有 `AqiLevel` 六档）；
//   ③ `0` 是合法点（成段、画点），与 nil（断裂、不画点）严格区分；
//   ④ 纵轴上限向上取整到 50 的整数倍、六档参考线只取域内断点。
//

import CoreGraphics
import XCTest
@testable import ZhishengWeather

final class AirQualityTrendLayoutTests: XCTestCase {

    private let canvasSize = CGSize(width: 320, height: 54)

    private func point(_ index: Int, _ aqi: Int?) -> AqiHourlyPoint {
        AqiHourlyPoint(time: Date(timeIntervalSince1970: 1_789_833_600 + Double(index) * 3600),
                       usAqi: aqi, pm25: nil, pm10: nil)
    }

    private func makeLayout(_ values: [Int?]) -> AqiTrendLayout {
        let points = values.enumerated().map { self.point($0.offset, $0.element) }
        return AqiTrendLayout(points: points, size: canvasSize)
    }

    // MARK: - AC-C10：nil 处断开，绝不跨缺口连线

    func testGapBreaksCurveInsteadOfConnectingAcrossNil() {
        let layout = makeLayout([50, 60, nil, 120, 130])
        // 只在 (0,1) 与 (3,4) 成段；下标 1 与 3 之间**不生成**任何线段。
        XCTAssertEqual(layout.segments.map(\.id), [0, 3],
                       "AC-C10：nil 处必须断开，绝不连线跨越缺口")
    }

    func testContinuousValuesProduceSegmentPerAdjacentPair() {
        let layout = makeLayout([50, 60, 70])
        XCTAssertEqual(layout.segments.map(\.id), [0, 1])
        XCTAssertEqual(layout.dots.map(\.id), [0, 1, 2])
    }

    func testAllNilProducesNothingToDraw() {
        let layout = makeLayout([nil, nil, nil])
        XCTAssertTrue(layout.segments.isEmpty, "全无 AQI 值 → 无曲线（调用方整块隐藏）")
        XCTAssertTrue(layout.dots.isEmpty)
    }

    /// 缺口点不画点，但有值点仍落在**原来的槽位**（缺口宽度如实）。
    func testGapPointStillKeepsPositionsOfLaterPoints() {
        let layout = makeLayout([nil, 60, 70])
        XCTAssertEqual(layout.dots.map(\.id), [1, 2])
        XCTAssertEqual(layout.dots[0].position.x, canvasSize.width * 1.5 / 3, accuracy: 1e-6)
        XCTAssertEqual(layout.dots[1].position.x, canvasSize.width * 2.5 / 3, accuracy: 1e-6)
    }

    // MARK: - `0` 与 nil 不可混淆

    func testZeroIsAPointNotAGap() {
        let layout = makeLayout([0, 0])
        XCTAssertEqual(layout.segments.count, 1, "0 是合法读数，必须成段（不得当缺口断开）")
        XCTAssertEqual(layout.dots.count, 2)
        XCTAssertEqual(layout.dots[0].level, .good)
    }

    // MARK: - AC-C9：六档语义色分段

    func testSegmentLevelUsesWorseEndpoint() {
        // 40 = 优；120 = 轻度 → 段取较差档（轻度），绝不把转差段画成"优"。
        let layout = makeLayout([40, 120])
        XCTAssertEqual(layout.segments.count, 1)
        XCTAssertEqual(layout.segments[0].level, .light)
        XCTAssertEqual(layout.dots[0].level, .good)
        XCTAssertEqual(layout.dots[1].level, .light)
    }

    func testSegmentLevelAcrossSevereBoundary() {
        let layout = makeLayout([250, 320])
        XCTAssertEqual(layout.segments[0].level, .severe, ">300 为严重污染")
    }

    func testHigherAqiIsDrawnHigherOnScreen() {
        let layout = makeLayout([50, 200])
        XCTAssertGreaterThan(layout.dots[0].position.y, layout.dots[1].position.y,
                             "AQI 越大 y 越小（越高）")
    }

    // MARK: - 纵轴与六档参考线

    func testUpperBoundRoundsUpToFiftyGrid() {
        XCTAssertEqual(makeLayout([0, 0]).upperBound, 50)
        XCTAssertEqual(makeLayout([10, 40]).upperBound, 50)
        XCTAssertEqual(makeLayout([187]).upperBound, 200)
        XCTAssertEqual(makeLayout([200]).upperBound, 200)
        XCTAssertEqual(makeLayout([201]).upperBound, 250)
        XCTAssertEqual(makeLayout([500]).upperBound, 500)
    }

    func testGridLinesOnlyContainBoundariesInsideDomain() {
        // upperBound = 200 → 域内断点 50/100/150；200 即上边界，不画。
        XCTAssertEqual(makeLayout([187]).gridLines.count, 3)
        // upperBound = 500 → 域内断点 50/100/150/200/300/400；500 是上边界。
        XCTAssertEqual(makeLayout([500]).gridLines.count, 6)
    }

    func testDegenerateSizeProducesNothingToDraw() {
        let layout = AqiTrendLayout(points: [point(0, 50)], size: .zero)
        XCTAssertTrue(layout.segments.isEmpty)
        XCTAssertTrue(layout.dots.isEmpty)
        XCTAssertTrue(layout.gridLines.isEmpty)
        XCTAssertEqual(layout.upperBound, 50)
    }

    func testEmptyPointsProduceNothingToDraw() {
        let layout = AqiTrendLayout(points: [], size: canvasSize)
        XCTAssertTrue(layout.segments.isEmpty)
        XCTAssertTrue(layout.dots.isEmpty)
        XCTAssertEqual(layout.upperBound, 50)
    }
}

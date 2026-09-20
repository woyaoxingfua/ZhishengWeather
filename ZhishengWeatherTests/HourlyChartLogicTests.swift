//
//  HourlyChartLogicTests.swift
//  ZhishengWeatherTests
//
//  D-C1 / D-C2 两张逐时图的**纯逻辑**（判定与几何）单测。
//
//  为什么测这些：两张图是"把数据画出来"的视图，真机之外无法断言像素；
//  但它们**是否该出现**（AC-C2/C3）与**柱高/顶点怎么算**全部落在静态纯函数里
//  （`isDataInsufficient` / `barHeight` / `probabilityY` / `scalePeak`），
//  这些是可以在 CI 上钉死的性质，也正是最容易"改一处忘另一处"的地方。
//
//  纪律：不触碰任何共享容器 / 不写 UserDefaults / 不取系统时钟
//  （时间相关用例一律用固定 `Date(timeIntervalSince1970:)` + 固定时区）。
//
//  @MainActor：被测类型（视图 struct）整体标注 @MainActor，故测试类同隔离。
//

import XCTest
@testable import ZhishengWeather

@MainActor
final class HourlyChartLogicTests: XCTestCase {

    /// 固定基准时刻（UTC 1970-01-01 00:00:00），避免任何"现在"依赖。
    private let base = Date(timeIntervalSince1970: 0)

    /// 造一串逐时点：第 index 小时的降水量取 `precipitation` 序列的值。
    private func points(precipitation: [Double?]) -> [HourlyPoint] {
        precipitation.enumerated().map { index, value in
            HourlyPoint(time: base.addingTimeInterval(Double(index) * 3_600),
                        temperature: 20,
                        weatherCode: 1,
                        precipitation: value)
        }
    }

    /// 造一串逐时点：第 index 小时的风速 / 阵风取两个序列的值。
    private func windPoints(speed: [Double?], gusts: [Double?]) -> [HourlyPoint] {
        let count = max(speed.count, gusts.count)
        return (0..<count).map { index in
            HourlyPoint(time: base.addingTimeInterval(Double(index) * 3_600),
                        temperature: 20,
                        weatherCode: 1,
                        windSpeed: index < speed.count ? speed[index] : nil,
                        windGusts: index < gusts.count ? gusts[index] : nil)
        }
    }

    // MARK: - D-C1：整块隐藏判据（AC-C3）

    func testEmptyHourlyHidesPrecipitationChart() {
        XCTAssertTrue(HourlyPrecipitationChart.isDataInsufficient([]))
    }

    func testAllNilPrecipitationHidesChartEvenIfProbabilityExists() {
        // 概率有值但降水量整列为 nil：AC-C3 判据锚在 `precipitation` 上 —— 隐藏，
        // 绝不用概率顶替"降水量"这张图承诺的量。
        let list = points(precipitation: [nil, nil, nil, nil, nil])
        let withProbability: [HourlyPoint] = list.enumerated().map { item in
            var copy = item.element
            copy.precipitationProbability = Double(40 + item.offset)
            return copy
        }
        XCTAssertTrue(HourlyPrecipitationChart.isDataInsufficient(withProbability))
    }

    func testSparseDryWindowHidesChart() {
        // 只有 3 个小时有值且全是 0.0 → 不足成图（ARCH §2 的有效点判据）。
        XCTAssertTrue(HourlyPrecipitationChart.isDataInsufficient(points(precipitation: [0, 0, 0])))
    }

    func testSparseButWetWindowStillShowsChart() {
        // 稀疏但**确有降水** → 必须显示：藏掉真实降水比"图太短"更严重。
        XCTAssertFalse(HourlyPrecipitationChart.isDataInsufficient(points(precipitation: [0, 0, 1.2])))
    }

    func testFullDryWindowShowsChart() {
        // 24 小时全是 0.0（有数据、没下雨）→ 显示"完整晴窗"（AC-C2）。
        let dry: [Double?] = Array(repeating: 0, count: 24)
        XCTAssertFalse(HourlyPrecipitationChart.isDataInsufficient(points(precipitation: dry)))
    }

    func testFourValidPointsAreEnough() {
        XCTAssertFalse(HourlyPrecipitationChart.isDataInsufficient(points(precipitation: [0, 0, 0, 0])))
    }

    // MARK: - D-C1：柱高（0.0 与 nil 必须可区分）

    func testZeroMillimetersGetsBaselineTickNotZeroHeightBar() {
        // 0.0 是"有数据、没下雨" → 2pt 基线刻度（nil 走的是"不画柱"，见调用点）。
        XCTAssertEqual(HourlyPrecipitationChart.barHeight(millimeters: 0,
                                                          plotHeight: 56,
                                                          peak: 5), 2)
    }

    func testWetBarScalesToPeakAndKeepsMinimumVisibility() {
        XCTAssertEqual(HourlyPrecipitationChart.barHeight(millimeters: 5,
                                                          plotHeight: 56,
                                                          peak: 5), 56)
        XCTAssertEqual(HourlyPrecipitationChart.barHeight(millimeters: 2.5,
                                                          plotHeight: 56,
                                                          peak: 5), 28)
        // 刚过阈值（0.02mm）也必须看得见。
        XCTAssertEqual(HourlyPrecipitationChart.barHeight(millimeters: 0.02,
                                                          plotHeight: 56,
                                                          peak: 5), 3)
    }

    func testBarHeightIsDefensiveWhenPeakIsZero() {
        XCTAssertEqual(HourlyPrecipitationChart.barHeight(millimeters: 1,
                                                          plotHeight: 56,
                                                          peak: 0), 3)
    }

    // MARK: - D-C1：概率折线的固定 0…100% 标尺

    func testProbabilityYIsFixedPercentScale() {
        XCTAssertEqual(HourlyPrecipitationChart.probabilityY(percent: 0, plotHeight: 56), 56)
        XCTAssertEqual(HourlyPrecipitationChart.probabilityY(percent: 50, plotHeight: 56), 28)
        XCTAssertEqual(HourlyPrecipitationChart.probabilityY(percent: 100, plotHeight: 56), 0)
    }

    func testProbabilityYClampsOutOfRangeValues() {
        XCTAssertEqual(HourlyPrecipitationChart.probabilityY(percent: 130, plotHeight: 56), 0)
        XCTAssertEqual(HourlyPrecipitationChart.probabilityY(percent: -20, plotHeight: 56), 56)
    }

    // MARK: - D-C2：整块隐藏判据与共用标尺

    func testWindChartHidesOnlyWhenBothSeriesAreEntirelyNil() {
        XCTAssertTrue(HourlyWindChart.isDataInsufficient([]))
        XCTAssertTrue(HourlyWindChart.isDataInsufficient(windPoints(speed: [nil, nil],
                                                                   gusts: [nil, nil])))
        // 任一项有值即显示（另一项留空，绝不补 0）。
        XCTAssertFalse(HourlyWindChart.isDataInsufficient(windPoints(speed: [3.2, nil],
                                                                    gusts: [nil, nil])))
        XCTAssertFalse(HourlyWindChart.isDataInsufficient(windPoints(speed: [nil, nil],
                                                                    gusts: [nil, 0])))
    }

    func testWindScalePeakIsSharedAndHasFloorOfOne() {
        // 两序列共用一把标尺：取两者最大值（阵风通常更高）。
        XCTAssertEqual(HourlyWindChart.scalePeak(windPoints(speed: [3, 4],
                                                            gusts: [8, nil])), 8)
        // 下限 1 m/s：微风窗口不按 0.x 归一（否则柱高比例失真）。
        XCTAssertEqual(HourlyWindChart.scalePeak(windPoints(speed: [0.4, 0.2],
                                                            gusts: [nil, nil])), 1)
        // 全 nil → 仍是下限（调用方此时已整块隐藏）。
        XCTAssertEqual(HourlyWindChart.scalePeak(windPoints(speed: [nil], gusts: [nil])), 1)
    }

    // MARK: - 共用时间轴（与柱心对齐的前提是"等长同序"）

    func testAxisLabelsAreLengthAlignedAndMarkEverySixHours() {
        let times = (0..<24).map { base.addingTimeInterval(Double($0) * 3_600) }
        let labels = HourlySeriesAxis.labels(times: times,
                                             timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(labels.count, times.count, "标签必须与列一一对应")
        XCTAssertEqual(labels[0], "现在")
        XCTAssertEqual(labels[6], "6")
        XCTAssertEqual(labels[12], "12")
        XCTAssertEqual(labels[18], "18")
        XCTAssertEqual(labels[1], "")
        XCTAssertEqual(labels[5], "")
    }

    func testAxisLabelsSurviveEmptyAndSinglePointInput() {
        XCTAssertTrue(HourlySeriesAxis.labels(times: [],
                                              timeZone: TimeZone(identifier: "UTC")!).isEmpty)
        let single = HourlySeriesAxis.labels(times: [base],
                                             timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(single, ["现在"])
    }

    // MARK: - 共用列几何（两图共用一套算式，柱心必须落在列中心）

    func testColumnGeometry() {
        XCTAssertEqual(HourlySeriesChartLayout.columnWidth(count: 4, width: 400), 100)
        XCTAssertEqual(HourlySeriesChartLayout.columnCenterX(index: 0, count: 4, width: 400), 50)
        XCTAssertEqual(HourlySeriesChartLayout.columnCenterX(index: 3, count: 4, width: 400), 350)
        // 柱宽 = 列宽 × 比例（下限 1pt）；浮点乘除用 accuracy 断言，不赌二进制精确。
        XCTAssertEqual(HourlySeriesChartLayout.barWidth(count: 4, width: 400), 55, accuracy: 0.001)
        XCTAssertEqual(HourlySeriesChartLayout.barWidth(count: 1, width: 0.1), 1)
        // 除零防御（调用方已保证非空）。
        XCTAssertEqual(HourlySeriesChartLayout.columnWidth(count: 0, width: 400), 0)
        XCTAssertEqual(HourlySeriesChartLayout.columnCenterX(index: 0, count: 0, width: 400), 0)
    }
}

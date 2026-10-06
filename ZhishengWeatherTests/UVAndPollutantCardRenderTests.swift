//
//  UVAndPollutantCardRenderTests.swift
//  ZhishengWeatherTests
//
//  两张新增卡的**纯逻辑**渲染面单测（不渲染视图、不联网）：
//   - `UVIndexCard.uvText` / `visText` / `metersText`：格式化与「0 不得变--」纪律；
//   - `UVIndexCard.color(for:)`：五档都有颜色（不许有档位被遗漏而落回默认）；
//   - `AirQualityPollutantCard.visibleRows` 派生逻辑：整行全缺测的行被过滤。
//
//  为什么格式化函数标`nonisolated`：为了让本测试文件（无 @MainActor 标注）
//  能直接调用，而不必给整个 suite 加主actor 约束。
//

import SwiftUI
import XCTest
@testable import ZhishengWeather

final class UVAndPollutantCardRenderTests: XCTestCase {

    // MARK: - UV 数值文案

    func testUVTextKeepsZeroVisible() {
        XCTAssertEqual(UVIndexCard.uvText(0.0), "0.0",
                       "UV 0 是合法夜间值，必须显示 0.0，绝不可显示 --")
        XCTAssertEqual(UVIndexCard.uvText(4.9), "4.9")
        XCTAssertEqual(UVIndexCard.uvText(nil), "--", "nil 才显示 --")
        XCTAssertEqual(UVIndexCard.uvText(.nan), "--")
    }

    // MARK: - 米 → km 换算（与 ContentView.visibilityText 同口径）

    func testVisibilityTextSwitchesToKilometersAtOneThousand() {
        XCTAssertEqual(UVIndexCard.visText(16740), "16.7 km", "≥1000 m 才换算，避免米当千米")
        XCTAssertEqual(UVIndexCard.visText(1000), "1.0 km", "边界：恰好 1000 m 用 km")
        XCTAssertEqual(UVIndexCard.visText(999), "999 m", "999 m 仍用米")
        XCTAssertEqual(UVIndexCard.visText(0), "0 m", "0 是合法读数，原样显示")
    }

    func testMetersTextRejectsNonFiniteAndNegative() {
        XCTAssertEqual(UVIndexCard.visText(nil), "--")
        XCTAssertEqual(UVIndexCard.visText(.infinity), "--")
        XCTAssertEqual(UVIndexCard.visText(-5), "--", "负能见度物理上不存在 → --")
    }

    func testFreezingLevelTextUsesSameScaleAsVisibility() {
        XCTAssertEqual(UVIndexCard.metersText(2690), "2.7 km", "零度层高度用同一米→km 口径")
        XCTAssertEqual(UVIndexCard.metersText(4010), "4.0 km")
        XCTAssertEqual(UVIndexCard.metersText(500), "500 m")
    }

    // MARK: - 五档配色齐全（不允许有档位漏掉）

    func testEveryLevelHasAColor() {
        for level in UVIndexLevel.allCases {
            _ = UVIndexCard.color(for: level)
        }
        XCTAssertEqual(UVIndexLevel.allCases.count, 5, "WHO 五档，新增档位时须同步复核配色与单测")
    }

    /// 高档（veryHigh / extreme）必须比低档更"警示"。
    ///
    /// 用 UIColor 分量做断言在单测里脆（颜色空间/转换器实现差异），
    /// 故改为**锁死映射的构造**而非比较分量：本用例断言五档都能取到颜色
    /// 且互不相同（若某档漏映射而与另一档同色，用户将无法区分档位）。
    @MainActor
    func testHigherLevelsAreVisuallyDistinctFromLow() {
        let rendered = UVIndexLevel.allCases.map { UVIndexCard.color(for: $0) }
        let descriptions = rendered.map { String(describing: $0) }
        XCTAssertEqual(Set(descriptions).count, UVIndexLevel.allCases.count,
                       "五档必须映射到互不相同的颜色，否则用户无法区分档位")
    }

    // MARK: - 分项卡：整行全缺测的行被过滤

    private func point(_ pm25: Double?, pm10: Double?, o3: Double?,
                       no2: Double?, so2: Double?, co: Double?) -> AqiHourlyPoint {
        AqiHourlyPoint(time: Date(timeIntervalSince1970: 1_789_833_600),
                       usAqi: 60, pm25: pm25, pm10: pm10,
                       carbonMonoxide: co, nitrogenDioxide: no2,
                       sulphurDioxide: so2, ozone: o3)
    }

    /// 六项都有值 → 六行全渲染。
    @MainActor
    func testAllPollutantsWithDataProduceSixRows() {
        let points = [point(12, 30, 60, 20, 4, 300), point(13, 31, 62, 21, 5, 310)]
        let card = AirQualityPollutantCard(points: points)
        XCTAssertEqual(card.visibleRowCount, 6, "六项都有数据 → 六行全渲染")
    }

    /// 某项**整行**缺测 → 该行被隐藏（绝不渲染 "--"）。
    @MainActor
    func testFullyMissingPollutantRowIsHidden() {
        // SO₂ 全为 nil（服务端未返回该键）→ 只出五行。
        let points = [point(12, 30, 60, 20, nil, 300)]
        let card = AirQualityPollutantCard(points: points)
        XCTAssertEqual(card.visibleRowCount, 5, "SO₂ 整行缺测 → 该行隐藏（不显示 --）")
    }

    /// 全部缺测 → 零行（整卡不渲染）。
    @MainActor
    func testAllMissingProducesNoRows() {
        let card = AirQualityPollutantCard(points: [point(nil, nil, nil, nil, nil, nil)])
        XCTAssertEqual(card.visibleRowCount, 0, "全缺测 → 整卡不渲染")
    }

    /// 序列为空 → 零行。
    @MainActor
    func testEmptyPointsProduceNoRows() {
        XCTAssertEqual(AirQualityPollutantCard(points: []).visibleRowCount, 0)
    }

    /// 部分缺测的行**仍渲染**（缺口如实留在曲线上断开，而不是整行丢掉）。
    @MainActor
    func testPartiallyMissingRowIsStillRendered() {
        let points = [point(12, 30, 60, 20, 4, 300), point(nil, nil, 62, 21, 5, 310)]
        XCTAssertEqual(AirQualityPollutantCard(points: points).visibleRowCount, 6,
                       "只有个别小时缺测的行仍要出（曲线断开），不得整行丢掉")
    }
}
//
//  FloodGridOriginCardTests.swift
//  ZhishengWeatherTests
//
//  「河道流量卡不知道是哪条河」这一诉求的**上屏文案**守卫（本轮新增）。
//
//  ── 背景事实（官方文档 + 本机实测双重确认，勿再重复调查）────────────────
//  · 上游 **不返回河名**：`daily` 块只有 `time` 与 `river_discharge`，
//    含 name / river 的键 **0 个** → 「这是哪条河」**无法回答**、**绝不编造**；
//  · 官方口径是「**5 km 区域内最大的那条河**」，并**明确警告**
//    「Due to the 5 km resolution the closest river might not be selected correctly」；
//  · 但响应**回显了网格中心坐标**（实测请求 39.909,116.397 → 回显
//    39.925003,116.375）→ 「距你多远」是**可以**如实回答的。
//
//  ── 本文件钉住的四条诚实性边界 ────────────────────────────────────────
//  ① **不可知 ≠ 0**：上游没回显网格坐标 → 整行**不渲染**（不是「约 0 km」）；
//  ② **重合 ≠ 伪精度**：距离 < 1 km → 说「重合」，不说「约 0 km」
//     （后者在中文里读起来就是自相矛盾的）；
//  ③ **取整公里**：实测偏移仅 2~3 km，显示 `2.4 km` 是**伪精度**
//     ——上游网格本身就是 5 km 分辨率，给不出米级精度；
//  ④ **标注出处**：距离是本应用按 Haversine 算的，**不是**上游测距。
//
//  ⚠️ 只测**纯文案函数**（`nonisolated static`，不渲染视图、不联网、不读时钟）。
//

import XCTest
@testable import ZhishengWeather

final class FloodGridOriginCardTests: XCTestCase {

    // MARK: - ① 不可知 ≠ 0

    /// 上游未回显网格坐标 → **不显示距离行**。
    ///
    /// 🔴 这是本组最重要的断言：回填请求坐标会让「偏移 2~3 km」永远显示成
    ///   「约 0 km」，等于对用户谎报数据的空间来源。
    func testUnknownGridOffsetRendersNoDistanceLine() {
        XCTAssertNil(FloodCard.gridDistanceText(hasEchoedGridPoint: false,
                                                distanceKilometers: nil),
                     "未回显网格坐标 → 距离不可知 → 整行不渲染")
        // 即使距离「恰好」是 0，**没有回显坐标**也不许显示「重合」——
        // 那等于宣称「上游告诉过我们网格点在哪」，而它并没有。
        XCTAssertNil(FloodCard.gridDistanceText(hasEchoedGridPoint: false,
                                                distanceKilometers: 0),
                     "没有回显坐标时，距离数值一律不可采信")
    }

    /// 回显了坐标但距离缺失 / 非有限 → 同样**不渲染**（如实缺测，绝不返回 0）。
    func testNilOrNonFiniteDistanceRendersNoDistanceLine() {
        XCTAssertNil(FloodCard.gridDistanceText(hasEchoedGridPoint: true,
                                                distanceKilometers: nil))
        XCTAssertNil(FloodCard.gridDistanceText(hasEchoedGridPoint: true,
                                                distanceKilometers: Double.nan),
                     "NaN → 不可知（GeoDistance 对非有限输入返回 nil）")
        XCTAssertNil(FloodCard.gridDistanceText(hasEchoedGridPoint: true,
                                                distanceKilometers: Double.infinity),
                     "Infinity → 不可知")
    }

    // MARK: - ② 重合 ≠ 伪精度

    /// 距离确实在 1 km 以内 → 说「重合」，**绝不**说「约 0 km」。
    func testCoincidentGridRendersCoincidentWordingNotZeroKm() throws {
        let text = try XCTUnwrap(
            FloodCard.gridDistanceText(hasEchoedGridPoint: true, distanceKilometers: 0),
            "坐标完全重合 → 距离确实为 0 → 必须有一句实话可说")

        // ⚠️ 逐字守「不说 0 km」：「约 0 km」是伪精度，且中文里自相矛盾。
        XCTAssertFalse(text.contains("0 km"), "重合时绝不说「约 0 km」（那是伪精度）")
        XCTAssertTrue(text.contains("重合"), "重合时必须如实说「重合」")
    }

    /// 0.4 km 也归入「重合」这一支 —— 理由：5 km 网格下 0.4 km 与 0 km 不可区分。
    func testSubKilometerOffsetUsesCoincidentWording() throws {
        let text = try XCTUnwrap(
            FloodCard.gridDistanceText(hasEchoedGridPoint: true, distanceKilometers: 0.4))
        XCTAssertTrue(text.contains("重合"),
                      "不足 1 km 在 5 km 网格语境下就是「同一格」，说重合比说「约 0 km」诚实")
        XCTAssertFalse(text.contains("0 km"), "仍然不许出现「0 km」")
    }

    // MARK: - ③ 取整公里（拒绝伪精度）

    /// 实测偏移量级（2~3 km）必须显示成**整数**公里，且四舍五入方向正确。
    func testRendersRoundedIntegerKilometers() throws {
        let roundedDown = try XCTUnwrap(
            FloodCard.gridDistanceText(hasEchoedGridPoint: true, distanceKilometers: 2.4))
        XCTAssertTrue(roundedDown.contains("2 km"), "2.4 → 「约 2 km」（四舍五入）")
        XCTAssertFalse(roundedDown.contains("2.4"),
                       "🔴 绝不显示小数：上游网格是 5 km 分辨率，给不出米级精度")

        let roundedUp = try XCTUnwrap(
            FloodCard.gridDistanceText(hasEchoedGridPoint: true, distanceKilometers: 2.6))
        XCTAssertTrue(roundedUp.contains("3 km"), "2.6 → 「约 3 km」（四舍五入进位）")
    }

    /// 实测那个具体偏移量（39.909,116.397 → 39.925003,116.375）→ 落在 1~5 km。
    ///
    /// ⚠️ 断言的是**量级**，不锚死具体数字 —— 上游网格布局若变，数字会变，
    ///   但「几公里」这个量级不会变。
    /// ⚠️ 这里**复用**本仓既有的 `GeoDistance`（`EarthquakeEvent.swift` 里的
    ///   Haversine 实现）—— 本轮**没有**新写第二份。
    func testMeasuredBeijingOffsetLandsInExpectedMagnitude() throws {
        let distance = try XCTUnwrap(
            GeoDistance.kilometers(originLatitude: 39.909,
                                   originLongitude: 116.397,
                                   targetLatitude: 39.925003,
                                   targetLongitude: 116.375),
            "实测两个坐标都有限 → 距离必须算得出来")
        XCTAssertTrue(distance > 1 && distance < 5,
                      "实测偏移应在 1~5 km 量级内，实际=\(distance)")

        let text = try XCTUnwrap(
            FloodCard.gridDistanceText(hasEchoedGridPoint: true, distanceKilometers: distance))
        XCTAssertTrue(text.contains("网格点"),
                      "必须点明「数据取自网格点」——这是对「哪条河」唯一能如实给的回答")
    }

    // MARK: - ④ 必须标注距离是本应用算的

    /// 距离是本应用按 Haversine 算的，**不是**上游测距 → 必须如实标注出处。
    ///
    /// ⚠️ 不标注就是谎报出处（同 `EarthquakeCard` 的既有纪律）。
    func testDistanceDeclaresItIsComputedLocally() throws {
        let text = try XCTUnwrap(
            FloodCard.gridDistanceText(hasEchoedGridPoint: true, distanceKilometers: 2.4))
        XCTAssertTrue(text.contains("Haversine"),
                      "必须声明距离由本应用按 Haversine 计算（上游不提供测距）")
    }
}
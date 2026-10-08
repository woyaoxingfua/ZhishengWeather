//
//  FallbackCrossCheckTests.swift
//  ZhishengWeatherTests
//
//  「多源常显交叉对照」的守卫（v1.6 新增）。
//
//  ── 背景 ──────────────────────────────────────────────────────────
//  `METNorwayMapper` 的 6 个数值字段进了 `solarOverlay`（单测
//  `SourceAttributionCoordinatorTests:327` 已断言 `solarOverlay?.number(.temperature)`
//  非 nil），但在 v1.6 之前 `WeatherSnapshot` 的这四项是**非可选**，
//  `FallbackSourceNote` 判「主源恒不缺失」→ **备源读数永远上不了屏**。
//  v1.6 改可选后，`FallbackCrossCheck` 才可能把它们以「对照」身份显示出来。
//
//  ── 本文件钉住的四条纪律 ───────────────────────────────────────────
//  ① **只在主源有值 且 备源有值时**出行；任一缺 → 不出该行（绝不编数）。
//  ② **文案必须明示是对照、不是替换**（含「对照」「以主源为准」字样），
//     且**必须带具体来源名**（取自 provenance，不写死）。
//  ③ **来源查不到就不显示**（不猜来源名）。
//  ④ **`.none`（查过了没有）与 `.unavailable`（取不到）是两套文案**，
//     绝不合并成一句「失败」。
//
//  ⚠️ 纯逻辑测试：不联网、不读时钟、不渲染视图。
//

import XCTest
@testable import ZhishengWeather

final class FallbackCrossCheckTests: XCTestCase {

    // MARK: - Helpers

    /// 主源快照（四项可注入 nil；默认全部有值 = 「主源正常」）。
    private func snapshot(temperature: Double? = 21.4,
                          humidity: Int? = 58,
                          windSpeed: Double? = 3.2,
                          windDirection: Double? = 135) -> WeatherSnapshot {
        WeatherSnapshot(location: .beijing,
                        temperature: temperature,
                        apparentTemperature: 20.0,
                        weatherCode: 1,
                        windSpeed: windSpeed,
                        windDirection: windDirection,
                        humidity: humidity,
                        isDay: true,
                        hourly: [],
                        dailyHigh: 24.0,
                        dailyLow: 15.0,
                        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// 辅助源覆盖层。
    private func overlay(temperature: Double? = nil,
                         humidity: Double? = nil,
                         windSpeed: Double? = nil,
                         windDirection: Double? = nil,
                         source: SourceID = .metNorwayForecast) -> FieldPatch {
        var patch = FieldPatch(sourceID: source, capturedAt: Date(timeIntervalSince1970: 0))
        if let temperature { patch.set(.temperature, .number(temperature)) }
        if let humidity { patch.set(.humidity, .number(humidity)) }
        if let windSpeed { patch.set(.windSpeed, .number(windSpeed)) }
        if let windDirection { patch.set(.windDirection, .number(windDirection)) }
        return patch
    }

    /// provenance（把给定字段标成「由某源降级补上」）。
    private func provenance(_ fields: [WeatherFieldKey],
                            source: SourceID = .metNorwayForecast) -> FieldProvenanceMap {
        var map: [WeatherFieldKey: FieldProvenance] = [:]
        for field in fields {
            map[field] = FieldProvenance(sourceID: source,
                                          kind: .fallback,
                                          capturedAt: Date(timeIntervalSince1970: 0))
        }
        return FieldProvenanceMap(map: map)
    }

    // MARK: - ① 主源与备源都有值 → 出对照行

    /// 🔴 主源与备源**都有**温度 → 出**一行**，且带上真实数值与来源名。
    func testProducesLineWhenBothPrimaryAndFallbackHaveValue() throws {
        let lines = FallbackCrossCheck.lines(
            snapshot: snapshot(),
            overlay: overlay(temperature: 19.8),
            provenance: provenance([.temperature]))
        let line = try XCTUnwrap(lines.first, "两边都有温度 → 必须出一行对照")
        XCTAssertEqual(lines.count, 1, "只提供了温度 → 只出一行")
        XCTAssertTrue(line.text.contains("21.4"), "必须含主源真实值，实际：\(line.text)")
        XCTAssertTrue(line.text.contains("19.8"), "必须含备源真实值，实际：\(line.text)")
        XCTAssertTrue(line.text.contains("MET Norway"), "必须标明具体来源名")
    }

    /// 四个字段都可对照 → 出四行，顺序稳定（温度→湿度→风速→风向）。
    func testAllFourFieldsProduceLinesInStableOrder() {
        let lines = FallbackCrossCheck.lines(
            snapshot: snapshot(),
            overlay: overlay(temperature: 19.8, humidity: 55, windSpeed: 2.8,
                             windDirection: 180),
            provenance: provenance([.temperature, .humidity, .windSpeed, .windDirection]))
        XCTAssertEqual(lines.count, 4, "四个字段都可对照 → 四行")
        XCTAssertEqual(lines.map(\.field), [.temperature, .humidity, .windSpeed, .windDirection],
                       "展示顺序必须稳定可预期")
    }

    /// 7timer 补上的值同样能对照，来源名是**它自己**（不是 MET）。
    func testSevenTimerAttributionIsNotMisattributed() throws {
        let lines = FallbackCrossCheck.lines(
            snapshot: snapshot(),
            overlay: overlay(temperature: 16.0, source: .sevenTimer),
            provenance: provenance([.temperature], source: .sevenTimer))
        let line = try XCTUnwrap(lines.first)
        XCTAssertTrue(line.text.contains("7timer"), "来源名必须来自 provenance")
        XCTAssertFalse(line.text.contains("MET Norway"),
                       "🔴 绝不能把 7timer 的读数标成 MET 的（张冠李戴）")
    }

    // MARK: - ② 文案纪律：必须明示「对照、不是替换」

    /// 🔴 文案必须同时含「对照」与「以主源为准」——否则用户会以为被替换了。
    func testTextExplicitlyMarksItAsCrossCheckNotReplacement() throws {
        let lines = FallbackCrossCheck.lines(
            snapshot: snapshot(),
            overlay: overlay(temperature: 19.8),
            provenance: provenance([.temperature]))
        let line = try XCTUnwrap(lines.first)
        XCTAssertTrue(line.text.contains("对照"), "必须出现「对照」二字，实际：\(line.text)")
        XCTAssertTrue(line.text.contains("以主源为准"),
                      "必须明示以主源为准（否则用户会以为主源值被替换了），实际：\(line.text)")
    }

    /// 🔴 绝不**平均**：主源 21.4 / 备源 19.8 →绝不能出现 20.6。
    func testNeverAveragesTheTwoValues() throws {
        let lines = FallbackCrossCheck.lines(
            snapshot: snapshot(temperature: 21.4),
            overlay: overlay(temperature: 19.8),
            provenance: provenance([.temperature]))
        let line = try XCTUnwrap(lines.first)
        XCTAssertFalse(line.text.contains("20.6"),
                       "🔴 绝不存在 (a+b)/2 合成路径，实际：\(line.text)")
        XCTAssertTrue(line.text.contains("21.4"), "主源值必须原样透传")
    }

    // MARK: - ③ 任一缺 → 不出该行

    /// 🔴 主源**缺** → 本层不出（那归 `FallbackSourceNote` 补缺层，两层互斥）。
    func testNoLineWhenPrimaryMissing() {
        let lines = FallbackCrossCheck.lines(
            snapshot: snapshot(temperature: nil),
            overlay: overlay(temperature: 18.0),
            provenance: provenance([.temperature]))
        XCTAssertTrue(lines.isEmpty,
                      "🔴 主源缺 → 归补缺层，本层不出（两层不得对同一字段都出）")
    }

    /// 备源**缺** → 不出该行（无对照可言，绝不编一个数）。
    func testNoLineWhenFallbackAlsoLacksTheField() {
        let lines = FallbackCrossCheck.lines(
            snapshot: snapshot(),
            overlay: overlay(temperature: nil),
            provenance: provenance([.temperature]))
        XCTAssertTrue(lines.isEmpty, "备源也没有 → 无值可对照（绝不编一个）")
    }

    /// overlay 的值非有限（NaN / Inf）→ 不出该行（如实缺测）。
    func testNoLineForNonFiniteFallbackValue() {
        let lines = FallbackCrossCheck.lines(
            snapshot: snapshot(),
            overlay: overlay(temperature: Double.nan),
            provenance: provenance([.temperature]))
        XCTAssertTrue(lines.isEmpty, "NaN 必须被当成缺测（绝不显示 NaN）")
    }

    /// overlay 为 nil → 一行都不出（无从判断来源）。
    func testNoLineWhenOverlayNil() {
        XCTAssertTrue(FallbackCrossCheck.lines(snapshot: snapshot(),
                                               overlay: nil,
                                               provenance: nil).isEmpty,
                      "没有 overlay → 无从判断来源 → 一行都不出")
    }

    /// provenance 为 nil → 不出该行（来源查不到就不显示，绝不猜来源名）。
    func testNoLineWhenProvenanceMissing() {
        let lines = FallbackCrossCheck.lines(
            snapshot: snapshot(),
            overlay: overlay(temperature: 19.8),
            provenance: nil)
        XCTAssertTrue(lines.isEmpty,
                      "🔴 来源查不到就不显示（写一个猜出来的来源名比不显示更糟）")
    }

    /// provenance 标的是 `.primary` → 不出（不得把主源值伪装成备源对照）。
    func testNoLineWhenProvenanceSaysPrimary() {
        var map: [WeatherFieldKey: FieldProvenance] = [:]
        map[.temperature] = FieldProvenance(sourceID: .openMeteoForecast,
                                            kind: .primary,
                                            capturedAt: Date(timeIntervalSince1970: 0))
        let lines = FallbackCrossCheck.lines(
            snapshot: snapshot(),
            overlay: overlay(temperature: 19.8),
            provenance: FieldProvenanceMap(map: map))
        XCTAssertTrue(lines.isEmpty, "provenance 标.primary → 不得当成备源对照显示")
    }

    /// 逐字段独立判定：四项里只有一项备源缺 → 只出三行，不整体吞掉。
    func testEachFieldJudgedIndependently() {
        let lines = FallbackCrossCheck.lines(
            snapshot: snapshot(),
            overlay: overlay(temperature: 19.8, windSpeed: 2.8),
            provenance: provenance([.temperature, .windSpeed]))
        XCTAssertEqual(lines.count, 2, "只有两项备源有值 → 只出两行")
        XCTAssertEqual(Set(lines.map(\.field)), [.temperature, .windSpeed])
    }

    // MARK: - ④ `.none` 与 `.unavailable` 两套文案，绝不合并

    /// 🔴 overlay 为 nil → `.unavailable`（取不到）。
    func testNilOverlayIsUnavailableNotNone() {
        XCTAssertEqual(FallbackCrossCheck.status(overlay: nil), .unavailable,
                       "overlay 为 nil = 取不到（协调器没跑 / 时区未知 / 源全失败）")
    }

    /// overlay 存在但没有这些字段 → `.none`（查过了，没有）。
    func testExistingOverlayWithoutFieldsIsNone() {
        XCTAssertEqual(FallbackCrossCheck.status(overlay: overlay()), .none,
                       "overlay 存在 = 查过了，只是这几项它没有（不是故障）")
    }

    /// 🔴 两套文案**必须不同**，且都不得说成一句「失败」。
    func testNoneAndUnavailableHaveDistinctCopy() {
        let none = FallbackCrossCheck.statusText(.none)
        let unavailable = FallbackCrossCheck.statusText(.unavailable)
        XCTAssertNotEqual(none, unavailable,
                          "🔴 「查过了没有」与「取不到」必须是两套文案，绝不合并")
        XCTAssertFalse(unavailable.contains("失败"),
                       "「取不到」要说清是取不到，而不是笼统的「失败」")
        XCTAssertFalse(none.contains("失败"), "「查过了没有」不是故障，不该说成失败")
    }

    // MARK: - 候选字段集纪律

    /// 🔴 候选集**恰好**是 v1.6 改可选的那四项，一个不多一个不少。
    ///
    /// ⚠️ `.pressure` / `.cloudCover` 刻意不在其中：它们本来就是可选的，
    ///   主源缺时已由 `FallbackSourceNote` 负责；这里再接一遍会让用户
    ///   在主源有值时多看到一行与主屏预期无关的信息。
    func testCandidateFieldsAreExactlyTheFourOptionalOnes() {
        XCTAssertEqual(FallbackCrossCheck.crossCheckFields,
                       [.temperature, .humidity, .windSpeed, .windDirection])
        // 压力 / 云量绝不在候选集内（避免与补缺层重复）。
        XCTAssertFalse(FallbackCrossCheck.crossCheckFields.contains(.pressure))
        XCTAssertFalse(FallbackCrossCheck.crossCheckFields.contains(.cloudCover))
    }

    /// `primaryValue` 对四个候选字段都能取到快照里的真实值（nil → nil）。
    func testPrimaryValueReadsSnapshotForEachCandidateField() {
        let snap = snapshot(temperature: 21.4, humidity: 58,
                            windSpeed: 3.2, windDirection: 135)
        XCTAssertEqual(FallbackCrossCheck.primaryValue(.temperature, snapshot: snap), 21.4)
        XCTAssertEqual(FallbackCrossCheck.primaryValue(.humidity, snapshot: snap), 58,
                       "湿度在快照里是 Int?、overlay 里是 Double → 必须统一成 Double")
        XCTAssertEqual(FallbackCrossCheck.primaryValue(.windSpeed, snapshot: snap), 3.2)
        XCTAssertEqual(FallbackCrossCheck.primaryValue(.windDirection, snapshot: snap), 135)

        let empty = snapshot(temperature: nil, humidity: nil,
                             windSpeed: nil, windDirection: nil)
        for field in FallbackCrossCheck.crossCheckFields {
            XCTAssertNil(FallbackCrossCheck.primaryValue(field, snapshot: empty),
                         "\(field) 主源为 nil → primaryValue 必须 nil，绝不返回 0")
        }
    }

    /// 非候选字段 → `primaryValue` 返回 nil（不猜、不顺手多显示一个）。
    func testNonCandidateFieldYieldsNilPrimaryValue() {
        XCTAssertNil(FallbackCrossCheck.primaryValue(.pressure, snapshot: snapshot()))
        XCTAssertNil(FallbackCrossCheck.primaryValue(.solarNoon, snapshot: snapshot()))
    }
}
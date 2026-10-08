//
//  FallbackSourceNoteTests.swift
//  ZhishengWeatherTests
//
//  兜底源数值**上屏**的守卫（2026-10-11 新增）。
//
//  ── 背景（主理人指出的真缺陷）────────────────────────────────────────
//  `METNorwayMapper` 写 6 个数值字段、`SevenTimerMapper` 写 3 个，
//  它们进了 `solarOverlay` 却**没有任何视图读取** —— 取到了、计了用量、
//  走了健康判定，用户永远看不到。本文件钉住「现在有消费者了，且守规矩」。
//
//  ── 本文件钉住的三条纪律 ──────────────────────────────────────────────
//  ① **主源有值 → 一行都不出**（绝不覆盖、绝不与主源并列显示两个温度）；
//  ② **主源缺该字段 → 才显示**，且**必须标注来源名**（来源查不到就不显示）；
//  ③ **只显示备源真实映射了的字段** —— 一个都不多接
//    （7timer 的 `rh2m` / `cloudcover` / `wind10m.speed` 是**档位码不是物理量**，
//      见 `SevenTimerMapper.swift:8-26` 的逐字段诚实性对照表）。
//
// ⚠️ 纯逻辑测试：不联网、不读时钟、不渲染视图。
//

import XCTest
@testable import ZhishengWeather

final class FallbackSourceNoteTests: XCTestCase {

    // MARK: - Helpers

    /// 一份主源快照（各可缺字段**有值** = 「主源正常」）。
    ///
    /// ⚠️ `fetchedAt` 是**必填**（合成逐成员初始化器里它没有默认值），
    ///   固定成一个常量值 → 本文件**不读真实时钟**，断言可重复。
    private func snapshot(pressureMSL: Double? = 1013.0,
                          cloudCover: Double? = 40.0) -> WeatherSnapshot {
        WeatherSnapshot(location: .beijing,
                        temperature: 21.5,
                        apparentTemperature: 20.0,
                        weatherCode: 1,
                        windSpeed: 3.0,
                        windDirection: 90,
                        humidity: 50,
                        isDay: true,
                        hourly: [],
                        dailyHigh: 24.0,
                        dailyLow: 15.0,
                        pressureMSL: pressureMSL,
                        cloudCover: cloudCover,
                        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// 一份 overlay（模拟协调器逐字段合并后的结果）。
    private func overlay(temperature: Double? = nil,
                         pressure: Double? = nil,
                         humidity: Double? = nil,
                         cloudCover: Double? = nil,
                         windSpeed: Double? = nil,
                         windDirection: Double? = nil,
                         source: SourceID = .metNorwayForecast) -> FieldPatch {
        var patch = FieldPatch(sourceID: source, capturedAt: Date(timeIntervalSince1970: 0))
        if let temperature { patch.set(.temperature, .number(temperature)) }
        if let pressure { patch.set(.pressure, .number(pressure)) }
        if let humidity { patch.set(.humidity, .number(humidity)) }
        if let cloudCover { patch.set(.cloudCover, .number(cloudCover)) }
        if let windSpeed { patch.set(.windSpeed, .number(windSpeed)) }
        if let windDirection { patch.set(.windDirection, .number(windDirection)) }
        return patch
    }

    /// 一份 provenance（把给定字段标成「由某源降级补上」）。
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

    // MARK: - ① 主源有值 → 一行都不出

    /// 🔴 主源**全部**有值 → **整段不渲染**（哪怕overlay 里有全部 6 个字段）。
    ///
    /// ⚠️ 这是「绝不覆盖主源」在展示层的最后一道闸门：数据取到了不等于
    ///   该显示 —— 主源有值时显示备源值，只会让用户不知道该信哪个。
    func testNoLineWhenPrimaryHasEveryField() {
        let lines = FallbackSourceNote.lines(
            snapshot: snapshot(pressureMSL: 1013.0, cloudCover: 40.0),
            overlay: overlay(temperature: 18.0, pressure: 1010.0, humidity: 55,
                             cloudCover: 45, windSpeed: 2.0, windDirection: 180),
            provenance: provenance([.temperature, .pressure, .humidity,
                                    .cloudCover, .windSpeed, .windDirection]))
        XCTAssertTrue(lines.isEmpty,
                      "🔴 主源有值时必须一行都不出（绝不覆盖、绝不并列显示两个温度）")
    }

    /// overlay 为 nil（协调器没跑 / 城市时区未知）→ 一行都不出。
    func testNoLineWhenOverlayMissing() {
        XCTAssertTrue(FallbackSourceNote.lines(snapshot: snapshot(pressureMSL: nil),
                                               overlay: nil,
                                               provenance: nil).isEmpty,
                      "没有 overlay → 无从判断来源 → 整段不渲染")
    }

    /// provenance 为 nil → **不出行**（来源查不到就不显示，绝不猜来源名）。
    func testNoLineWhenProvenanceMissing() {
        let lines = FallbackSourceNote.lines(
            snapshot: snapshot(pressureMSL: nil),
            overlay: overlay(pressure: 1010.0),
            provenance: nil)
        XCTAssertTrue(lines.isEmpty,
                      "🔴 来源查不到就不显示（写一个猜出来的来源名比不显示更糟）")
    }

    /// provenance 标的是 `.primary`（不是降级）→ 不出该行。
    ///
    /// ⚠️ 协调器的不变量保证 overlay 里不会有 `.primary` 字段；本用例守的是
    ///   「若哪天这个不变量被破坏，UI 不会把主源值伪装成备源值」。
    func testNoLineWhenProvenanceSaysPrimary() {
        var map: [WeatherFieldKey: FieldProvenance] = [:]
        map[.pressure] = FieldProvenance(sourceID: .openMeteoForecast,
                                         kind: .primary,
                                         capturedAt: Date(timeIntervalSince1970: 0))
        let lines = FallbackSourceNote.lines(
            snapshot: snapshot(pressureMSL: nil),
            overlay: overlay(pressure: 1010.0),
            provenance: FieldProvenanceMap(map: map))
        XCTAssertTrue(lines.isEmpty, "provenance 标 .primary → 不得当成备源显示")
    }

    // MARK: - ② 主源缺 → 显示，且必须标注来源

    /// 主源**气压**缺失 + overlay 有值 + provenance 标MET → 出**一行**，带来源名。
    func testShowsLineWhenPrimaryFieldMissing() throws {
        let lines = FallbackSourceNote.lines(
            snapshot: snapshot(pressureMSL: nil),
            overlay: overlay(pressure: 1010.0),
            provenance: provenance([.pressure]))
        let line = try XCTUnwrap(lines.first, "主源缺气压 + 备源补上 → 必须出一行")
        XCTAssertEqual(lines.count, 1, "只有一个字段缺失 → 只出一行")
        XCTAssertTrue(line.text.contains("气压"), "必须点明是哪个量")
        XCTAssertTrue(line.text.contains("备源"), "必须标明这是备源值（不是主源值）")
        XCTAssertTrue(line.text.contains("MET Norway"),
                      "必须标明**具体来源名**（取自 SourceDirectory，不写死）")
    }

    /// 🔴 兜底值**必须是真值**：断言带上具体数字，别只测「有输出」。
    func testShownValueIsTheFallbackValueNotSomethingElse() throws {
        let lines = FallbackSourceNote.lines(
            snapshot: snapshot(pressureMSL: nil),
            overlay: overlay(pressure: 1010.0),
            provenance: provenance([.pressure]))
        let line = try XCTUnwrap(lines.first)
        // ⚠️ 只断言「含该数值」，**不断言具体单位串**：单位随用户偏好变
        //   （hPa / mmHg / inHg），锁死单位会让这条用例在改单位时假红。
        XCTAssertTrue(line.text.contains("1010"),
                      "显示的必须是 overlay 里的那个值（1010），不是别处的数")
    }

    /// 7timer 补上的值同样能显示，且来源名是**它自己**（不是 MET）。
    func testShowsSevenTimerAttributionWhenItIsTheFallbackSource() throws {
        let lines = FallbackSourceNote.lines(
            snapshot: snapshot(pressureMSL: nil),
            overlay: overlay(pressure: 1009.0, source: .sevenTimer),
            provenance: provenance([.pressure], source: .sevenTimer))
        let line = try XCTUnwrap(lines.first)
        XCTAssertTrue(line.text.contains("7timer"),
                      "来源名必须来自 provenance（7timer 补的就写 7timer）")
        XCTAssertFalse(line.text.contains("MET Norway"),
                       "🔴 绝不能把 7timer 的值标成 MET 的（张冠李戴）")
    }

    /// 两个字段都缺 → **各出一行**（逐字段独立判定，不整体吞掉）。
    func testEachMissingFieldGetsItsOwnLine() {
        let lines = FallbackSourceNote.lines(
            snapshot: snapshot(pressureMSL: nil, cloudCover: nil),
            overlay: overlay(pressure: 1010.0, cloudCover: 45),
            provenance: provenance([.pressure, .cloudCover]))
        XCTAssertEqual(lines.count, 2, "两个字段缺失 → 各出一行")
        XCTAssertEqual(Set(lines.map(\.field)), [.pressure, .cloudCover])
    }

    /// 主源缺、但 overlay **没有**该字段 → 不出该行（缺两处 =真没有）。
    func testNoLineWhenOverlayAlsoLacksTheField() {
        let lines = FallbackSourceNote.lines(
            snapshot: snapshot(pressureMSL: nil),
            overlay: overlay(pressure: nil),
            provenance: provenance([.pressure]))
        XCTAssertTrue(lines.isEmpty, "主源与备源都没有 → 无值可显示（绝不编一个）")
    }

    /// overlay 里的值非有限（NaN / Inf）→ 不出该行（**如实缺测**）。
    func testNoLineForNonFiniteValue() {
        let lines = FallbackSourceNote.lines(
            snapshot: snapshot(pressureMSL: nil),
            overlay: overlay(pressure: Double.nan),
            provenance: provenance([.pressure]))
        XCTAssertTrue(lines.isEmpty, "NaN 必须被当成缺测（绝不显示 NaN）")
    }

    // MARK: - ③ 只显示备源真实映射了的字段

    /// 🔴 候选字段集**必须**恰好是备源真实映射的那些，一个不多。
    ///
    /// ⚠️ 这条是「不为显示更多去接没有的字段」的机械守卫：
    ///   有人往 `candidateFields` 里加一个 `.humidity`（MET 有）或
    ///   `.precipitation`（**两个备源都没有**）时，本用例会红。
    func testCandidateFieldsMatchWhatFallbackSourcesActuallyMap() {
        let expected: Set<WeatherFieldKey> = [
            // METNorwayMapper 写 6 个（temperature/pressure/humidity/
            // cloudCover/windSpeed/windDirection）。
            .temperature, .pressure, .humidity, .cloudCover, .windSpeed, .windDirection,
        ]
        XCTAssertEqual(Set(FallbackSourceNote.candidateFields), expected,
                       "候选字段集必须与备源实际映射的字段一致（不多接一个）")
        // 7timer 只映射 3 个（temperature/pressure/windDirection），
        // 全在集合内 → 它补上的值能显示；它**没**映射的字段不在集合内 →
        // 不可能被显示（这正是「不接档位码」的机械保证）。
        XCTAssertTrue(Set(FallbackSourceNote.candidateFields).isSuperset(of: [.temperature, .pressure, .windDirection]),
                      "7timer 实际映射的 3 个字段必须在集合内（否则它的值永远显示不了）")
    }

    /// ⚠️ **主源的非可选字段恒不出行**（温度/湿度/风速/风向）。
    ///
    /// 🔴 这条钉的是一条**反直觉但正确**的性质：`WeatherSnapshot` 里
    ///   `temperature` / `humidity` / `windSpeed` / `windDirection` 是
    ///   **非可选**（mapper 阶段就保证了），所以主源**结构上不可能缺**它们
    ///   → 备源在这些字段上**永远没有可补的位**→ 提示行永远不为它们出现。
    /// 若将来这些字段改成可选，本用例会提醒重新评估 `isPrimaryMissing`。
    func testNonOptionalSnapshotFieldsNeverProduceLines() {
        for field in [WeatherFieldKey.temperature, .humidity, .windSpeed, .windDirection] {
            XCTAssertFalse(FallbackSourceNote.isPrimaryMissing(field, snapshot: snapshot()),
                           "\(field) 在主源快照里是非可选 → 结构上不可能缺失")
        }
        // 而这两个是**可选**的 → 可以缺 → 可以被备源补。
        XCTAssertTrue(FallbackSourceNote.isPrimaryMissing(.pressure,
                                                          snapshot: snapshot(pressureMSL: nil)))
        XCTAssertTrue(FallbackSourceNote.isPrimaryMissing(.cloudCover,
                                                          snapshot: snapshot(cloudCover: nil)))
    }

    /// 非候选字段（如 `solarNoon`）→ 绝不出行。
    ///
    /// ⚠️ `solarNoon` 的既有消费者是 `DaylightCard`；两处都显示会让用户
    ///   看到同一件事两遍。
    func testNonCandidateFieldsNeverProduceLines() {
        XCTAssertFalse(FallbackSourceNote.isPrimaryMissing(.solarNoon, snapshot: snapshot()),
                       "非候选字段一律不显示（避免与 DaylightCard 重复）")
        XCTAssertFalse(FallbackSourceNote.isPrimaryMissing(.sunrise, snapshot: snapshot()))
        XCTAssertFalse(FallbackSourceNote.isPrimaryMissing(.visibility, snapshot: snapshot()),
                       "`.visibility` 不在候选集内（无备源映射它）→ 不显示")
    }

    // MARK: - 量纲纪律（每字段一份格式，绝不共用）

    /// 🔴 风向走 8 方位中文（复用 `WindDirectionFormatter` 单一真源）。
    ///
    /// ⚠️ 这条防的是「把度数组当成数字直接显示」——
    ///   用户看到「风向 180」根本读不出方向。
    func testWindDirectionUsesCompassTextNotRawDegrees() throws {
        let text = try XCTUnwrap(FallbackSourceNote.displayText(field: .windDirection, value: 180))
        XCTAssertFalse(text.contains("180"),
                       "风向必须转成 8 方位中文，不显示裸度数")
    }

    /// 温度保留一位小数 + 单位；湿度 / 云量取整百分比。
    func testPerFieldFormatsAreDistinct() throws {
        let temperature = try XCTUnwrap(
            FallbackSourceNote.displayText(field: .temperature, value: 21.46))
        XCTAssertTrue(temperature.contains("21.5"), "温度保留一位小数")

        let humidity = try XCTUnwrap(
            FallbackSourceNote.displayText(field: .humidity, value: 55.4))
        XCTAssertTrue(humidity.contains("55"), "湿度取整百分比")

        let cloud = try XCTUnwrap(
            FallbackSourceNote.displayText(field: .cloudCover, value: 45.6))
        XCTAssertTrue(cloud.contains("46"), "云量取整百分比")
    }

    /// 不认识的字段 → **nil**（**绝不**给一个没有单位的裸数字）。
    func testUnknownFieldYieldsNilNotBareNumber() {
        XCTAssertNil(FallbackSourceNote.displayText(field: .uvIndex, value: 5.0),
                     "不在候选集的字段必须返回 nil（裸数字没有单位 = 事故）")
        XCTAssertNil(FallbackSourceNote.displayText(field: .precipitation, value: 3.0))
    }
}
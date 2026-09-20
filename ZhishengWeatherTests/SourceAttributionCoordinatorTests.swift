//
//  SourceAttributionCoordinatorTests.swift
//  ZhishengWeatherTests
//
//  T09 接线(b) 协调器单测（ARCH §12.3.2，硬约束①⑥ / §3.5 诚实红线）：
//  - 主源有值 + 备源不同值 → 上屏值 == 主源值、分歧量被记录（硬约束①）；
//  - 主源缺某项 → 备源补齐，并标记字段级降级（L2 标注依据）；
//  - 城市时区未知 → 不补值、不退回设备时区（诚实红线 §3.5）。
//
//  隔离纪律：ledger / preference / attribution 全部注入独立 UserDefaults suite，
//  绝不触碰 .standard 真实数据。
//

import XCTest
@testable import ZhishengWeather

final class SourceAttributionCoordinatorTests: XCTestCase {

    /// 可注入返回值的辅助源桩（测试用，不联网、不读时钟）。
    private struct StubFieldSource: FieldSupplying {
        var id: SourceID = .sunriseSunset
        var displayName: String = "stub"
        var capabilities: Set<SourceCapability> = [.solarEvents]
        var requiredFields: Set<WeatherFieldKey> = [.sunrise, .sunset, .daylightDuration]
        var patch: FieldPatch
        func fetchFields(latitude: Double, longitude: Double,
                         capabilities: Set<SourceCapability>, now: Date) async throws -> FieldPatch {
            patch
        }
    }

    /// 注入隔离 suite 的全套可注入依赖（不污染 .standard）。
    ///
    /// `@MainActor`：与 `SourceAttributionCoordinator` 同隔离域，避免把非 Sendable 的
    /// 依赖对象跨隔离域传递（测试方法也标 `@MainActor`，见下）。
    @MainActor
    private func makeHarness(suiteName: String) -> (tracker: SourceHealthTracker,
                                                    prefs: SourcePreferences,
                                                    store: SourceAttributionStore) {
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let ledger = SourceHealthLedger(defaults: suite)
        let prefs = SourcePreferences(defaults: suite)
        let store = SourceAttributionStore(defaults: suite)
        let tracker = SourceHealthTracker(policy: .default, ledger: ledger, preferences: prefs)
        return (tracker, prefs, store)
    }

    /// 主源有值 + 备源给不同值 → 上屏值必须 == 主源值；主备分歧量被记录。
    ///
    /// `@MainActor`（CI 修正）：`SourceAttributionCoordinator` 是 `@MainActor` 隔离类型，
    /// 且 `refresh` 是 `async`。**不能**用 `MainActor.run { }` 承载——它的闭包形参是
    /// **同步**的（`@Sendable () throws -> T`），装不下 `await c.refresh(...)`，
    /// 会报 "cannot pass function of type '@Sendable () async -> ...' to parameter
    /// expecting synchronous function type"。正确做法是把测试方法本身标 `@MainActor`，
    /// 然后直接 `await`。
    @MainActor
    func testPrimaryValueNotOverwrittenAndDivergenceRecorded() async {
        let (tracker, prefs, store) = makeHarness(suiteName: "coord.test.1")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pSun = Date(timeIntervalSince1970: 1_000_000)
        let pSet = Date(timeIntervalSince1970: 1_100_000)
        let auxSun = pSun.addingTimeInterval(3600)    // 与主源差 1h（>60s → 分歧）
        let auxSet = pSet.addingTimeInterval(3600)
        let stub = StubFieldSource(patch: FieldPatch(sourceID: .sunriseSunset, capturedAt: now,
                                                     values: [.sunrise: .instant(auxSun),
                                                              .sunset: .instant(auxSet),
                                                              .daylightDuration: .seconds(43_000)]))
        let city = City(name: "测试", latitude: 39.9, longitude: 116.4, isCurrentLocation: false,
                        timeZoneIdentifier: "Asia/Shanghai")

        let c = SourceAttributionCoordinator(sources: [stub], health: tracker,
                                             preferences: prefs, attributionStore: store)
        await c.refresh(for: city,
                        primarySolar: PrimarySolarInput(sunrise: pSun, sunset: pSet),
                        now: now)

        // 不变量：主源 sunrise/sunset **不得**内嵌进 overlay（否则锁旧值）。
        // DaylightCard 取值阶梯 `overlay?.X ?? snapshot.X` 会退回**当前**主快照取到最新值。
        XCTAssertNil(c.solarOverlay?.instant(.sunrise), "主源 sunrise 绝不内嵌进 overlay（不变量）")
        XCTAssertNil(c.solarOverlay?.instant(.sunset), "主源 sunset 绝不内嵌进 overlay（不变量）")
        // 等价性：overlay 为空（nil）→ 阶梯退回主快照 → 上屏值 == 主源值（无陈旧锁定）。
        // 注：**刻意不在此断言**"DaylightCard 阶梯退回主快照取当前值"。
        // 形如 `overlay?.X ?? pSun == pSun` 的写法是**恒真式** —— 上一行已断言该键为 nil，
        // 于是 `??` 必然取到 pSun，这条断言**不可能失败**，等于没断言。
        // 本仓库已因"测试没有证明力"吃过一次亏（某批测试把 case 名当 rawValue，
        // 6 条专为钉住修复而写的用例实际保护力为零），故此类写法一律不留。
        //
        // 真正有分辨力的断言是上面的 `XCTAssertNil`：**只要 overlay 不含该键，
        // 消费方的 `??` 就必然取到"当次最新"的快照值** —— 陈旧锁定被结构性地消除，
        // 而不是靠一条看不到实情的断言"声明"它没发生。
        // 阶梯等价性本身属 `DaylightCard` 的消费行为；协调器只收 `primarySolar`、
        // 拿不到"更新的快照"，在协调器层构造不出有分辨力的输入，
        // 故应放在卡片层测（或明确登记为未覆盖），不要在这里造假绿灯。
        XCTAssertNotNil(c.divergence?.sunriseDiffSeconds, "主备分歧量应被记录")
        XCTAssertFalse(c.attribution.hasFieldFallback, "主源有值则无字段级降级")
    }

    /// 主源缺 `sunset`、备源真的把它补上 → 标记字段级降级（L2 标注依据）。
    ///
    /// ⚠️ 本用例的取数场景在 P2 复盘时**被改写过**：原版本的桩只提供
    /// `sunrise` + `solarNoon`（不提供 `sunset`），却断言 `hasFieldFallback == true`。
    /// 那是照着**有缺陷的语义**写的 —— 旧实现把"备源提供了主源从不提供的字段
    /// （solarNoon / daylightDuration）"也算作降级，于是 `hasFieldFallback` **恒为 true**、
    /// 页脚**恒定**谎称「主源不可用」。修正后：降级的判据是
    /// "**主源本应提供却缺失**的字段由备源顶上"。
    /// 因此本用例改成让备源**真的补上主源缺失的 `sunset`** —— 这才叫降级。
    @MainActor
    func testAuxiliaryFillsMissingFieldAndRecordsFallback() async {
        let (tracker, prefs, store) = makeHarness(suiteName: "coord.test.2")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pSun = Date(timeIntervalSince1970: 1_000_000)
        let auxSet = Date(timeIntervalSince1970: 1_100_000)
        let auxNoon = Date(timeIntervalSince1970: 1_050_000)
        let stub = StubFieldSource(patch: FieldPatch(sourceID: .sunriseSunset, capturedAt: now,
                                                     values: [.sunrise: .instant(pSun),
                                                              .sunset: .instant(auxSet),
                                                              .solarNoon: .instant(auxNoon)]))
        let city = City(name: "测试", latitude: 39.9, longitude: 116.4, isCurrentLocation: false,
                        timeZoneIdentifier: "Asia/Shanghai")

        let c = SourceAttributionCoordinator(sources: [stub], health: tracker,
                                             preferences: prefs, attributionStore: store)
        await c.refresh(for: city,
                        primarySolar: PrimarySolarInput(sunrise: pSun, sunset: nil),
                        now: now)

        // 主源 sunrise 是 .primary → 不变量下不进 overlay；但 DaylightCard 退回快照仍是 pSun。
        XCTAssertNil(c.solarOverlay?.instant(.sunrise), "主源 sunrise 不进 overlay（不变量）")
        XCTAssertEqual(c.solarOverlay?.instant(.sunset), auxSet, "备源补齐主源缺失的 sunset（fallback，保留进 overlay）")
        XCTAssertEqual(c.solarOverlay?.instant(.solarNoon), auxNoon, "备源 solarNoon 补齐（fallback，保留进 overlay）")
        XCTAssertTrue(c.attribution.hasFieldFallback, "主源本应提供却缺失的字段被顶上 → 判为降级")
        XCTAssertEqual(c.solarProvenance?[.solarNoon]?.kind, .fallback, "solarNoon 来源应为 fallback")
    }

    /// **防"谎称主源不可用"复发**（P2 复盘修复的屏幕级缺陷）。
    ///
    /// 旧实现下这条必红：`primaryPatch` 把 `solarNoon` / `daylightDuration` 写死 nil，
    /// 而备源**永远**返回这两个字段 → `degradedFields` 恒非空 → `hasFieldFallback` 恒 true
    /// → 页脚**恒定**显示「主源不可用，当前数据来自 sunrise-sunset.org（备源）」，
    /// 即使主源一切正常。即 App 一直对用户**说假话**。
    ///
    /// 正确语义：`solarNoon` / `daylightDuration` 是主源**从不提供**的字段，
    /// 由辅助源作为**指定提供方**给出 —— 那不是降级，**不得**触发 L2 文案。
    @MainActor
    func testAuxOnlyFieldsDoNotClaimPrimaryUnavailable() async {
        let (tracker, prefs, store) = makeHarness(suiteName: "coord.test.4")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pSun = Date(timeIntervalSince1970: 1_000_000)
        let pSet = Date(timeIntervalSince1970: 1_100_000)
        // 主源 sunrise / sunset **齐全**；备源只额外提供 solarNoon + daylightDuration。
        let stub = StubFieldSource(patch: FieldPatch(sourceID: .sunriseSunset, capturedAt: now,
                                                     values: [.sunrise: .instant(pSun),
                                                              .sunset: .instant(pSet),
                                                              .solarNoon: .instant(Date(timeIntervalSince1970: 1_050_000)),
                                                              .daylightDuration: .seconds(43_000)]))
        let city = City(name: "测试", latitude: 39.9, longitude: 116.4, isCurrentLocation: false,
                        timeZoneIdentifier: "Asia/Shanghai")

        let c = SourceAttributionCoordinator(sources: [stub], health: tracker,
                                             preferences: prefs, attributionStore: store)
        await c.refresh(for: city,
                        primarySolar: PrimarySolarInput(sunrise: pSun, sunset: pSet),
                        now: now)

        XCTAssertFalse(c.attribution.hasFieldFallback,
                       "主源 sunrise/sunset 齐全时，备源补 solarNoon/daylightDuration **不算降级**；"
                       + "为 true 会让页脚谎称主源不可用")
        // 不变量：主源 sunrise/sunset 不进 overlay（即使主源值齐全）。
        XCTAssertNil(c.solarOverlay?.instant(.sunrise), "主源 sunrise 不进 overlay（不变量）")
        XCTAssertNil(c.solarOverlay?.instant(.sunset), "主源 sunset 不进 overlay（不变量）")
        XCTAssertEqual(c.solarOverlay?.instant(.solarNoon), Date(timeIntervalSince1970: 1_050_000),
                       "备源的指定字段仍然照常上屏（fallback，保留进 overlay）")
    }

    /// 城市时区未知 → 不补值、不退回设备时区（诚实红线 §3.5）。
    @MainActor
    func testTimeZoneUnknownProducesNoOverlay() async {
        let (tracker, prefs, store) = makeHarness(suiteName: "coord.test.3")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stub = StubFieldSource(patch: FieldPatch(sourceID: .sunriseSunset, capturedAt: now,
                                                     values: [.sunrise: .instant(Date()),
                                                              .sunset: .instant(Date()),
                                                              .daylightDuration: .seconds(43_000)]))
        let city = City(name: "测试", latitude: 39.9, longitude: 116.4, isCurrentLocation: false,
                        timeZoneIdentifier: nil)   // 时区未知

        let c = SourceAttributionCoordinator(sources: [stub], health: tracker,
                                             preferences: prefs, attributionStore: store)
        await c.refresh(for: city,
                        primarySolar: PrimarySolarInput(sunrise: Date(), sunset: Date()),
                        now: now)
        XCTAssertNil(c.solarOverlay, "时区未知时不应补值")
    }

    // MARK: - T10：EV-1 判缺泛化（新字段自动参与）

    /// **EV-1 对「非 solar 的新字段」同样触发**（T10 §3.3，E8 哑火线）。
    ///
    /// 桩声明一个**非 solar** 的必填字段（`.temperature`）且从不提供它。
    /// 旧实现 `isFieldNil` 只 `switch` 4 个 solar case、`default: return false`
    /// → 该字段被判「不缺失」→ EV-1 **恒不触发**（源明明一直不达标却永远不被摘除），
    /// 本用例在旧实现下**必红**。
    @MainActor
    func testEV1TriggersForAnyDeclaredFieldNotJustSolar() async {
        let (tracker, prefs, store) = makeHarness(suiteName: "coord.test.ev1.generic")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stub = StubFieldSource(requiredFields: [.temperature],
                                   patch: FieldPatch(sourceID: .sunriseSunset, capturedAt: now,
                                                     values: [.sunrise: .instant(Date(timeIntervalSince1970: 100)),
                                                              .sunset: .instant(Date(timeIntervalSince1970: 200))]))
        let city = City(name: "测试", latitude: 39.9, longitude: 116.4, isCurrentLocation: false,
                        timeZoneIdentifier: "Asia/Shanghai")
        let c = SourceAttributionCoordinator(sources: [stub], health: tracker,
                                             preferences: prefs, attributionStore: store)
        let primarySolar = PrimarySolarInput(sunrise: Date(timeIntervalSince1970: 100),
                                            sunset: Date(timeIntervalSince1970: 200))

        await c.refresh(for: city, primarySolar: primarySolar, now: now)
        await c.refresh(for: city, primarySolar: primarySolar, now: now)
        await c.refresh(for: city, primarySolar: primarySolar, now: now)

        let reason = await tracker.exclusionReason(for: .sunriseSunset, now: now)
        XCTAssertEqual(reason, .missingFields(consecutive: 3),
                       "声明了非 solar 必填字段且一直缺 → 必须照样累计到 EV-1 阈值（新字段自动参与）")
    }

    /// 上一条的**对照组**（防「永远摘除」的假绿）：同一必填字段**真的提供了**时，
    /// 连续三轮都不该触发摘除 —— 证明触发的是「缺字段」这件事本身，
    /// 而不是「只要声明了非 solar 字段就摘」。
    @MainActor
    func testEV1DoesNotTriggerWhenDeclaredFieldIsProvided() async {
        let (tracker, prefs, store) = makeHarness(suiteName: "coord.test.ev1.generic.ok")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stub = StubFieldSource(requiredFields: [.temperature],
                                   patch: FieldPatch(sourceID: .sunriseSunset, capturedAt: now,
                                                     values: [.temperature: .number(21),
                                                              .sunrise: .instant(Date(timeIntervalSince1970: 100)),
                                                              .sunset: .instant(Date(timeIntervalSince1970: 200))]))
        let city = City(name: "测试", latitude: 39.9, longitude: 116.4, isCurrentLocation: false,
                        timeZoneIdentifier: "Asia/Shanghai")
        let c = SourceAttributionCoordinator(sources: [stub], health: tracker,
                                             preferences: prefs, attributionStore: store)
        let primarySolar = PrimarySolarInput(sunrise: Date(timeIntervalSince1970: 100),
                                            sunset: Date(timeIntervalSince1970: 200))

        await c.refresh(for: city, primarySolar: primarySolar, now: now)
        await c.refresh(for: city, primarySolar: primarySolar, now: now)
        await c.refresh(for: city, primarySolar: primarySolar, now: now)

        let reason = await tracker.exclusionReason(for: .sunriseSunset, now: now)
        XCTAssertNil(reason, "必填字段齐备 → 绝不能被摘除")
    }

    // MARK: - T10：逐源停用判定（不再写死某一个源 id）

    /// 手动停用**第二个**辅助源 → 只跳过**该源**，其余源照常补值。
    ///
    /// 旧实现把停用/摘除判定写死成 `exclusionReason(for: .sunriseSunset)`，
    /// 于是停用任何**别的**辅助源都完全无效（静默）。本用例在旧实现下必红。
    @MainActor
    func testDisabledSourceIsSkippedPerSource() async {
        let (tracker, prefs, store) = makeHarness(suiteName: "coord.test.perSource")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        prefs.setDisabled(.openMeteoAirQuality, disabled: true)

        let second = StubFieldSource(id: .openMeteoAirQuality,
                                     displayName: "second",
                                     patch: FieldPatch(sourceID: .openMeteoAirQuality, capturedAt: now,
                                                       values: [.solarNoon: .instant(Date(timeIntervalSince1970: 777))]))
        let first = StubFieldSource(patch: FieldPatch(sourceID: .sunriseSunset, capturedAt: now,
                                                      values: [.sunrise: .instant(Date(timeIntervalSince1970: 100))]))
        let city = City(name: "测试", latitude: 39.9, longitude: 116.4, isCurrentLocation: false,
                        timeZoneIdentifier: "Asia/Shanghai")
        let c = SourceAttributionCoordinator(sources: [second, first], health: tracker,
                                             preferences: prefs, attributionStore: store)

        await c.refresh(for: city,
                        primarySolar: PrimarySolarInput(sunrise: nil, sunset: nil),
                        now: now)

        XCTAssertNil(c.solarOverlay?.instant(.solarNoon),
                     "被停用的源不得参与补值（停用判定必须逐源，而非写死某一源）")
        XCTAssertEqual(c.solarOverlay?.instant(.sunrise)?.timeIntervalSince1970, 100,
                       "未被停用的源照常补值")
    }

    // MARK: - 不变量：overlay 永不内嵌主源快照值（旧实现下必红）

    /// **场景 1（RED under old impl）**：主源 sunrise/sunset **齐全** + 一个**非 solar** 辅助源
    /// （MET Norway，`.basicNumericFields`）成功 → overlay **不得**含有 `.sunrise`/`.sunset`。
    ///
    /// 旧实现把 `merged`（含主源当刻的 sunrise/sunset）整包发布，只要任一辅助源成功就令
    /// `auxiliaryContributed = true` → overlay 内嵌主源旧值 → 跨日陈旧锁定。本用例在旧实现下
    /// **必红**：`c.solarOverlay?.instant(.sunrise)` 是主源值而非 nil。
    @MainActor
    func testOverlayExcludesPrimarySolarWhenNonSolarAuxSucceeds() async {
        let (tracker, prefs, store) = makeHarness(suiteName: "coord.inv.nonSolar")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pSun = Date(timeIntervalSince1970: 1_000_000)
        let pSet = Date(timeIntervalSince1970: 1_100_000)
        // 非 solar 辅助源（MET Norway 范式）：只出数值字段，不出 solar。
        let met = StubFieldSource(id: .metNorwayForecast,
                                  displayName: "MET",
                                  capabilities: [.basicNumericFields],
                                  requiredFields: [.temperature, .pressure, .humidity, .cloudCover, .windSpeed, .windDirection],
                                  patch: FieldPatch(sourceID: .metNorwayForecast, capturedAt: now,
                                                    values: [.temperature: .number(21),
                                                             .pressure: .number(1013),
                                                             .humidity: .number(55)]))
        // solar 辅助源：只补它"指定提供"的 solarNoon/daylightDuration（主源从不提供）。
        let solar = StubFieldSource(patch: FieldPatch(sourceID: .sunriseSunset, capturedAt: now,
                                                      values: [.solarNoon: .instant(Date(timeIntervalSince1970: 1_050_000)),
                                                               .daylightDuration: .seconds(43_000)]))
        let city = City(name: "测试", latitude: 39.9, longitude: 116.4, isCurrentLocation: false,
                        timeZoneIdentifier: "Asia/Shanghai")
        let c = SourceAttributionCoordinator(sources: [met, solar], health: tracker,
                                             preferences: prefs, attributionStore: store)
        await c.refresh(for: city,
                        primarySolar: PrimarySolarInput(sunrise: pSun, sunset: pSet),
                        now: now)

        // 不变量：主源 solar 值绝不内嵌进 overlay（旧实现会红）。
        XCTAssertNil(c.solarOverlay?.instant(.sunrise), "主源 sunrise 绝不进 overlay（不变量，旧实现会红）")
        XCTAssertNil(c.solarOverlay?.instant(.sunset), "主源 sunset 绝不进 overlay（不变量，旧实现会红）")
        // 辅助源真正贡献的字段仍照常上屏。
        XCTAssertNotNil(c.solarOverlay?.number(.temperature), "MET 提供的温度保留进 overlay")
        XCTAssertNotNil(c.solarOverlay?.instant(.solarNoon), "solar 辅源指定字段保留进 overlay")
    }

    /// **场景 2（同场景，RED under old impl）**：上一条场景再断言 **DaylightCard 取值等价**——
    /// overlay 不含主源 solar 键时，其取值阶梯 `overlay?.X ?? snapshot.X` 退回的正是
    /// **当前**主快照值，无任何陈旧锁定。
    ///
    /// 旧实现下 overlay 内嵌主源当刻值，阶梯取到的是**调用当刻**的旧值（跨日即错）。
    /// 本用例直接断言「overlay 项为空 → 阶梯等价主快照」这一不变量性质。
    @MainActor
    func testDaylightCardEquivalenceWhenOverlayExcludesPrimary() async {
        let (tracker, prefs, store) = makeHarness(suiteName: "coord.inv.equiv")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pSun = Date(timeIntervalSince1970: 1_000_000)
        let pSet = Date(timeIntervalSince1970: 1_100_000)
        let met = StubFieldSource(id: .metNorwayForecast,
                                  displayName: "MET",
                                  capabilities: [.basicNumericFields],
                                  requiredFields: [.temperature],
                                  patch: FieldPatch(sourceID: .metNorwayForecast, capturedAt: now,
                                                    values: [.temperature: .number(21)]))
        let city = City(name: "测试", latitude: 39.9, longitude: 116.4, isCurrentLocation: false,
                        timeZoneIdentifier: "Asia/Shanghai")
        let c = SourceAttributionCoordinator(sources: [met], health: tracker,
                                             preferences: prefs, attributionStore: store)
        await c.refresh(for: city,
                        primarySolar: PrimarySolarInput(sunrise: pSun, sunset: pSet),
                        now: now)

        // 不变量等价于：overlay 缺项 → 阶梯退回**当前**主快照值（无陈旧锁定）。
        XCTAssertNil(c.solarOverlay?.instant(.sunrise), "overlay 不含主源 sunrise（前提）")
        XCTAssertNil(c.solarOverlay?.instant(.sunset), "overlay 不含主源 sunset（前提）")
        XCTAssertEqual(c.solarOverlay?.instant(.sunrise) ?? pSun, pSun, "DaylightCard 阶梯退回主快照取当前 sunrise")
        XCTAssertEqual(c.solarOverlay?.instant(.sunset) ?? pSet, pSet, "DaylightCard 阶梯退回主快照取当前 sunset")
    }

    /// **场景 3（保留行为，green under both）**：主源**缺** sunset、solar 辅源把它补上 →
    /// overlay **含** `.sunset` 且 provenance 为 `.fallback`。
    ///
    /// 给「按 provenance 过滤」兜底：过滤必须只剔除 `.primary`，**不能**误伤真正由辅助源
    /// 贡献的 `.fallback` 字段——否则降级链与 L2 标注整体失效。
    @MainActor
    func testSolarAuxFillMissingKeepsFallbackInOverlay() async {
        let (tracker, prefs, store) = makeHarness(suiteName: "coord.inv.fallback")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pSun = Date(timeIntervalSince1970: 1_000_000)
        let auxSet = Date(timeIntervalSince1970: 1_100_000)
        let solar = StubFieldSource(patch: FieldPatch(sourceID: .sunriseSunset, capturedAt: now,
                                                     values: [.sunrise: .instant(pSun),
                                                              .sunset: .instant(auxSet)]))
        let city = City(name: "测试", latitude: 39.9, longitude: 116.4, isCurrentLocation: false,
                        timeZoneIdentifier: "Asia/Shanghai")
        let c = SourceAttributionCoordinator(sources: [solar], health: tracker,
                                             preferences: prefs, attributionStore: store)
        await c.refresh(for: city,
                        primarySolar: PrimarySolarInput(sunrise: pSun, sunset: nil),
                        now: now)

        XCTAssertEqual(c.solarOverlay?.instant(.sunset), auxSet, "辅助源补的缺失项保留进 overlay")
        XCTAssertEqual(c.solarProvenance?[.sunset]?.kind, .fallback, "补值来源标记为 fallback")
    }

    /// **场景 4（RED under old impl）**：solar 辅源被**停用** + 非 solar 辅助源（MET）成功 →
    /// overlay **不得**含有主源 solar 键（`.sunrise`/`.sunset`）。
    ///
    /// 旧实现下 MET 成功即 `auxiliaryContributed = true`，`merged` 含主源当刻 sunrise/sunset
    /// → overlay 内嵌它们 → 本用例必红。新不变量下 MET 只出数值，solar 键一个都没有。
    @MainActor
    func testSolarAuxDisabledPlusMetSuccessExcludesPrimarySolarKeys() async {
        let (tracker, prefs, store) = makeHarness(suiteName: "coord.inv.disabledSolar")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pSun = Date(timeIntervalSince1970: 1_000_000)
        let pSet = Date(timeIntervalSince1970: 1_100_000)
        prefs.setDisabled(.sunriseSunset, disabled: true)

        let met = StubFieldSource(id: .metNorwayForecast,
                                  displayName: "MET",
                                  capabilities: [.basicNumericFields],
                                  requiredFields: [.temperature, .pressure, .humidity, .cloudCover, .windSpeed, .windDirection],
                                  patch: FieldPatch(sourceID: .metNorwayForecast, capturedAt: now,
                                                    values: [.temperature: .number(21)]))
        // solar 源虽注入，但被停用 → 协调器跳过它（逐源判定），不参与补值。
        let solar = StubFieldSource(patch: FieldPatch(sourceID: .sunriseSunset, capturedAt: now,
                                                      values: [.sunrise: .instant(Date()), .sunset: .instant(Date())]))
        let city = City(name: "测试", latitude: 39.9, longitude: 116.4, isCurrentLocation: false,
                        timeZoneIdentifier: "Asia/Shanghai")
        let c = SourceAttributionCoordinator(sources: [met, solar], health: tracker,
                                             preferences: prefs, attributionStore: store)
        await c.refresh(for: city,
                        primarySolar: PrimarySolarInput(sunrise: pSun, sunset: pSet),
                        now: now)

        XCTAssertNil(c.solarOverlay?.instant(.sunrise), "solar 辅源停用 + MET 成功：overlay 不含主源 sunrise（旧实现会红）")
        XCTAssertNil(c.solarOverlay?.instant(.sunset), "solar 辅源停用 + MET 成功：overlay 不含主源 sunset（旧实现会红）")
        XCTAssertNotNil(c.solarOverlay?.number(.temperature), "MET 数值仍进 overlay")
    }
}

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
    func testPrimaryValueNotOverwrittenAndDivergenceRecorded() async {
        let (tracker, prefs, store) = makeHarness(suiteName: "coord.test.1")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pSun = Date(timeIntervalSince1970: 1_000_000)
        let pSet = Date(timeIntervalSince1970: 1_100_000)
        let auxSun = pSun.addingTimeInterval(3600)    // 与主源差 1h（>60s → 分歧）
        let auxSet = pSet.addingTimeInterval(3600)
        let stub = StubFieldSource(patch: FieldPatch(sourceID: .sunriseSunset, capturedAt: now,
                                                     sunrise: auxSun, sunset: auxSet,
                                                     daylightDuration: 43_000))
        let city = City(name: "测试", latitude: 39.9, longitude: 116.4, isCurrentLocation: false,
                        timeZoneIdentifier: "Asia/Shanghai")

        let (overlay, divergence, attribution): (FieldPatch?, SolarDivergence?, SourceAttribution) = await MainActor.run {
            let c = SourceAttributionCoordinator(sources: [stub], health: tracker,
                                                 preferences: prefs, attributionStore: store)
            await c.refresh(for: city,
                            primarySolar: PrimarySolarInput(sunrise: pSun, sunset: pSet),
                            now: now)
            return (c.solarOverlay, c.divergence, c.attribution)
        }

        XCTAssertEqual(overlay?.sunrise, pSun, "主源 sunrise 绝不可被备源覆盖")
        XCTAssertEqual(overlay?.sunset, pSet, "主源 sunset 绝不可被备源覆盖")
        XCTAssertNotNil(divergence?.sunriseDiffSeconds, "主备分歧量应被记录")
        XCTAssertFalse(attribution.hasFieldFallback, "主源有值则无字段级降级")
    }

    /// 主源只给 sunrise、备源补齐 solarNoon → 标记字段级降级（L2 标注依据）。
    func testAuxiliaryFillsMissingFieldAndRecordsFallback() async {
        let (tracker, prefs, store) = makeHarness(suiteName: "coord.test.2")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pSun = Date(timeIntervalSince1970: 1_000_000)
        let auxNoon = Date(timeIntervalSince1970: 1_050_000)
        let stub = StubFieldSource(patch: FieldPatch(sourceID: .sunriseSunset, capturedAt: now,
                                                     sunrise: pSun, solarNoon: auxNoon))
        let city = City(name: "测试", latitude: 39.9, longitude: 116.4, isCurrentLocation: false,
                        timeZoneIdentifier: "Asia/Shanghai")

        let (overlay, attribution, provenance): (FieldPatch?, SourceAttribution, FieldProvenanceMap?) = await MainActor.run {
            let c = SourceAttributionCoordinator(sources: [stub], health: tracker,
                                                 preferences: prefs, attributionStore: store)
            await c.refresh(for: city,
                            primarySolar: PrimarySolarInput(sunrise: pSun, sunset: nil),
                            now: now)
            return (c.solarOverlay, c.attribution, c.solarProvenance)
        }

        XCTAssertEqual(overlay?.sunrise, pSun, "主源 sunrise 保留")
        XCTAssertEqual(overlay?.solarNoon, auxNoon, "备源 solarNoon 补齐")
        XCTAssertTrue(attribution.hasFieldFallback, "字段级降级应被标记")
        XCTAssertEqual(provenance?[.solarNoon]?.kind, .fallback, "solarNoon 来源应为 fallback")
    }

    /// 城市时区未知 → 不补值、不退回设备时区（诚实红线 §3.5）。
    func testTimeZoneUnknownProducesNoOverlay() async {
        let (tracker, prefs, store) = makeHarness(suiteName: "coord.test.3")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stub = StubFieldSource(patch: FieldPatch(sourceID: .sunriseSunset, capturedAt: now,
                                                     sunrise: Date(), sunset: Date(),
                                                     daylightDuration: 43_000))
        let city = City(name: "测试", latitude: 39.9, longitude: 116.4, isCurrentLocation: false,
                        timeZoneIdentifier: nil)   // 时区未知

        let overlay: FieldPatch? = await MainActor.run {
            let c = SourceAttributionCoordinator(sources: [stub], health: tracker,
                                                 preferences: prefs, attributionStore: store)
            await c.refresh(for: city,
                            primarySolar: PrimarySolarInput(sunrise: Date(), sunset: Date()),
                            now: now)
            return c.solarOverlay
        }
        XCTAssertNil(overlay, "时区未知时不应补值")
    }
}

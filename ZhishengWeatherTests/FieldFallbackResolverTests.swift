//
//  FieldFallbackResolverTests.swift
//  ZhishengWeatherTests
//
//  逐字段降级纯函数性质锚点（ARCH §8 守卫⑤ / §12.4 硬约束①②）：
//  ① 主源非 nil 绝不被辅助源覆盖（结果 == 主源值、kind == .primary）；
//  ② 绝无平均路径；③ 主源 nil 时采用辅助源且 kind == .fallback；④ 全 nil → nil。
//
//  不联网、不读真实时钟（now 由测试注入）。
//

import XCTest
@testable import ZhishengWeather

final class FieldFallbackResolverTests: XCTestCase {

    let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// 主源 sunrise/sunset 非 nil，辅助源给不同值 → 必须保留主源值（绝不覆盖）。
    func testPrimaryNonNilNotOverwritten() {
        let primary = FieldPatch(sourceID: .openMeteoForecast, capturedAt: now,
                                 sunrise: Date(timeIntervalSince1970: 100),
                                 sunset: Date(timeIntervalSince1970: 200))
        let aux = FieldPatch(sourceID: .sunriseSunset, capturedAt: now,
                             sunrise: Date(timeIntervalSince1970: 999),
                             sunset: Date(timeIntervalSince1970: 888))
        let (merged, provenance) = FieldFallbackResolver.merge(primary: primary, auxiliary: [aux])

        XCTAssertEqual(merged.sunrise?.timeIntervalSince1970, 100, "主源非nil必须保留主源值")
        XCTAssertEqual(merged.sunset?.timeIntervalSince1970, 200)
        XCTAssertEqual(provenance[.sunrise]?.kind, ProvenanceKind.primary)
        XCTAssertEqual(provenance[.sunset]?.kind, ProvenanceKind.primary)
    }

    /// 同上：结果必须 == 主源值，绝非 (100+999)/2 之类的平均。
    func testNoAveraging() {
        let primary = FieldPatch(sourceID: .openMeteoForecast, capturedAt: now,
                                 sunrise: Date(timeIntervalSince1970: 100))
        let aux = FieldPatch(sourceID: .sunriseSunset, capturedAt: now,
                             sunrise: Date(timeIntervalSince1970: 999))
        let (merged, _) = FieldFallbackResolver.merge(primary: primary, auxiliary: [aux])

        XCTAssertEqual(merged.sunrise?.timeIntervalSince1970, 100, "绝不平均")
        XCTAssertNotEqual(merged.sunrise?.timeIntervalSince1970, (100 + 999) / 2)
    }

    /// 主源 nil + 辅助源有值 → 采用辅助源且 kind == .fallback。
    func testPrimaryNilAuxFallback() {
        let primary = FieldPatch(sourceID: .openMeteoForecast, capturedAt: now)
        let aux = FieldPatch(sourceID: .sunriseSunset, capturedAt: now,
                             sunrise: Date(timeIntervalSince1970: 999))
        let (merged, provenance) = FieldFallbackResolver.merge(primary: primary, auxiliary: [aux])

        XCTAssertEqual(merged.sunrise?.timeIntervalSince1970, 999)
        XCTAssertEqual(provenance[.sunrise]?.kind, ProvenanceKind.fallback)
        XCTAssertEqual(provenance[.sunrise]?.sourceID, SourceID.sunriseSunset)
    }

    /// 主源与所有辅助源皆 nil → 保持 nil（UI 走 "--"/隐藏，绝不用假值填）。
    func testAllNilStaysNil() {
        let primary = FieldPatch(sourceID: .openMeteoForecast, capturedAt: now)
        let aux = FieldPatch(sourceID: .sunriseSunset, capturedAt: now)
        let (merged, provenance) = FieldFallbackResolver.merge(primary: primary, auxiliary: [aux])

        XCTAssertNil(merged.sunrise)
        XCTAssertNil(merged.sunset)
        XCTAssertNil(merged.solarNoon)
        XCTAssertNil(merged.daylightDuration)
        XCTAssertTrue(provenance.degradedFields.isEmpty)
    }

    /// solarNoon / daylightDuration 仅第二源提供（主源无）→ 验证「补一格」能力。
    func testSolarNoonOnlyFromAux() {
        let primary = FieldPatch(sourceID: .openMeteoForecast, capturedAt: now)
        let aux = FieldPatch(sourceID: .sunriseSunset, capturedAt: now,
                            solarNoon: Date(timeIntervalSince1970: 555),
                            daylightDuration: 44329)
        let (merged, provenance) = FieldFallbackResolver.merge(primary: primary, auxiliary: [aux])

        XCTAssertEqual(merged.solarNoon?.timeIntervalSince1970, 555)
        XCTAssertEqual(merged.daylightDuration, 44329.0)
        XCTAssertEqual(provenance[.solarNoon]?.kind, ProvenanceKind.fallback)
        XCTAssertEqual(provenance[.daylightDuration]?.kind, ProvenanceKind.fallback)
    }
}

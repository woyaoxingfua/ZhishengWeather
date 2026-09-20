//
//  FieldFallbackResolverGeneralityTests.swift
//  ZhishengWeatherTests
//
//  T10 §3.2 / §8 守卫③ —— **锚性质**的穷举守卫（**不锚任何符号名**）：
//
//  ① **主源非 nil 绝不覆盖**：对 `WeatherFieldKey.allCases` **逐字段**断言
//     「主源给 A、备源给 B(≠A) → 结果 == A 且 provenance == .primary」。
//  ② **绝不平均 / 绝不融合**：对每个 key 断言结果是**参与者的某一个输入**
//     （identity 成员性），且「两辅助源给不同值」时取**第一个**（非均值）。
//     数值型字段额外显式断言「≠ (a+b)/2」。
//  ③ **全 nil 保持缺失**：对每个 key 断言结果仍是缺失（不用假值填）。
//
//  为什么这份测试比「4 个字段各写一个断言」可靠：
//  测试与实现遍历的是**同一张 `WeatherFieldKey.allCases`** ——
//  **新增字段自动进入全部三条性质断言，测试无需随字段增加而改**。
//
//  不联网、不读真实时钟（now 由测试注入）。
//

import XCTest
@testable import ZhishengWeather

final class FieldFallbackResolverGeneralityTests: XCTestCase {

    let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// 为主源 / 备源造**互不相同**的探测值。
    ///
    /// 按 `index % 3` 轮换三种载荷（数值 / 时长 / 时刻），保证三条载荷路径
    /// 都被穷举覆盖到（而不是只覆盖 `.instant`）。
    /// - Parameters:
    ///   - index: 字段在 `allCases` 中的下标（决定载荷种类）。
    ///   - variant: 变体号（1 = 主源侧、2 = 备源侧；两侧必须不同）。
    private func probeValue(index: Int, variant: Int) -> FieldValue {
        let magnitude = Double(index * 10 + variant)
        switch index % 3 {
        case 0: return .number(magnitude)
        case 1: return .seconds(magnitude)
        default: return .instant(Date(timeIntervalSince1970: magnitude))
        }
    }

    /// ① 主源非 nil ⇒ 该字段绝不被备源覆盖（逐字段穷举）。
    func testPrimaryNeverOverwrittenForEveryField() {
        for (index, key) in WeatherFieldKey.allCases.enumerated() {
            let primaryValue = probeValue(index: index, variant: 1)
            let auxValue = probeValue(index: index, variant: 2)
            XCTAssertNotEqual(primaryValue, auxValue, "用例自检：主备探测值必须不同（\(key.rawValue)）")

            let primary = FieldPatch(sourceID: .openMeteoForecast, capturedAt: now,
                                     values: [key: primaryValue])
            let auxiliary = FieldPatch(sourceID: .sunriseSunset, capturedAt: now,
                                       values: [key: auxValue])

            let (merged, provenance) = FieldFallbackResolver.merge(primary: primary,
                                                                   auxiliary: [auxiliary])

            XCTAssertEqual(merged.value(key), primaryValue,
                           "字段 \(key.rawValue)：主源有值时绝不可被备源覆盖")
            XCTAssertEqual(provenance[key]?.kind, .primary,
                           "字段 \(key.rawValue)：来源必须是 .primary")
            XCTAssertEqual(provenance[key]?.sourceID, .openMeteoForecast,
                           "字段 \(key.rawValue)：来源源 id 必须是主源")
        }
    }

    /// ② 绝不平均：备源顶替时取**第一个**有值的辅助源，且结果必须是某个输入本身。
    func testNoAveragingAndFirstAuxWinsForEveryField() {
        for (index, key) in WeatherFieldKey.allCases.enumerated() {
            let firstValue = probeValue(index: index, variant: 1)
            let secondValue = probeValue(index: index, variant: 2)
            XCTAssertNotEqual(firstValue, secondValue)

            // 主源缺该字段；两个辅助源给出**不同**的值。
            let primary = FieldPatch(sourceID: .openMeteoForecast, capturedAt: now)
            let first = FieldPatch(sourceID: .sunriseSunset, capturedAt: now, values: [key: firstValue])
            let second = FieldPatch(sourceID: .openMeteoAirQuality, capturedAt: now, values: [key: secondValue])

            let (merged, provenance) = FieldFallbackResolver.merge(primary: primary,
                                                                   auxiliary: [first, second])

            guard let result = merged.value(key) else {
                XCTFail("字段 \(key.rawValue)：主源缺 + 备源有值 → 必须取到备源值，不得缺失")
                continue
            }
            // identity 成员性：结果必须**就是**某个输入值，绝不落在一个新造的值上。
            XCTAssertTrue(result == firstValue || result == secondValue,
                          "字段 \(key.rawValue)：结果既非主源也非备源输入（疑似合成/平均）")
            XCTAssertEqual(result, firstValue,
                           "字段 \(key.rawValue)：同字段多备源时必须取链序**第一个**（非均值）")
            XCTAssertEqual(provenance[key]?.kind, .fallback)
            XCTAssertEqual(provenance[key]?.sourceID, .sunriseSunset)

            // 数值型字段：显式断言不是两端均值。
            if case .number(let a) = firstValue, case .number(let b) = secondValue,
               case .number(let got) = result {
                XCTAssertNotEqual(got, (a + b) / 2, "字段 \(key.rawValue)：绝不允许取平均")
            }
        }
    }

    /// ③ 主源与所有备源皆缺 ⇒ 该字段保持缺失（不用假值填）。
    func testAllMissingStaysMissingForEveryField() {
        let primary = FieldPatch(sourceID: .openMeteoForecast, capturedAt: now)
        let auxiliary = FieldPatch(sourceID: .sunriseSunset, capturedAt: now)

        let (merged, provenance) = FieldFallbackResolver.merge(primary: primary,
                                                               auxiliary: [auxiliary])

        for key in WeatherFieldKey.allCases {
            XCTAssertNil(merged.value(key), "字段 \(key.rawValue)：全缺时必须保持缺失")
            XCTAssertTrue(merged.isMissing(key), "字段 \(key.rawValue)：全缺时 isMissing 必须为 true")
            XCTAssertNil(provenance[key], "字段 \(key.rawValue)：没有值就不该有来源记录（不造假来源）")
        }
        XCTAssertTrue(provenance.degradedFields.isEmpty)
    }

    /// 合并结果的载体身份：sourceID / capturedAt 取**主源**（不是备源，也不是新时刻）。
    func testMergedCarrierIdentityComesFromPrimary() {
        let primaryCapturedAt = Date(timeIntervalSince1970: 1_600_000_000)
        let primary = FieldPatch(sourceID: .openMeteoForecast, capturedAt: primaryCapturedAt)
        let auxiliary = FieldPatch(sourceID: .sunriseSunset, capturedAt: now,
                                   values: [.sunrise: .instant(Date(timeIntervalSince1970: 100))])

        let (merged, _) = FieldFallbackResolver.merge(primary: primary, auxiliary: [auxiliary])

        XCTAssertEqual(merged.sourceID, .openMeteoForecast)
        XCTAssertEqual(merged.capturedAt, primaryCapturedAt)
    }
}

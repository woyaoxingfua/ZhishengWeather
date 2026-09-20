//
//  FieldPatchSparseSemanticsTests.swift
//  ZhishengWeatherTests
//
//  T10 §3.1 / §3.3 / §8 守卫② —— 稀疏容器与 EV-1 判据的锚点：
//
//  ① **稀疏语义**：「未命中」与「值是 0」严格区分 ——
//     `set(.x, .number(0))` 之后该字段**不是**缺失；没写过的字段**才是**缺失。
//  ② **空补丁对 `allCases` 的每个 case 都报缺失**（EV-1 判据的穷举守卫）；
//  ③ **带类型访问器**：类型不符 → 返回 nil（不崩、不静默转型）；
//  ④ **`fields` 是派生的**：与写入的键集合逐字相等（不可能与实际存储不同步）。
//
//  为什么锚在 `allCases`：实现里的 `isMissing` 与字段名**无关**，
//  于是**新增字段自动进入本守卫**（测试无需随字段增加而改）——
//  这正是它比「给 4 个 solar 字段各写一条」可靠的地方。
//
//  不联网、不读真实时钟。
//

import XCTest
@testable import ZhishengWeather

final class FieldPatchSparseSemanticsTests: XCTestCase {

    let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// ② 空补丁 → 对**每个**字段键都报缺失（EV-1 判据穷举，ARCH §8 守卫②）。
    func testEmptyPatchReportsMissingForEveryField() {
        let patch = FieldPatch(sourceID: .sunriseSunset, capturedAt: now)

        for key in WeatherFieldKey.allCases {
            XCTAssertTrue(patch.isMissing(key), "字段 \(key.rawValue)：空补丁必须判为缺失")
            XCTAssertNil(patch.value(key), "字段 \(key.rawValue)：空补丁不得有值")
            XCTAssertNil(patch.number(key))
            XCTAssertNil(patch.seconds(key))
            XCTAssertNil(patch.instant(key))
        }
        XCTAssertTrue(patch.fields.isEmpty)
    }

    /// ① 稀疏语义：**值为 0 ≠ 缺失**（数值 / 时长两种载荷都验）。
    func testZeroValueIsPresentNotMissing() {
        var patch = FieldPatch(sourceID: .sunriseSunset, capturedAt: now)
        patch.set(.temperature, .number(0))
        patch.set(.daylightDuration, .seconds(0))

        XCTAssertFalse(patch.isMissing(.temperature), "值 0 是有效值，不是缺失")
        XCTAssertEqual(patch.number(.temperature), 0.0)
        XCTAssertNotNil(patch.value(.temperature))

        XCTAssertFalse(patch.isMissing(.daylightDuration), "时长 0 是有效值（极夜），不是缺失")
        XCTAssertEqual(patch.seconds(.daylightDuration), 0.0)

        // 与之对照：**没写过**的字段仍然是缺失（缺字段 vs 值为 0 的分界）。
        XCTAssertTrue(patch.isMissing(.sunset), "未写入的字段必须仍然是缺失")
        XCTAssertNil(patch.value(.sunset))
    }

    /// ④ `fields` 是**派生**的：与写入的键集合完全一致（不可能是两份存储）。
    func testFieldsIsDerivedFromStoredValues() {
        let keys: [WeatherFieldKey] = [.sunrise, .sunset, .daylightDuration, .temperature]
        var patch = FieldPatch(sourceID: .sunriseSunset, capturedAt: now)
        for key in keys { patch.set(key, .number(1)) }

        XCTAssertEqual(Set(patch.fields), Set(keys), "fields 必须恰好等于已装载的字段集合")
        for key in WeatherFieldKey.allCases where !keys.contains(key) {
            XCTAssertFalse(patch.fields.contains(key), "未装载的字段 \(key.rawValue) 不得出现在 fields 里")
        }
    }

    /// ③ 带类型访问器：类型不符 → nil（既不崩，也不静默转型）。
    func testTypedAccessorsRejectWrongPayloadType() {
        var patch = FieldPatch(sourceID: .sunriseSunset, capturedAt: now)
        patch.set(.sunrise, .number(42))          // 故意用数值载荷装「日出」
        patch.set(.temperature, .instant(now))    // 故意用时刻载荷装「温度」

        XCTAssertNotNil(patch.value(.sunrise), "擦除值仍在（字段已装载）")
        XCTAssertNil(patch.instant(.sunrise), "用数值载荷装的日出，取 instant 必须是 nil")
        XCTAssertEqual(patch.number(.sunrise), 42.0)

        XCTAssertNil(patch.number(.temperature), "用时刻载荷装的温度，取 number 必须是 nil")
        XCTAssertEqual(patch.instant(.temperature), now)
    }

    /// 覆盖写：同一字段被再次 `set` → 值更新（后写覆盖前写），不是「两份值」。
    func testSetOverwritesPreviousValue() {
        var patch = FieldPatch(sourceID: .sunriseSunset, capturedAt: now)
        patch.set(.sunrise, .instant(Date(timeIntervalSince1970: 100)))
        patch.set(.sunrise, .instant(Date(timeIntervalSince1970: 200)))

        XCTAssertEqual(patch.instant(.sunrise)?.timeIntervalSince1970, 200)
        XCTAssertEqual(patch.fields.filter { $0 == .sunrise }.count, 1, "同一字段不得重复出现")
    }

    /// 载体身份：`sourceID` / `capturedAt` 原样保留（构造即确定，不被 set 影响）。
    func testCarrierIdentityPreserved() {
        var patch = FieldPatch(sourceID: .sunriseSunset, capturedAt: now)
        patch.set(.sunrise, .instant(Date(timeIntervalSince1970: 100)))

        XCTAssertEqual(patch.sourceID, .sunriseSunset)
        XCTAssertEqual(patch.capturedAt, now)
    }
}

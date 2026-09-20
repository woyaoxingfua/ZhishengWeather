//
//  SourceDirectoryCoverageTests.swift
//  ZhishengWeatherTests
//
//  T10 §3.4 / §8 守卫① —— **锚性质**的源目录守卫（**不锚任何符号名**）：
//
//  **性质：「每个被声明的源都有且仅有一个角色条目」（双向相等）。**
//  手段：断言 `Set(SourceID.allCases) == Set(SourceCatalog.all.map(\.id))`。
//  —— 既防**漏加**（声明了却没目录项），也防**幽灵条目**（目录项没有对应声明）。
//
//  这条守卫锚的是**关系（双射）**，不是某个名字：改名 / 搬迁 / 重排都不失效。
//  它拦的是**静默哑火**：漏目录项 → `participatesInAutoExclusion` 无从查得 →
//  该源的自动摘除**完全哑火**、且设置页**根本不显示它**（本仓库真的漏过
//  `openMeteoAirQuality`，就是这条守卫要防的现实样本）。
//
//  不联网、不读真实时钟。
//

import XCTest
@testable import ZhishengWeather

final class SourceDirectoryCoverageTests: XCTestCase {

    /// 双射：被声明的源集合 == 目录里的源集合（无漏项、无幽灵条目）。
    func testEveryDeclaredSourceHasExactlyOneRoleEntry() {
        let declared = Set(SourceID.allCases)
        let catalogued = Set(SourceCatalog.all.map(\.id))

        let missing = declared.subtracting(catalogued)
        let ghost = catalogued.subtracting(declared)

        XCTAssertTrue(missing.isEmpty,
                      "以下源已声明但**没有角色条目**（后果：自动摘除哑火 + 设置页隐身）：\(missing)")
        XCTAssertTrue(ghost.isEmpty,
                      "以下目录条目**没有对应的源声明**（幽灵条目）：\(ghost)")
        XCTAssertEqual(declared, catalogued)
    }

    /// 同一性质的数量形式：条目数 == 声明数（防重复条目把「相等」凑出来）。
    func testCatalogHasNoDuplicateEntries() {
        XCTAssertEqual(SourceCatalog.all.count, SourceID.allCases.count,
                       "目录条目数与源声明数不一致（可能有重复项）")
        XCTAssertEqual(Set(SourceCatalog.all.map(\.id)).count, SourceCatalog.all.count,
                       "目录里出现了重复的源条目")
    }

    /// 源描述符自身：id 唯一、展示名非空。
    func testDescriptorUniquenessAndDisplayName() {
        let ids = SourceDirectory.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "SourceDirectory.all 里出现重复的 SourceID")
        for descriptor in SourceDirectory.all {
            XCTAssertFalse(descriptor.displayName.isEmpty,
                           "源 \(descriptor.id.rawValue) 的展示名为空（设置页会出现空白行）")
        }
    }

    /// 描述符与目录条目**同源**：目录条目必须逐字段反映描述符（不许各自漂移）。
    func testCatalogItemMirrorsDescriptor() {
        for item in SourceCatalog.all {
            guard let descriptor = SourceDirectory.descriptor(for: item.id) else {
                XCTFail("目录条目 \(item.id.rawValue) 在 SourceDirectory 里查不到描述符")
                continue
            }
            XCTAssertEqual(item.displayName, descriptor.displayName)
            XCTAssertEqual(item.participatesInAutoExclusion, descriptor.participatesInAutoExclusion)
        }
    }

    /// 主源**绝不**参与自动摘除（ARCH R-7 / H-8：主源只记录、不自动摘）。
    ///
    /// 这里锚的是**关系**（"主源"这个角色 ⇔ 不参与自动摘除），不是具体某个 id。
    func testPrimaryNeverParticipatesInAutoExclusion() {
        for descriptor in SourceDirectory.all where descriptor.role == .primary {
            XCTAssertFalse(descriptor.participatesInAutoExclusion,
                           "主源 \(descriptor.id.rawValue) 不允许参与自动摘除（R-7）")
        }
    }

    /// 设有「参与自动摘除」的源时，其必填集不得为空
    /// —— 空的 `requiredFields` 会让 EV-1 **永远算不出缺失**（静默哑火）。
    ///
    /// 守卫锚的是**性质**（"参与摘除 ⇒ 有可判缺的字段"），不锚任何符号名。
    func testAutoExcludedSourcesDeclareRequiredFields() {
        for descriptor in SourceDirectory.all where descriptor.participatesInAutoExclusion {
            XCTAssertFalse(descriptor.requiredFields.isEmpty,
                           "源 \(descriptor.id.rawValue) 参与自动摘除但 requiredFields 为空 → EV-1 恒不触发")
        }
    }

    /// `SourceID` 转 enum 后：rawValue 必须**唯一**（重复 rawValue 会让账本 / 偏好互相串台）。
    func testRawValuesAreUnique() {
        let rawValues = SourceID.allCases.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, rawValues.count,
                       "SourceID 的 rawValue 出现重复（持久化键会互相覆盖）")
    }

    /// 反序列化未知 rawValue → nil（绝不造一个假 id；账本据此跳过该项）。
    func testUnknownRawValueFailsToInitialize() {
        XCTAssertNil(SourceID(rawValue: "not-a-real-source"))
    }

    /// **组装点实例化的源**必须①已登记在 `SourceDirectory`，且②运行期声明与描述符一致。
    ///
    /// 为什么需要：`capabilities` / `requiredFields` 在两侧各有一份 ——
    /// `FieldSupplying` 的实现面是**运行期真源**（协调器直接读它做 EV-1 判定），
    /// 描述符里那份供**守卫与派生**使用。两处一旦漂移，就会出现
    /// 「设置页/守卫看的是 A、实际摘除判据用的是 B」——又一条静默线。
    /// 本守卫锚的是**关系**（两侧相等 / 已登记），不锚任何符号名。
    @MainActor
    func testComposedSourcesMatchTheirDescriptors() {
        let composed = SourceComposition.makeAuxiliarySources()
        XCTAssertFalse(composed.isEmpty, "组装点不该为空（否则辅助源永远不参与）")

        for source in composed {
            guard let descriptor = SourceDirectory.descriptor(for: source.id) else {
                XCTFail("组装点实例化了**未登记**的源 \(source.id.rawValue)："
                        + "它不会出现在设置页，自动摘除的行为标记也无从查得")
                continue
            }
            XCTAssertEqual(source.capabilities, descriptor.capabilities,
                           "源 \(source.id.rawValue)：运行期能力集与描述符不一致（声明与事实漂移）")
            XCTAssertEqual(source.requiredFields, descriptor.requiredFields,
                           "源 \(source.id.rawValue)：运行期必填集与描述符不一致"
                           + "（EV-1 判据用的可能是另一份字段清单）")
            XCTAssertEqual(source.displayName, descriptor.displayName,
                           "源 \(source.id.rawValue)：展示名两侧不一致")
        }
    }
}

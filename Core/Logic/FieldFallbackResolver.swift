//
//  FieldFallbackResolver.swift
//  Core / Logic  [App + Widget 共用]
//
//  逐字段降级合并（纯函数，ARCH §3.1 / §12.4 硬约束①②；T10 §3.2 泛化）。
//
//  **硬约束②**：本类型必须是纯函数——无 I/O、无内部时钟（时间维度由
//  FieldPatch.capturedAt 承载，调用方注入）、无全局状态。
//
//  **硬约束①**：主源有值**绝不覆盖**——`merge` 在「主源非 nil」分支上无条件
//  返回主源值且 `kind == .primary`；辅助源同字段值被丢弃。该性质以单测直接断言
//  （对 `WeatherFieldKey.allCases` **全枚举**断言）。
//  **绝不平均**（不存在 (a+b)/2 类算术合成路径）。
//
//  ── T10 泛化（ARCH-T10 §3.2）────────────────────────────────────────────────
//  泛化前 `merge` 是 **4 段结构相同、只是字段名不同的复制粘贴**（sunrise / sunset /
//  solarNoon / daylightDuration 各一段）。加字段必须手抄第 5 段，否则新字段
//  **永不合并**（恒 nil）；更险的是**抄错**（把 `.sunset` 分支粘成 `.sunrise`），
//  两个字段互相顶替而单测若不覆盖该字段则完全静默。
//  现在改为**按字段表遍历**：两条性质由**结构**保证（主源分支无条件优先、
//  循环体对每个 key 只「选择」一个值），而不是靠「记得抄对」。
//  → 因为测试与实现对**同一张 `WeatherFieldKey.allCases`** 遍历，
//    **新增字段自动进入两条性质断言，测试无需随字段增加而改**。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 逐字段降级合并器（纯函数）。
enum FieldFallbackResolver {

    /// 逐字段合并主源与若干辅助源的补丁。
    ///
    /// 规则（逐字段、对**全部**字段键一视同仁）：
    /// 1. 主源某字段非 nil → 保留主源值，`kind = .primary`（**绝不覆盖、绝不做平均**）；
    /// 2. 主源 nil 且任一辅助源该字段非 nil → 取**第一个**有值的辅助源，`kind = .fallback`；
    /// 3. 主源与所有辅助源皆 nil → 不写入（保持缺失，UI 走 "--"/隐藏，绝不用假值填）。
    ///
    /// - Parameters:
    ///   - primary: 主源补丁（多为稀疏，只装主源真正提供的字段）。
    ///   - auxiliary: 辅助源补丁列表（有序；同字段多源时以**链序优先者**为准）。
    /// - Returns: (合并后的稀疏补丁, 逐字段来源图)。
    static func merge(primary: FieldPatch,
                      auxiliary: [FieldPatch]) -> (patch: FieldPatch, provenance: FieldProvenanceMap) {

        var merged = FieldPatch(sourceID: primary.sourceID, capturedAt: primary.capturedAt)
        var provenance: [WeatherFieldKey: FieldProvenance] = [:]

        // 遍历「所有参与者实际装载过的字段」的并集 —— **不是**任何写死的字段清单。
        let allKeys = Set(primary.fields).union(auxiliary.flatMap { $0.fields })

        for key in allKeys {
            if let value = primary.value(key) {
                // ① 主源非 nil → 无条件优先；下面的辅助源分支**不可达**（结构性保证）。
                merged.set(key, value)
                provenance[key] = FieldProvenance(sourceID: primary.sourceID,
                                                  kind: .primary,
                                                  capturedAt: primary.capturedAt)
            } else if let source = auxiliary.first(where: { $0.value(key) != nil }),
                      let value = source.value(key) {
                // ② 主源缺 → 取**第一个**有值的辅助源（**选择**语义，非合成）。
                merged.set(key, value)
                provenance[key] = FieldProvenance(sourceID: source.sourceID,
                                                  kind: .fallback,
                                                  capturedAt: source.capturedAt)
            }
            // ③ 都无 → 不写入（保持缺失，不用假值填）。
        }

        return (merged, FieldProvenanceMap(map: provenance))
    }
}

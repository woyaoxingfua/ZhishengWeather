//
//  FieldFallbackResolver.swift
//  Core / Logic  [App + Widget 共用]
//
//  逐字段降级合并（纯函数，ARCH §3.1 / §12.4 硬约束①②）。
//
//  **硬约束②**：本类型必须是纯函数——无 I/O、无内部时钟（时间维度由
//  FieldPatch.capturedAt 承载，调用方注入）、无全局状态。
//
//  **硬约束①**：主源有值**绝不覆盖**——`merge` 在「主源非 nil」分支上无条件
//  返回主源值且 `kind == .primary`；辅助源同字段值被丢弃。该性质以单测直接断言
//  （主/辅同字段都给非 nil → 结果 == 主源值）。**绝不平均**（不存在 (a+b)/2 类合成路径）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 逐字段降级合并器（纯函数）。
enum FieldFallbackResolver {

    /// 逐字段合并主源与若干辅助源的补丁。
    ///
    /// 规则（逐字段、四条 solar 字段对称处理）：
    /// 1. 主源某字段非 nil → 保留主源值，`kind = .primary`（**绝不覆盖、绝不做平均**）；
    /// 2. 主源 nil 且任一辅助源该字段非 nil → 取**第一个**有值的辅助源，`kind = .fallback`；
    /// 3. 主源与所有辅助源皆 nil → 保持 nil（UI 走 "--"/隐藏，绝不用假值填）。
    ///
    /// - Parameters:
    ///   - primary: 主源补丁（多为 nil，因其 solar 字段来自主快照，由调用方填入）。
    ///   - auxiliary: 辅助源补丁列表（有序）。
    /// - Returns: (合并后的稀疏补丁, 逐字段来源图)。
    static func merge(primary: FieldPatch,
                      auxiliary: [FieldPatch]) -> (patch: FieldPatch, provenance: FieldProvenanceMap) {

        var merged = FieldPatch(sourceID: primary.sourceID,
                                capturedAt: primary.capturedAt,
                                sunrise: primary.sunrise,
                                sunset: primary.sunset,
                                solarNoon: primary.solarNoon,
                                daylightDuration: primary.daylightDuration)
        var provenance: [WeatherFieldKey: FieldProvenance] = [:]

        // sunrise
        if primary.sunrise != nil {
            provenance[.sunrise] = FieldProvenance(sourceID: primary.sourceID,
                                                   kind: .primary,
                                                   capturedAt: primary.capturedAt)
        } else if let src = auxiliary.first(where: { $0.sunrise != nil }) {
            merged.sunrise = src.sunrise
            provenance[.sunrise] = FieldProvenance(sourceID: src.sourceID,
                                                   kind: .fallback,
                                                   capturedAt: src.capturedAt)
        }

        // sunset
        if primary.sunset != nil {
            provenance[.sunset] = FieldProvenance(sourceID: primary.sourceID,
                                                  kind: .primary,
                                                  capturedAt: primary.capturedAt)
        } else if let src = auxiliary.first(where: { $0.sunset != nil }) {
            merged.sunset = src.sunset
            provenance[.sunset] = FieldProvenance(sourceID: src.sourceID,
                                                  kind: .fallback,
                                                  capturedAt: src.capturedAt)
        }

        // solarNoon（主源无此字段，天然验证「补一格」）
        if primary.solarNoon != nil {
            provenance[.solarNoon] = FieldProvenance(sourceID: primary.sourceID,
                                                     kind: .primary,
                                                     capturedAt: primary.capturedAt)
        } else if let src = auxiliary.first(where: { $0.solarNoon != nil }) {
            merged.solarNoon = src.solarNoon
            provenance[.solarNoon] = FieldProvenance(sourceID: src.sourceID,
                                                     kind: .fallback,
                                                     capturedAt: src.capturedAt)
        }

        // daylightDuration
        if primary.daylightDuration != nil {
            provenance[.daylightDuration] = FieldProvenance(sourceID: primary.sourceID,
                                                            kind: .primary,
                                                            capturedAt: primary.capturedAt)
        } else if let src = auxiliary.first(where: { $0.daylightDuration != nil }) {
            merged.daylightDuration = src.daylightDuration
            provenance[.daylightDuration] = FieldProvenance(sourceID: src.sourceID,
                                                            kind: .fallback,
                                                            capturedAt: src.capturedAt)
        }

        return (merged, FieldProvenanceMap(map: provenance))
    }
}

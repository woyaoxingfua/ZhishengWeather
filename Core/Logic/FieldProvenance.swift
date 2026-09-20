//
//  FieldProvenance.swift
//  Core / Logic  [App + Widget 共用]
//
//  逐字段来源图（FieldProvenanceMap）：记录每个字段来自哪个源、何种 kind。
//  内存态，不落盘、不进共享容器（ARCH §3.1 / §3.4）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 字段来源种类。
enum ProvenanceKind: String, Codable, Sendable {
    case primary        // 主源直出
    case fallback       // 主源缺该项，由辅助源补（L2 标注「来自 …」的依据）
    case localEstimate  // 本地估算（沿用生活指数范式）
}

/// 单字段来源记录。
struct FieldProvenance: Equatable, Sendable {
    var sourceID: SourceID
    var kind: ProvenanceKind
    var capturedAt: Date
}

/// 逐字段来源图（内存态，不落盘、不进共享载荷）。
struct FieldProvenanceMap: Equatable, Sendable {

    private var map: [WeatherFieldKey: FieldProvenance]

    /// 用既有映射构造（默认空）。
    init(map: [WeatherFieldKey: FieldProvenance] = [:]) {
        self.map = map
    }

    /// 取某字段的来源记录（缺失返回 nil，而非造一个假来源）。
    subscript(_ key: WeatherFieldKey) -> FieldProvenance? {
        map[key]
    }

    /// 被辅助源补齐（kind == .fallback）的字段集合（L2 / 分歧量诊断用）。
    var degradedFields: [WeatherFieldKey] {
        map.filter { $0.value.kind == .fallback }.map { $0.key }
    }
}

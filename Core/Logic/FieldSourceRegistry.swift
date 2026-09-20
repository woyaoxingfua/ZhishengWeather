//
//  FieldSourceRegistry.swift
//  Core / Logic  [App + Widget 共用]
//
//  注册表：capability → 有序源列表（主源在前）。
//
//  T10 起「接入一个新源」的改动面收敛为：新源四件套 + `SourceDirectory.all` 加一项声明
//  + `SourceComposition` append 一行。本注册表的查找逻辑**无需改动**（按能力过滤）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 按能力查找源的有序注册表。
///
/// `sources(for:)` 返回具备该能力的全部源（主源在前、辅助源在后）。
/// 协调器据此找到 `.solarEvents` 对应的第二源，调用点零改动即可接入新源。
struct FieldSourceRegistry: Sendable {

    private let sources: [any DataFieldSource]

    /// 用源列表组装注册表。
    init(sources: [any DataFieldSource]) {
        self.sources = sources
    }

    /// 返回具备指定能力的全部源（保持原顺序）。
    func sources(for capability: SourceCapability) -> [any DataFieldSource] {
        sources.filter { $0.capabilities.contains(capability) }
    }

    /// 返回全部已注册源。
    func allSources() -> [any DataFieldSource] {
        sources
    }

    /// 取源的展示名（未知则返回原始 rawValue）。
    func displayName(for id: SourceID) -> String {
        sources.first { $0.id == id }?.displayName ?? id.rawValue
    }
}

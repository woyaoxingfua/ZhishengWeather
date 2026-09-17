//
//  SpotlightIndexer.swift
//  ZhishengWeather（主 App target）
//
//  iOS 系统搜索（Spotlight）索引的**副作用出口**：把 Core 组装好的
//  `WeatherSpotlightItem` 落为系统 `CSSearchableIndex` 写入 / 删除。
//
//  分层（同 AppIconSwitcher 的「纯逻辑在 Core、副作用在 App」）：
//   - Core/Logic/WeatherSpotlight.swift：判定「有没有温度、描述写什么」（可单测）；
//   - 本文件：只做「值 → CSSearchableItem → 系统 API」的搬运与错误收敛。
//
//  纪律：
//  - **可注入**：系统面协议化为 `SearchIndexWriting`，单测塞 Spy，绝不触碰
//    真实 `CSSearchableIndex`（那会污染设备 / 模拟器的系统索引）。
//  - **只 import CoreSpotlight / Foundation / UniformTypeIdentifiers**：
//    本文件不 import UIKit（索引与界面无关）。
//  - **错误不静默，但绝不反噬主链路**：写入失败打印 + 上抛给调用方决定是否
//    展示；调用方（ContentView）只打印，**不弹窗、不改取数状态** ——
//    索引是增强能力，不是数据源，索引失败时天气功能必须完全不受影响。
//  - **不可用即跳过**：`isIndexingAvailable` 为 false（模拟器 / 受限环境 /
//    设备索引被系统暂停）时直接 return，不做任何系统调用，也不报错。
//  - **整体重写而非增量求差**：城市数量级是「数十」，无法在无持久状态的前提
//    下知道上次写了哪些 identifier；故先按域清空再写入当前集合，保证
//    **用户删掉的城市不会留下点了没反应的陈旧条目**（陈旧条目比多做两次
//    系统调用更伤）。条目 identifier 仍保持稳定，便于系统侧去重与后续
//    若引入持久化后改为增量。
//

import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

// MARK: - 注入缝

/// 系统索引写入能力面（单测注入点；生产实现转发 CSSearchableIndex）。
protocol SearchIndexWriting: Sendable {

    /// 系统索引当前是否可用（模拟器 / 受限环境可能为 false）。
    var isIndexingAvailable: Bool { get }

    /// 写入（已存在同 identifier 的条目会被覆盖更新）。
    /// - Parameter items: 待写入条目。
    func indexSearchableItems(_ items: [WeatherSpotlightItem]) async throws

    /// 按 identifier 删除。
    /// - Parameter identifiers: 待删除条目的唯一标识。
    func deleteSearchableItems(withIdentifiers identifiers: [String]) async throws

    /// 按域删除（清空本 App 在该域下的全部条目）。
    /// - Parameter domainIdentifiers: 域标识。
    func deleteSearchableItems(withDomainIdentifiers domainIdentifiers: [String]) async throws
}

/// 生产实现：转发 `CSSearchableIndex.default()`。
///
/// 注意：`CSSearchableIndex` 实例**不作存储属性**保存 —— 它不是 Sendable，
/// 存下来会让本 struct 无法声明 Sendable 一致性（进而让注入缝失效）。
struct SystemSearchIndexWriter: SearchIndexWriting {

    var isIndexingAvailable: Bool {
        CSSearchableIndex.isIndexingAvailable()
    }

    private var index: CSSearchableIndex {
        CSSearchableIndex.default()
    }

    func indexSearchableItems(_ items: [WeatherSpotlightItem]) async throws {
        let searchableItems: [CSSearchableItem] = items.map { Self.searchableItem(for: $0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.indexSearchableItems(searchableItems) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func deleteSearchableItems(withIdentifiers identifiers: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.deleteSearchableItems(withIdentifiers: identifiers) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func deleteSearchableItems(withDomainIdentifiers domainIdentifiers: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.deleteSearchableItems(withDomainIdentifiers: domainIdentifiers) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - 值 → CSSearchableItem

    /// 把 Core 的值类型条目转成系统条目。
    ///
    /// `contentDescription` 为 nil 时**不设**该属性（系统侧显示为空副标题），
    /// 绝不写一个占位数字代替。
    /// - Parameter item: Core 组装好的条目。
    /// - Returns: 系统索引条目。
    private static func searchableItem(for item: WeatherSpotlightItem) -> CSSearchableItem {
        let attributeSet: CSSearchableItemAttributeSet = CSSearchableItemAttributeSet(contentType: UTType.text)
        attributeSet.title = item.title
        attributeSet.contentDescription = item.contentDescription
        attributeSet.keywords = item.keywords
        return CSSearchableItem(uniqueIdentifier: item.uniqueIdentifier,
                                domainIdentifier: WeatherSpotlight.domainIdentifier,
                                attributeSet: attributeSet)
    }
}

// MARK: - 索引器

/// 城市天气的 Spotlight 索引器。
///
/// 非隔离（`Sendable`）：只在 async 函数里接触 Sendable 入参与注入的
/// `SearchIndexWriting`，故从 @MainActor 调用无需跨 actor 跳跃，也不会
/// 产生并发告警。
final class SpotlightIndexer: Sendable {

    /// 系统写入实现（生产 = SystemSearchIndexWriter；单测 = Spy）。
    private let writer: SearchIndexWriting

    /// 生产共享实例（视图层挂索引用；单测另建实例注入 Spy）。
    static let shared: SpotlightIndexer = SpotlightIndexer()

    /// - Parameter writer: 系统写入实现。
    init(writer: SearchIndexWriting = SystemSearchIndexWriter()) {
        self.writer = writer
    }

    /// 把当前城市列表（含已知快照）写入系统索引。
    ///
    /// 流程：可用性检查（不可用直接跳过）→ 按域清空 → 写入当前集合。
    /// 任一步失败都打印 + 上抛，**调用方决定如何提示**（主链路不受影响）。
    ///
    /// - Parameters:
    ///   - cities: 当前城市列表。
    ///   - snapshotByCityID: 城市 id → 最近一次成功快照（无快照的城市按
    ///     Core 的诚实纪律只写静态文案）。
    /// - Throws: 系统索引写入 / 清空失败（已打印）。
    func index(cities: [City], snapshotByCityID: [String: WeatherSnapshot]) async throws {
        guard writer.isIndexingAvailable else {
            // 模拟器 / 受限环境 / 系统索引被暂停：跳过是**正确行为**，
            // 不是故障 —— 索引只是增强，缺了它天气功能完好，故不抛错。
            print("[SpotlightIndexer] 系统搜索索引不可用（模拟器或受限环境），跳过写入")
            return
        }

        let items: [WeatherSpotlightItem] = WeatherSpotlightBuilder.items(
            cities: cities,
            snapshotByCityID: snapshotByCityID
        )
        guard !items.isEmpty else { return }

        do {
            // 先清域：删除用户已移除城市留下的陈旧条目（点了没反应的搜索
            // 结果比多一次系统调用更伤）。城市数量级为数十，代价可忽略。
            try await writer.deleteSearchableItems(
                withDomainIdentifiers: [WeatherSpotlight.domainIdentifier]
            )
            try await writer.indexSearchableItems(items)
        } catch {
            print("[SpotlightIndexer] 写入系统搜索索引失败：\(error)")
            throw error
        }
    }

    /// 按 identifier 删除条目。
    /// - Parameter identifiers: 待删除条目的唯一标识。
    /// - Throws: 系统删除失败（已打印）。
    func remove(identifiers: [String]) async throws {
        guard writer.isIndexingAvailable, !identifiers.isEmpty else { return }
        do {
            try await writer.deleteSearchableItems(withIdentifiers: identifiers)
        } catch {
            print("[SpotlightIndexer] 删除系统搜索条目失败：\(error)")
            throw error
        }
    }

    /// 清空本 App 在索引域下的全部条目。
    /// - Throws: 系统删除失败（已打印）。
    func removeAll() async throws {
        guard writer.isIndexingAvailable else { return }
        do {
            try await writer.deleteSearchableItems(
                withDomainIdentifiers: [WeatherSpotlight.domainIdentifier]
            )
        } catch {
            print("[SpotlightIndexer] 清空系统搜索索引失败：\(error)")
            throw error
        }
    }
}

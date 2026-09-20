//
//  SourceAttributionStore.swift
//  Core / Logic  [App + Widget 共用]
//
//  L1 来源归属的 App 本地存储（ARCH v1.1 裁定：共享载荷本轮零改动，
//  归属改由 App 本地 UserDefaults.standard 承担）。
//
//  落点纪律：可注入 `UserDefaults`（默认 `.standard`），**不进 App Group**、
//  **不进共享载荷**（侧载下 App Group 恒不可用）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 一次来源归属记录。
struct SourceAttribution: Equatable, Codable, Sendable {
    /// 主源标识（本轮恒为 open-meteo-forecast）。
    var primarySourceID: SourceID
    /// 是否发生过字段级降级（任一字段由备源补齐）。
    var hasFieldFallback: Bool
    /// 记录时刻（调用方注入）。
    var at: Date
}

/// L1 来源归属存储（App 本地 .standard，可注入 suite）。
struct SourceAttributionStore: Sendable {

    private let defaults: UserDefaults
    private let key: String

    /// 注入式初始化（测试传独立 suite）。
    init(defaults: UserDefaults = .standard, key: String = "zs.sourceAttribution.v1") {
        self.defaults = defaults
        self.key = key
    }

    /// 全量共享实例（App 侧默认）。
    static let shared = SourceAttributionStore()

    /// 记录最近一次成功归属（冷启动 / 缓存态也诚实）。
    func record(primaryID: SourceID, hasFieldFallback: Bool, at date: Date) {
        let record = SourceAttribution(primarySourceID: primaryID,
                                       hasFieldFallback: hasFieldFallback,
                                       at: date)
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
    }

    /// 读取最近一次成功归属（无记录 → nil）。
    func load() -> SourceAttribution? {
        guard let data = defaults.data(forKey: key),
              let record = try? JSONDecoder().decode(SourceAttribution.self, from: data) else {
            return nil
        }
        return record
    }
}

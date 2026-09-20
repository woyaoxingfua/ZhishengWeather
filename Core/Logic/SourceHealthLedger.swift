//
//  SourceHealthLedger.swift
//  Core / Logic  [App + Widget 共用]
//
//  源健康计数持久化（极小的计数/冷却记录）。
//
//  落点纪律（ARCH §4.2 / R-9）：
//  - 位置可注入 `UserDefaults`（默认 `.standard`）——**不是 App Group**
//    （侧载下恒不可用），**不进**共享载荷；
//  - 只存 [SourceID: Entry] 极小结构（lastSuccessAt / consecutiveMissing /
//    cooldownUntil / todayUsageCount）；
//  - **坏 JSON → 空账本，且绝不覆盖写**（一次解码失败就把历史健康数据清空
//    是不可接受的，ARCH §7 T07 单测锚此性质）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 源健康账本（可注入 UserDefaults，纯值类型）。
struct SourceHealthLedger: Sendable {

    /// 单源健康条目（可选字段 + 默认值，合成 Codable）。
    struct Entry: Codable, Sendable {
        var lastSuccessAt: Date? = nil
        var consecutiveMissing: Int = 0
        var cooldownUntil: Date? = nil
        var todayUsageCount: Int = 0
    }

    /// 持久化键（internal，供单测写入坏字节验证「不覆盖写」）。
    static let storeKey = "zs.sourceHealthLedger.v1"

    private let defaults: UserDefaults
    private let key: String

    /// 注入式初始化（测试传独立 suite，不污染 `.standard`）。
    init(defaults: UserDefaults = .standard, key: String = storeKey) {
        self.defaults = defaults
        self.key = key
    }

    /// 全量加载。
    ///
    /// 坏 JSON → 返回空账本 `[:]`，且**不写入**（绝不清空历史数据）。
    func loadAll() -> [SourceID: Entry] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        guard let raw = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            // 坏 JSON：空账本 + 不覆盖写。
            return [:]
        }
        var result: [SourceID: Entry] = [:]
        for (rawKey, entry) in raw {
            result[SourceID(rawValue: rawKey)] = entry
        }
        return result
    }

    /// 全量保存。
    ///
    /// 编码失败（极少见）→ 静默忽略，不破坏既有账本。
    func saveAll(_ ledger: [SourceID: Entry]) {
        var raw: [String: Entry] = [:]
        for (id, entry) in ledger {
            raw[id.rawValue] = entry
        }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        defaults.set(data, forKey: key)
    }
}

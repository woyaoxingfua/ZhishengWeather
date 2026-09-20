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
    struct Entry: Codable, Sendable, Equatable {
        var lastSuccessAt: Date? = nil
        var consecutiveMissing: Int = 0
        var cooldownUntil: Date? = nil
        var todayUsageCount: Int = 0
    }

    /// 持久化键（internal，供单测写入坏字节验证「不覆盖写」）。
    static let storeKey = "zs.sourceHealthLedger.v1"

    /// 坏账本留档键后缀。
    ///
    /// 为什么需要它：`loadAll()` 的契约是"坏 JSON → 空账本且**不写回**"，这条守住了
    /// 「读取不销毁数据」。但**写入路径**仍然会踩同一个坑——一旦账本字节损坏，
    /// 下一次任何源的 `recordSuccess` 都会用一个只含单个源的账本**整体覆盖**，
    /// 于是其余源的历史健康数据被**静默销毁**（读取时明明保住了，写入时又丢）。
    /// 因此 `saveAll` 在覆盖前先把不可解析的现存字节留档到此键，
    /// 让"丢"这件事**可追溯**而不是无声发生。
    static let quarantineKeySuffix = ".corrupt"

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
            // `SourceID` 转 enum 后 `init?(rawValue:)` 是**可失败**的：
            // 未知 rawValue（旧版本登记过、现已删除的源）→ **跳过该项**，
            // 绝不造一个假 id 混进账本。副作用是该项在下一次 `saveAll` 时
            // 随之消失 —— 这正是「该源已不存在」应有的行为。
            guard let id = SourceID(rawValue: rawKey) else { continue }
            result[id] = entry
        }
        return result
    }

    /// 全量保存。
    ///
    /// 编码失败（极少见）→ 静默忽略，不破坏既有账本。
    ///
    /// 覆盖写之前先把**不可解析**的现存字节留档到 `key + quarantineKeySuffix`：
    /// `loadAll()` 只保证"读不写"，但损坏的账本一旦被下一次写入整体覆盖，
    /// 其余源的历史就**静默消失**了。留档让这次丢失**可追溯**。
    func saveAll(_ ledger: [SourceID: Entry]) {
        var raw: [String: Entry] = [:]
        for (id, entry) in ledger {
            raw[id.rawValue] = entry
        }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        if let existing = defaults.data(forKey: key),
           (try? JSONDecoder().decode([String: Entry].self, from: existing)) == nil {
            defaults.set(existing, forKey: key + Self.quarantineKeySuffix)
        }
        defaults.set(data, forKey: key)
    }
}

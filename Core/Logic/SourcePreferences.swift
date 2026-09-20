//
//  SourcePreferences.swift
//  Core / Logic  [App + Widget 共用]
//
//  多源手动停用偏好（D-C5 / AC-C13）：用户可停用某源，
//  停用只影响该源的降级参与，不影响其余源、绝不换城市。
//
//  落点纪律：可注入 `UserDefaults`（默认 `.standard`），**不进 App Group**、
//  **不进共享载荷**（ARCH §4.3）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 多源手动停用偏好（纯值类型，可注入 suite）。
struct SourcePreferences: Sendable {

    private let defaults: UserDefaults
    private let key: String

    /// 注入式初始化（测试传独立 suite）。
    init(defaults: UserDefaults = .standard, key: String = "zs.sourcePreferences.v1") {
        self.defaults = defaults
        self.key = key
    }

    /// 全量共享实例（App 侧默认）。
    static let shared = SourcePreferences()

    /// 某源是否被手动停用。
    func isDisabled(_ id: SourceID) -> Bool {
        disabledSet().contains(id)
    }

    /// 设置某源的手动停用状态。
    func setDisabled(_ id: SourceID, disabled: Bool) {
        var set = disabledSet()
        if disabled {
            set.insert(id)
        } else {
            set.remove(id)
        }
        guard let data = try? JSONEncoder().encode(set) else { return }
        defaults.set(data, forKey: key)
    }

    // MARK: - Private

    private func disabledSet() -> Set<SourceID> {
        guard let data = defaults.data(forKey: key) else { return [] }
        // 快路径：整体解码。`SourceID` 自带**双形态解码**（新单值字符串 / 旧 keyed
        // `{rawValue}`），故旧数据也能走通。
        if let set = try? JSONDecoder().decode(Set<SourceID>.self, from: data) {
            return set
        }
        // 慢路径（**必须存在**）：集合里含**当前版本不认识**的 rawValue 时走这里。
        //
        // ⚠️ 为什么不能只靠快路径：`SourceID.init(from:)` 对未知 rawValue 会 **throw**
        // （这是对的——单值解码不该猜），但放进**集合**解码时，**一个**未知元素会让
        // **整个集合**解码失败；而本函数若用 `try? … ?? []` 兜底，后果是
        // **用户全部「停用某源」偏好被静默清空**，且下次 `setDisabled` 会用空集
        // **覆盖写**——连恢复的机会都没有。
        // 触发场景：装过更新版后回退、或某个源被删除 / 改了 rawValue。
        // 这与 `SourceHealthLedger` 对未知键 `continue` 跳过的处理**必须对称**：
        // 同一个未知键，账本安全而偏好集被清空，是不可接受的不对称。
        return Self.lenientSourceIDs(from: data)
    }

    /// 从 JSON 数组里尽力提取 `SourceID`，**跳过认不出的元素**（不抛错、不清空）。
    ///
    /// 用 `JSONSerialization` 而不是**逐元素 `decode`**：后者在解码失败时
    /// "容器游标是否推进"的语义依赖 Foundation 实现细节，一旦假设错了会
    /// **死循环**（`isAtEnd` 永远为 false）。这里先把结构完整取出来，再纯函数式过滤，
    /// 从根上避开那个不确定性。
    private static func lenientSourceIDs(from data: Data) -> Set<SourceID> {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let array = object as? [Any] else {
            return []
        }
        let rawValues: [String] = array.compactMap { element in
            if let raw = element as? String { return raw }                       // 新形态
            if let dict = element as? [String: Any] { return dict["rawValue"] as? String } // 旧形态
            return nil
        }
        // `compactMap` 才是"跳过认不出的"的那一步：未知 rawValue 在此被丢弃，
        // 而不是让整个集合解码失败。
        return Set(rawValues.compactMap { SourceID(rawValue: $0) })
    }
}

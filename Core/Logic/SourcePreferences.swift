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
        guard let data = defaults.data(forKey: key),
              let set = try? JSONDecoder().decode(Set<SourceID>.self, from: data) else {
            return []
        }
        return set
    }
}

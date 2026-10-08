//
//  SourceHealthTracker.swift
//  Core / Logic  [App + Widget 共用]
//
//  源级健康与摘除判定（运行期 actor）。纯判定 + 可注入持久化；
//  **不联网、不进 App Group**（ARCH §4.2）。
//
//  自动摘除**只对「参与自动摘除」的源生效**（判据来自源描述符的
//  `participatesInAutoExclusion`，T10 §3.4）：主源只记录、不自动摘；
//  主源失败仍走既有 `.failed(cached:)` 路径（ARCH R-7 / H-8）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//  actor 隔离：所有状态经 actor 串行访问，避免竞态。
//

import Foundation

/// 源级健康跟踪器（运行期判定 + 持久化）。
actor SourceHealthTracker {

    /// 全量共享实例（App 侧默认接线点）。
    static let shared = SourceHealthTracker()

    private let policy: ExclusionPolicy
    private let ledger: SourceHealthLedger
    private let preferences: SourcePreferences

    /// 本会话内摘除（auth / missingFields 用；rateLimit 走持久化冷却）。
    private var sessionExclusions: [SourceID: ExclusionReason] = [:]

    /// 注入式初始化（测试传独立 ledger / preferences）。
    init(policy: ExclusionPolicy = .default,
         ledger: SourceHealthLedger = SourceHealthLedger(defaults: .standard),
         preferences: SourcePreferences = .shared) {
        self.policy = policy
        self.ledger = ledger
        self.preferences = preferences
    }

    /// 该源是否参与自动摘除（仅参与自动摘除的源会被 EV-1 / EV-3 摘掉）。
    ///
    /// T10 §3.4：行为来源改为描述符的**显式布尔** `participatesInAutoExclusion`，
    /// 不再借 `role`（展示标记）表达 —— 「改展示文案的人顺手改了摘除行为」这种错位被消除。
    /// 未登记的源一律 `false`（fail-closed：认不出来的源绝不自动摘除）。
    private func isAuxiliary(_ id: SourceID) -> Bool {
        SourceDirectory.descriptor(for: id)?.participatesInAutoExclusion ?? false
    }

    /// 记录一次成功（清零连续缺失、累计今日用量、解除会话摘除）。
    func recordSuccess(_ id: SourceID, at date: Date) {
        var all = ledger.loadAll()
        var entry = all[id] ?? SourceHealthLedger.Entry()
        entry.lastSuccessAt = date
        entry.consecutiveMissing = 0
        entry.todayUsageCount += 1
        all[id] = entry
        ledger.saveAll(all)
        sessionExclusions.removeValue(forKey: id)
    }

    /// EV-1：记录一次必填字段缺失。
    ///
    /// 仅对**辅助源**自动摘；主源只记录、不摘。
    /// - 缺失集为空 → 视为「全绿」，清零连续计数（不摘除）；
    /// - 缺失集非空 → 连续计数 +1，达到阈值返回 `.missingFields(consecutive:)`。
    /// - Returns: 命中阈值后的摘除原因（未命中返回 nil）。
    func recordMissingFields(_ id: SourceID, missing: Set<WeatherFieldKey>, at date: Date) -> ExclusionReason? {
        guard isAuxiliary(id) else { return nil }

        if missing.isEmpty {
            // 全绿：清零计数（不摘除、不重置 lastSuccess 之外的健康）。
            var all = ledger.loadAll()
            var entry = all[id] ?? SourceHealthLedger.Entry()
            entry.consecutiveMissing = 0
            all[id] = entry
            ledger.saveAll(all)
            sessionExclusions.removeValue(forKey: id)
            return nil
        }

        var all = ledger.loadAll()
        var entry = all[id] ?? SourceHealthLedger.Entry()
        entry.consecutiveMissing += 1
        all[id] = entry
        ledger.saveAll(all)

        if entry.consecutiveMissing >= policy.consecutiveMissingThreshold {
            let reason = ExclusionReason.missingFields(consecutive: entry.consecutiveMissing)
            sessionExclusions[id] = reason
            return reason
        }
        return nil
    }

    /// EV-3：按 HTTP 状态码判定。
    ///
    /// - 401/403 → `.auth`（本会话内摘除）；
    /// - 429 → `.rateLimit(until: now + 冷却)`（冷却期内不请求）；
    /// - 其余 → nil。
    /// 仅对辅助源生效。
    func recordHTTPStatus(_ id: SourceID, status: Int, at date: Date) -> ExclusionReason? {
        guard isAuxiliary(id) else { return nil }

        if status == 401 || status == 403 {
            let reason = ExclusionReason.auth
            sessionExclusions[id] = reason
            return reason
        }
        if status == 429 {
            let until = date.addingTimeInterval(policy.rateLimitCooldown)
            var all = ledger.loadAll()
            var entry = all[id] ?? SourceHealthLedger.Entry()
            entry.cooldownUntil = until
            all[id] = entry
            ledger.saveAll(all)
            return ExclusionReason.rateLimit(until: until)
        }
        return nil
    }

    /// 当前是否处于限流冷却中。
    func isCoolingDown(_ id: SourceID, now: Date) -> Bool {
        guard let until = ledger.loadAll()[id]?.cooldownUntil else { return false }
        return until > now
    }

    /// 取当前摘除原因（综合：手动停用 > 会话摘除 > 冷却中）。无 → nil。
    func exclusionReason(for id: SourceID, now: Date) -> ExclusionReason? {
        if preferences.isDisabled(id) { return .userDisabled }
        if let reason = sessionExclusions[id] { return reason }
        if isCoolingDown(id, now: now) {
            if let until = ledger.loadAll()[id]?.cooldownUntil {
                return ExclusionReason.rateLimit(until: until)
            }
        }
        return nil
    }

    /// 设置页「多源管理」的数据源：逐源状态 + 最近成功 + 今日用量。
    ///
    /// 主源恒为「在用」；辅助源按 手动停用 / 会话摘除 / 冷却 / 备用 推导。
    ///
    /// ⚠️ **为什么 `todayUsage` 不再兜底成 0**（2026-10-09修复）：
    /// 原先每个分支都写 `?.todayUsageCount ?? 0`，把「本地无该源记录」
    /// 压成「今日用量 0」。这正是设置页「数据源调用次数全为 0」的**显示侧根因**：
    /// 它让「从未接入计数」与「接入了但今天真的一次没成功」显示成同一个数字，
    /// 而两者对用户含义相反。现在如实传 `nil`，由 UI 渲染成「—」。
    /// 计数不全责在无自增路径，已逐源接线 + 由
    /// `ZhishengWeatherTests/SourceUsageCountingGuardTests` 机械守卫。
    func snapshot(now: Date) -> [SourceStatusRow] {
        SourceCatalog.all.map { item in
            let id = item.id
            let entry = ledger.loadAll()[id]
            if preferences.isDisabled(id) {
                return SourceStatusRow(id: id,
                                      displayName: item.displayName,
                                      state: .excluded(.userDisabled),
                                      lastSuccessAt: entry?.lastSuccessAt,
                                      todayUsage: entry?.todayUsageCount)
            }
            if let reason = sessionExclusions[id] {
                return SourceStatusRow(id: id,
                                      displayName: item.displayName,
                                      state: .excluded(reason),
                                      lastSuccessAt: entry?.lastSuccessAt,
                                      todayUsage: entry?.todayUsageCount)
            }
            if isCoolingDown(id, now: now) {
                return SourceStatusRow(id: id,
                                      displayName: item.displayName,
                                      state: .excluded(.rateLimit(until: ledger.loadAll()[id]?.cooldownUntil ?? now)),
                                      lastSuccessAt: entry?.lastSuccessAt,
                                      todayUsage: entry?.todayUsageCount)
            }
            let state: SourceStatusState = (item.role == .primary) ? .primaryActive : .standby
            return SourceStatusRow(id: id,
                                  displayName: item.displayName,
                                  state: state,
                                  lastSuccessAt: entry?.lastSuccessAt,
                                  todayUsage: entry?.todayUsageCount)
        }
    }

    // MARK: - 用量占比（设置页「多源管理」逐源占比条）

    /// 全部源的今日用量**合计**（只累加**已接入计数且有记录**的源）。
    ///
    /// ⚠️ **口径纪律**：分母**只由已接入计数的源构成**。把未接入的源算进分母
    /// 会让所有真实源的占比被凭空稀释（读者以为"它占了 0%"，其实它压根没参与）。
    /// 未接入的源在 UI 上显示「—」且**不画占比条**，不参与分母。
    ///
    /// - Returns: 合计次数；无任何记录时为 0。
    static func totalCountedUsage(rows: [SourceStatusRow]) -> Int {
        rows.reduce(into: 0) { running, row in
            // `countsUsage == false` 的源不参与合计（见上文口径纪律）。
            guard SourceDirectory.descriptor(for: row.id)?.countsUsage == true else { return }
            running += row.todayUsage ?? 0
        }
    }

    /// 单源占比（0…1）。**未接入计数的源一律返回 nil**（UI 据此不画占比条）。
    ///
    /// - Parameters:
    ///   - row: 目标源行。
    ///   - total: 全部已接入计数源的合计（由 `totalCountedUsage` 给出）。
    /// - Returns: 占比；未接入 / 无记录 / 合计为 0 时为 nil。
    static func usageShare(for row: SourceStatusRow, total: Int) -> Double? {
        guard SourceDirectory.descriptor(for: row.id)?.countsUsage == true else { return nil }
        guard let usage = row.todayUsage, total > 0 else { return nil }
        return Double(usage) / Double(total)
    }
}

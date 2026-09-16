//
//  LinkHealthRecorder.swift
//  Core / Logic  [App + Widget 共用]
//
//  数据链路健康记录器（actor，**进程内内存，不持久化**）。
//
//  为何要单独记录「尝试」：只记录成功的健康表无法区分「从未运行」与「运行后失败」，
//  而真机烟测最需要的正是这个区分 —— 故 `recordAttempt` 与
//  `recordSuccess` / `recordFailure` 分离。
//
//  纪律：
//  - **不落盘**：绝不碰 App Group、绝不新增 payload key（纯本地诊断）。
//  - **绝不向调用方抛错**：全部方法非 throwing，接入点只是纯追加。
//  - 时刻一律由调用方注入 `at:` —— 本文件内**不出现任何 `Date()`**。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 数据链路健康记录器。
actor LinkHealthRecorder {

    /// 进程内共享单例：各链路 catch 点直接上报，设置页读取快照。
    static let shared = LinkHealthRecorder()

    /// 记录表（key = 链路标识）。
    private var records: [LinkIdentifier: LinkHealth] = [:]

    init() {}

    /// 记录一次「尝试」（尚未知成败）。
    ///
    /// 在发起请求**前**调用，使「从未运行」与「运行后失败」可区分。
    /// - Parameters:
    ///   - identifier: 链路标识。
    ///   - date: 尝试时刻（调用方注入）。
    func recordAttempt(_ identifier: LinkIdentifier, at date: Date) {
        var record = existingOrNew(identifier)
        record.lastAttemptAt = date
        records[identifier] = record
    }

    /// 记录一次「成功」（同时把尝试时刻推进到本次）。
    ///
    /// **不**清除 `lastErrorMessage`：保留最近一次错误信息便于回溯，
    /// 是否展示由 UI 依据派生状态决定（见 `LinkHealth`）。
    /// - Parameters:
    ///   - identifier: 链路标识。
    ///   - date: 成功时刻（调用方注入）。
    func recordSuccess(_ identifier: LinkIdentifier, at date: Date) {
        var record = existingOrNew(identifier)
        record.lastAttemptAt = date
        record.lastSuccessAt = date
        records[identifier] = record
    }

    /// 记录一次「失败」（保留错误信息）。
    /// - Parameters:
    ///   - identifier: 链路标识。
    ///   - date: 失败时刻（调用方注入）。
    ///   - message: 错误描述（可为 nil）。
    func recordFailure(_ identifier: LinkIdentifier, at date: Date, message: String?) {
        var record = existingOrNew(identifier)
        record.lastAttemptAt = date
        record.lastErrorMessage = message
        records[identifier] = record
    }

    /// 只读快照：按 `LinkIdentifier.allCases` 顺序返回**全部**链路记录；
    /// 从未记录的链路返回默认「从未尝试」记录（面板据此显示 从未尝试，而非空屏）。
    /// - Returns: 固定顺序的记录数组。
    func snapshot() -> [LinkHealth] {
        LinkIdentifier.allCases.map { existingOrNew($0) }
    }

    /// 清空全部记录（仅测试用）。
    func reset() {
        records.removeAll()
    }

    // MARK: - Private

    /// 取既有记录，缺失则以标识构造默认记录（displayName 取标识的单一真源）。
    private func existingOrNew(_ identifier: LinkIdentifier) -> LinkHealth {
        records[identifier]
            ?? LinkHealth(identifier: identifier, displayName: identifier.displayName)
    }
}

//
//  LinkHealth.swift
//  Core / Models  [App + Widget 共用]
//
//  数据链路健康记录（真机诊断用）：记录每条数据链路最近一次「尝试」与「成败」。
//
//  设计要点：
//  - 纯值类型 + **纯函数**派生状态（注入 now 与窗口，可确定性单测）；
//  - **不持久化**：仅进程内内存，绝不进 App Group、绝不新增 payload key；
//  - 所有字段 Optional + 默认 nil + 合成 Codable（禁手写 `init(from:)`、禁 `payloadVersion`）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//  （状态派生要求调用方注入 `now` —— 本文件内不出现任何 `Date()`。）
//

import Foundation

/// 数据链路标识（稳定字符串；可作 `ForEach` 的 id）。
enum LinkIdentifier: String, Codable, CaseIterable, Sendable {
    /// 主天气链路（forecast + minutely）。
    case forecast
    /// 空气质量第二链路（`air-quality-api.open-meteo.com`）。
    case airQuality
    /// 历史 / 气候档案链路（`archive-api.open-meteo.com`）。
    case archive
    /// 集合预报第三链路（`ensemble-api.open-meteo.com`）。
    case ensemble
    /// 城市搜索链路（`geocoding-api.open-meteo.com`）。
    case geocoding

    /// 展示名（诊断面板用；单一真源，避免调用点各自写字符串）。
    var displayName: String {
        switch self {
        case .forecast: return "天气预报"
        case .airQuality: return "空气质量"
        case .archive: return "历史资料"
        case .ensemble: return "集合预报"
        case .geocoding: return "城市搜索"
        }
    }
}

/// 链路派生状态（不入库；由 `LinkHealth.state(now:freshnessWindow:)` 纯函数求出）。
enum LinkHealthState: Equatable, Sendable {
    /// 从未尝试。
    case neverAttempted
    /// 正常（最近一次尝试成功，且未超过新鲜度窗口）。
    case healthy
    /// 陈旧（最近一次成功已超过新鲜度窗口，但最近一次尝试并非失败）。
    case stale
    /// 失败（最近一次尝试以失败告终，或从未成功过）。
    case failed

    /// 展示文案。
    var displayName: String {
        switch self {
        case .neverAttempted: return "从未尝试"
        case .healthy: return "正常"
        case .stale: return "陈旧"
        case .failed: return "失败"
        }
    }
}

/// 单条链路的健康记录。
struct LinkHealth: Codable, Equatable, Identifiable, Sendable {

    /// 链路标识。
    var identifier: LinkIdentifier
    /// 展示名。
    var displayName: String
    /// 最近一次「尝试」时刻（无论成败）。nil = 从未尝试。
    var lastAttemptAt: Date? = nil
    /// 最近一次「成功」时刻。nil = 从未成功。
    var lastSuccessAt: Date? = nil
    /// 最近一次「失败」的错误信息（成功**不**清除，便于回溯；是否展示由 UI 决定）。
    var lastErrorMessage: String? = nil

    /// 以链路标识作为稳定 id。
    var id: String { identifier.rawValue }

    /// 派生状态（**纯函数**：注入 now 与新鲜度窗口，本类型内不调用 `Date()`）。
    ///
    /// 判定顺序（先「从未尝试」，再判「失败」，最后在「成功」上分 正常/陈旧）：
    /// 1. `lastAttemptAt == nil` → 从未尝试；
    /// 2. 最近一次尝试**未成功**（`lastSuccessAt == nil` 或 `lastSuccessAt < lastAttemptAt`）
    ///    → 失败 —— 含「只尝试过、从未成功」，故**只失败过的链路绝不会被判为正常**；
    /// 3. 其余（最近一次尝试即成功）：距最近成功 ≤ 窗口 → 正常；> 窗口 → 陈旧。
    ///
    /// 边界（含端点）：`now - lastSuccessAt == freshnessWindow` 判为**正常**；
    /// 再多 1 秒即**陈旧**（算术见对应单测注释）。
    ///
    /// - Parameters:
    ///   - now: 当前时刻（由调用方注入 —— Core 内禁止取系统时钟）。
    ///   - freshnessWindow: 新鲜度窗口（秒）；由 App 侧透传 `WeatherViewModel` 的既有常量，
    ///     避免在 Core 里固化第二个「15 分钟」字面量。
    /// - Returns: 派生状态。
    func state(now: Date, freshnessWindow: TimeInterval) -> LinkHealthState {
        guard let lastAttemptAt else { return .neverAttempted }
        guard let lastSuccessAt, lastSuccessAt >= lastAttemptAt else { return .failed }
        let age = now.timeIntervalSince(lastSuccessAt)
        return age <= freshnessWindow ? .healthy : .stale
    }
}

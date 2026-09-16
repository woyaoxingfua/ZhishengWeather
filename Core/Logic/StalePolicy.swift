//
//  StalePolicy.swift
//  Core / Logic  [App + Widget 共用]
//
//  数据新鲜度（陈旧）判定 —— **纯函数**，便于边界单测（本轮要求之一）。
//
//  背景：`refreshIfNeeded` 的 15 分钟窗口只治理「要不要再取数」，不代表
//  「屏幕上的数据还算不算新」。二者必须分开：
//    - 15 分钟窗口 → 触发刷新；
//    - 本阈值 → 给用户「数据可能已过期」的**可见标记**。
//
//  纪律：纯逻辑；`now` 一律由调用方注入（Core 禁内部 `Date()`），保证可测。
//

import Foundation

/// 数据陈旧判定。
enum StalePolicy {

    /// 默认陈旧阈值：30 分钟（= 前台 15 分钟新鲜度窗口的 2 倍）。
    ///
    /// 取值理由：数据在 15 分钟后即「该刷了」，但一次失败不该立刻打红；
    /// 给到 2 倍窗口（30 分钟）才提示「可能已过期」，既不过敏也不迟钝。
    static let defaultThreshold: TimeInterval = 30 * 60

    /// 给定「数据时刻」判断是否已陈旧。
    ///
    /// 边界裁定：**恰好等于阈值不算陈旧**（判定式取「严格大于」），
    /// 只有超过阈值才为 true —— 便于边界用例（恰好 / 略小 / 略大）明确断言。
    /// - Parameters:
    ///   - lastUpdated: 数据的时刻；nil = 无从证明新鲜 → 视为陈旧。
    ///   - now: 当前时刻（注入）。
    ///   - threshold: 阈值（秒）；默认 `defaultThreshold`。
    /// - Returns: 是否陈旧。
    static func isStale(lastUpdated: Date?,
                        now: Date,
                        threshold: TimeInterval = StalePolicy.defaultThreshold) -> Bool {
        guard let lastUpdated else { return true }
        return now.timeIntervalSince(lastUpdated) > threshold
    }

    /// 数据年龄（秒）。
    /// - Parameters:
    ///   - lastUpdated: 数据的时刻；nil → nil。
    ///   - now: 当前时刻（注入）。
    /// - Returns: 自数据时刻起的秒数；无时间戳 → nil。
    static func age(lastUpdated: Date?, now: Date) -> TimeInterval? {
        guard let lastUpdated else { return nil }
        return now.timeIntervalSince(lastUpdated)
    }
}

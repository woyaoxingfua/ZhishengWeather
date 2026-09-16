//
//  EnsembleForecast.swift
//  Core / Models  [App + Widget 共用]
//
//  集合预报领域模型：由 `EnsembleMapper` 从 DTO 映射而来，**仅存于
//  WeatherViewModel 的独立属性 `ensemble`**，不进 `WeatherSnapshot` /
//  共享容器 / App Group 键（ARCH-A2 §1.1① 纪律平移，Widget 载荷契约零改动）。
//
//  结构（成员优先 / member-major）：每一条 `memberSeries` 是**一个成员**的逐小时
//  降水序列，下标与 `times` 对齐。此排布便于：
//    - 逐小时统计：取各成员在该小时的取值 → 成员比例 + 分位（见 EnsembleProbabilityEngine）；
//    - 窗口聚合：判断「某成员在窗口内是否有雨」（沿单条序列扫描）。
//  控制成员（`precipitation`，无 `_member` 后缀）**不计入** `memberSeries`。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 集合预报领域模型。
struct EnsembleForecast: Codable, Equatable, Sendable {

    /// 逐小时时刻（已按 `utcOffsetSeconds` 解释为绝对时刻）。与 `memberSeries` 下标对齐。
    var times: [Date]
    /// 各成员降水序列（mm，元素为 nil 表示服务端缺失）。只含 `_memberNN`，不含控制成员。
    var memberSeries: [[Double?]]
    /// 时间字符串所属 UTC 偏移秒（诊断用；随响应根级 `utc_offset_seconds`，缺省 0）。
    var utcOffsetSeconds: Int

    /// 成员数 = `memberSeries.count`。**来自数据，绝不硬编码**（成员数随模式 1/30/40/50…）。
    var memberCount: Int { memberSeries.count }

    /// 空预报（无成员 / 无时刻）：UI 侧据此整块隐藏。
    static let empty = EnsembleForecast(times: [], memberSeries: [], utcOffsetSeconds: 0)
}

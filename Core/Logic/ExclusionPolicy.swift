//
//  ExclusionPolicy.swift
//  Core / Logic  [App + Widget 共用]
//
//  摘除判据的阈值集中地（ARCH §4.2）。
//  所有 EV 阈值在此一处固化，禁止散落在各调用点；设置页不暴露调参入口。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 摘除判据阈值（集中常量，可调）。
struct ExclusionPolicy: Sendable {

    /// 连续缺字段次数阈值（EV-1）：达到即摘除。
    var consecutiveMissingThreshold: Int = 3

    /// 限流冷却时长（EV-3，429）：秒；期内不再请求。
    var rateLimitCooldown: TimeInterval = 600

    /// 默认策略（3 次 / 600 秒）。
    static let `default` = ExclusionPolicy()
}

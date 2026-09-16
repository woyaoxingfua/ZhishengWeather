//
//  SourceState.swift
//  Core / Logic  [App + Widget 共用]
//
//  单个数据源的独立状态（失败隔离的可视化基础）。
//
//  背景（docs/handover/ARCH-zhisheng-ios-multi-source.md §3 失败隔离纪律）：
//  「一条链路失败，必须表现为**该链路**的失败，而其余链路的数据照常留在屏上」。
//  链路各自的槽位是 `nil`（整卡不渲染），但「整卡不渲染」等于**失败不可见**。
//  故每条副链路再持有一个 `SourceState`：
//    - 成功 → `.loaded`（正常渲染卡片）；
//    - 失败 → `.failed(文案)`（卡片位置显示该链路的降级提示，文案来自
//      `FaultDomain.message(for:)`，绝不触碰主链路 `state`）。
//
//  纪律：本枚举是**纯值**，不含网络 / IO / 时钟；判定与文案都由 Core 纯逻辑给定。
//

import Foundation

/// 单个数据源的状态。
enum SourceState: Equatable, Sendable {

    /// 尚未取数（或已因切城清空）——不提示（避免首屏就报错）。
    case idle
    /// 已成功取回并落槽。
    case loaded
    /// 取数失败；关联值为**已本地化**的故障文案。
    case failed(String)

    /// 失败文案；非失败态为 nil。
    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

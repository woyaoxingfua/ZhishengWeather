//
//  WidgetPayloadStatus.swift
//  Core / Logic  [App + Widget 共用]
//
//  Widget 载荷状态与解析 —— **纯函数**，可纯单测。
//
//  背景（本轮要求 6）：Widget **没有网络**。共享载荷缺失 / 损坏 / 过旧时，
//  它必须**如实说明**（"共享数据不可用" / "数据已过期"），而不是渲染空白
//  或编一个假值。
//
//  为什么放 Core：Widget target 不被测试 bundle 引入（测试宿主是主 App），
//  逻辑若写在 Widget target 里就**无法单测**（CI-pitfalls P-18 同源盲区）。
//  故把「载荷 + 状态」的判定下沉为 Core 纯函数，Widget 只做调用与渲染。
//

import Foundation

/// Widget 载荷的状态。
enum WidgetPayloadStatus: Equatable, Sendable {

    /// 有**归属匹配**且**新鲜**的数据 —— 正常渲染。
    case available
    /// 有归属匹配的数据，但已过旧 —— 照常渲染，但须标注「可能已过期」。
    case stale
    /// 从未写入（键缺失）或归属不匹配 —— 渲染「暂无数据」（沿用 AC-C6 语义）。
    case missing
    /// 共享容器不可用 / 载荷损坏 —— 必须如实说明「共享数据不可用」，不得静默留白。
    case unavailable
}

/// Widget 载荷解析结果。
struct WidgetPayloadResolution: Equatable, Sendable {

    /// 允许下发给 entry 的载荷；nil = 不下发（视图走空态 / 不可用态）。
    var payload: SharedWeatherPayload?
    /// 载荷状态（决定视图如何标注）。
    var status: WidgetPayloadStatus
}

/// Widget 载荷解析器（纯函数）。
enum WidgetPayloadResolver {

    /// 依据共享容器状态 + 归属校验，解析出「下发的载荷」与「状态」。
    ///
    /// 判定优先级（不可换序）：
    ///   1. 容器不可用 → `.unavailable`（连读取都不可信，绝不当成「暂无数据」）；
    ///   2. 键缺失 → `.missing`；
    ///   3. 键存在但解码失败（损坏）→ `.unavailable`；
    ///   4. 归属不匹配 → `payload = nil` + `.missing`（R-C2 / AC-C6：绝不冒充别城数据）；
    ///   5. 归属匹配但过旧 → 照发 payload + `.stale`（**仍展示数据**，只是标注）；
    ///   6. 归属匹配且新鲜 → `.available`。
    ///
    /// - Parameters:
    ///   - containerAvailable: `AppGroupStore.isSharedContainerAvailable` 的结果。
    ///   - loadResult: `AppGroupStore.loadResult()` 的结果。
    ///   - ownershipMatches: 该载荷是否归属本实例目标城市。
    ///   - now: 当前时刻（注入，由 entry 的 `date` 提供）。
    ///   - staleThreshold: 陈旧阈值（秒）；默认 `StalePolicy.defaultThreshold`。
    /// - Returns: 载荷 + 状态。
    static func resolve(containerAvailable: Bool,
                        loadResult: AppGroupStore.PayloadLoadResult,
                        ownershipMatches: Bool,
                        now: Date,
                        staleThreshold: TimeInterval = StalePolicy.defaultThreshold) -> WidgetPayloadResolution {
        guard containerAvailable else {
            return WidgetPayloadResolution(payload: nil, status: .unavailable)
        }

        switch loadResult {
        case .missing:
            return WidgetPayloadResolution(payload: nil, status: .missing)
        case .corrupt:
            return WidgetPayloadResolution(payload: nil, status: .unavailable)
        case .loaded(let payload):
            guard ownershipMatches else {
                return WidgetPayloadResolution(payload: nil, status: .missing)
            }
            if StalePolicy.isStale(lastUpdated: payload.updatedAt,
                                   now: now,
                                   threshold: staleThreshold) {
                return WidgetPayloadResolution(payload: payload, status: .stale)
            }
            return WidgetPayloadResolution(payload: payload, status: .available)
        }
    }
}

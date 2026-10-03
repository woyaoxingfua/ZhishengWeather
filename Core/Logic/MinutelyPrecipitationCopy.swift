//
//  MinutelyPrecipitationCopy.swift
//  Core / Logic  [App + Widget 共用]
//
//  短时降水卡的**顶部结论句**（纯函数，可 @testable 单测）——仿 `WidgetCopy.swift` 的
//  「文案单一真源」做法：句子收在 Core，视图只做取值与渲染。
//
//  为什么要单独成文件（而不是在 `MinutelyPrecipitationCard` 里拼字符串）：
//   1. `MinutelyPrecipitationEngine.Timing.start` 此前**没有任何 UI 消费者**（死代码）——
//      本文件是它的**第一个**消费者，且是**唯一**一处拼句子的地方。
//   2. 文案里最容易出错的是**措辞与口径**，而措辞无法靠截图证明。放进 Core 后
//      XCTest 可直接断言「什么时候必须说哪句话」，把规则钉成可执行的门禁。
//   3. 竞品（墨迹「大雨定点速报」/ Apple Weather Next-Hour / 彩云降水条）给的都是
//      **结论句**而非图表；本仓数据与判定早已就绪，缺的只是这一句。
//
//  ⚠️ **判定口径必须复用引擎**（本文件最重要的纪律）：
//  wet/dry 一律走 `MinutelyPrecipitationEngine.timing(_:)`，阈值沿用引擎的
//  `precipitationThreshold`。**禁止**在本文件里重新判一遍降水。若两处口径分叉，
//  会出现「引擎说正在下雨、文案说 20 分钟后开始」的自相矛盾——那比没有文案更糟。
//
//  ⚠️ **秒级精度是错的**：数据是 15 分钟粒度（见 `MinutelyPrecipitationPoint`），
//  写「约 23 分 47 秒后开始降水」是把插值结果冒充成雷达临近观测。故一律
//  **四舍五入到 5 的倍数**；差值不足 5 分钟时说不准分钟数，改说「即将开始降水」。
//
//  ⚠️ **窗口长度不硬编码**：`OpenMeteoEndpoint` 的 `forecast_minutely_15` 可配，
//  故窗口末端一律取 `points.last?.time`（序列实际跨度），不写死「2 小时」——
//  写死会在配置变更时**静默说错**。
//
//  ⚠️ **概率的诚实使用**：`probability` 是**可空**的。nil（服务端未返回 / 元素 null）
//  含义是「**未知**」，**不是 0%**，因此**不触发**降级（否则旧载荷会被无端弱化）。
//  有值且明显偏低时才降级——拿 30% 的概率说「即将下雨」是编造确定性，
//  违反本仓「不冒充」纪律。阈值与理由见 `lowProbabilityThreshold`。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 短时降水卡的结论句生成器（纯函数，无状态、无 IO、**时钟由参数注入**）。
enum MinutelyPrecipitationCopy {

    // MARK: - 阈值（全部具名，便于测试与复核）

    /// 「明显偏低」的降水概率阈值（%）。
    ///
    /// 低于 40% 就**不用肯定句**（改说「可能有降水，暂不确定」）。理由：
    /// - 40% 是「值得提醒、但不保证」的常用分界；说「即将开始降水」等于把
    ///   约 1/3 的兑现可能性讲成必然，正是本仓「不冒充」纪律所禁止的；
    /// - 反过来，**不**取更低（如 20%）：低于 20% 属于基本无望，句子本身的
    ///   信息量已很低，降级反而是噪声。40% 落在「有参考价值」与「不宜断言」之间。
    ///
    /// ⚠️ 该阈值只作用于**预报性**表述（即将 / N 分钟后开始）。
    /// `isRainingNow`（**正在**下雨）是**已发生**的事实陈述，不受它约束。
    static let lowProbabilityThreshold: Double = 40

    /// 「即将开始」的判定窗口（秒）：差值 < 该值 → 说不准分钟数。
    ///
    /// 取 5 分钟与数据粒度一致：不足一个 15 分钟窗时，报「约 5 分钟」会和
    /// 「约 10 分钟」一样是编造，故直接说「即将」。
    static let imminentWindow: TimeInterval = 300

    /// 分钟数的取整步长（分钟）。输出恒为该步长的整数倍。
    static let roundingStepMinutes: Int = 5

    // MARK: - 文案（单一真源，测试按字面量断言）

    /// 首点已有降水 —— 已在下，**不是**「预计将开始」。
    static let rainingNowText = "正在下雨"
    /// 差值不足一个 imminentWindow —— 不编造具体分钟数。
    static let imminentText = "即将开始降水"
    /// `start` 那一点概率明显偏低 —— 降级为不确定表述。
    static let lowProbabilityText = "可能有降水，暂不确定"

    // MARK: - 唯一对外入口

    /// 卡片顶部的结论句。
    ///
    /// - Parameters:
    ///   - points: 短时降水序列（实际窗口长度以序列跨度为准，不假设 2 小时）。
    ///   - now: 当前时刻（**由调用方注入**；Core 内不取时钟）。
    /// - Returns: 结论句；**nil = 此刻没有可说的结论** → 调用方**整行隐藏**
    ///   （不留空白、不画「无」，沿用既有「没下就不显示」纪律）。
    static func headline(points: [MinutelyPrecipitationPoint]?,
                         now: Date) -> String? {
        guard let points, !points.isEmpty else { return nil }
        // 判定完全交给引擎（不重新判 wet/dry，见文件头口径纪律）。
        guard let timing = MinutelyPrecipitationEngine.timing(points) else { return nil }
        // 窗口末端取序列实际末点（不硬编码 2 小时）。
        let windowEnd = points.last?.time
        // start 那一点（仅此一点）的概率；nil = 未知 → 不降级。
        let probability = timing.start.flatMap { start in
            points.first(where: { $0.time == start })?.probability
        }
        return compose(isRainingNow: timing.isRainingNow,
                       start: timing.start,
                       windowEnd: windowEnd,
                       probability: probability,
                       now: now)
    }

    // MARK: - 规则表（拆出可单测的纯拼装层）

    /// 按规则表拼装结论句。**规则逐条对应下表**（改文案时逐行复核）：
    ///
    /// | 情况 | 输出 |
    /// |---|---|
    /// | `isRainingNow == true` | 「正在下雨」（不受概率阈值影响：已在下） |
    /// | `start == nil`（不该发生，兜底） | nil |
    /// | `start` 晚于 `windowEnd`（落在窗口外） | nil（不编造窗口外的时间） |
    /// | `start` 早于 `now`（时钟漂移 / 序列已过期） | nil（见下方说明） |
    /// | `probability` 有值且 < 40% | 「可能有降水，暂不确定」 |
    /// | 差值 < 5 分钟 | 「即将开始降水」 |
    /// | 其余 | 「约 N 分钟后开始降水」，N 为 5 的倍数 |
    ///
    /// ⚠️ **`start` 早于 `now` 为什么返回 nil**（不是「即将开始降水」）：
    /// 引擎判「正在下雨」的唯一依据是**首点已有降水**（`isRainingNow`）。若此刻
    /// `start` 却已经过去，说明这段序列相对当前时钟**已过期/不自洽**（如卡片被长时间
    /// 缓存后渲染）。此时说「即将开始降水」是在拿过期数据下断言，说「正在下雨」则与
    /// 引擎判定**直接矛盾**。返回 nil（不显示结论句）是唯一不撒谎的选择。
    ///
    /// - Parameters:
    ///   - isRainingNow: 引擎判定的「首点已有降水」。
    ///   - start: 降水开始时刻；正在下时为 nil。
    ///   - windowEnd: 序列末点时刻（窗口外判据）；nil = 未知窗口 → 不做窗口外拦截。
    ///   - probability: `start` 那一点的概率；nil = 未知（**不等于 0%**）→ 不降级。
    ///   - now: 当前时刻。
    /// - Returns: 结论句；无可说之结论 → nil。
    static func compose(isRainingNow: Bool,
                        start: Date?,
                        windowEnd: Date?,
                        probability: Double?,
                        now: Date) -> String? {
        // 1) 已在下：事实陈述，不受预报性阈值约束。
        if isRainingNow { return rainingNowText }
        guard let start else { return nil }

        // 2) 落在窗口外 → 不编造。
        if let windowEnd, start > windowEnd { return nil }

        // 3) 差值为负（时钟漂移 / 序列过期）→ 不说（详见上方说明）。
        let delta = start.timeIntervalSince(now)
        if delta < 0 { return nil }

        // 4) 概率明显偏低 → 降级为不确定表述（**先于**分钟数分支：不足 5 分钟时
        //    「即将开始降水」同样是肯定句，必须一并降级）。
        if let probability, probability < lowProbabilityThreshold {
            return lowProbabilityText
        }

        // 5) 不足 5 分钟 → 说不准分钟数。
        if delta < imminentWindow { return imminentText }

        // 6) 其余 → 约 N 分钟后开始降水（N 恒为 5 的倍数，故此处 N ≥ 5，绝不会是 0）。
        return "约 \(roundedMinutes(delta)) 分钟后开始降水"
    }

    // MARK: - 取整

    /// 把秒差取整到「5 的倍数」分钟（`.rounded()` = 四舍五入，2.5 → 3）。
    /// - Parameter interval: 距开始的秒差（调用方保证 ≥ 0）。
    /// - Returns: 分钟数（`roundingStepMinutes` 的整数倍）。
    static func roundedMinutes(_ interval: TimeInterval) -> Int {
        let rawMinutes = interval / 60
        let steps = (rawMinutes / Double(roundingStepMinutes)).rounded()
        return Int(steps) * roundingStepMinutes
    }
}

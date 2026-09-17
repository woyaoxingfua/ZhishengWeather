//
//  UmbrellaReminderEngine.swift
//  Core / Logic  [App + Widget 共用]
//
//  雨伞提醒决策引擎（产品转向「决策优先」：从"显示数据"到"告诉你该做什么"）。
//
//  裁定（本轮冻结范围）：
//  - 触发条件**只有一条**：未来 2 小时窗口内出现「干 → 湿」的降水**起始**，
//    且**当前未在下雨**。正在下雨**绝不重复触发**（"持续下雨"状态不得骚扰）。
//  - 文案纪律（AC-B1-7 同一口径，事实更正·已实测验证）：**禁止**任何
//    "分钟级 / 逐分钟 / 雷达临近 / nowcast"措辞；标注必须声明
//    「由逐小时插值」（非原生覆盖区的 minutely_15 为逐小时插值到 15 分钟网格，
//    非实况外推）。与 MinutelyPrecipitationCard 的诚实标注完全一致。
//  - 降水判定**复用** MinutelyPrecipitationEngine.precipitationThreshold，
//    本文件绝不复制第二套阈值/规则（单一真源）。
//  - 时钟注入：Core 禁内部 Date()，`now` 由调用方传入，全分支纯函数可单测。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 雨伞提醒决策引擎（纯函数，无状态）。
enum UmbrellaReminderEngine {

    /// 触发前瞻窗口（秒）：仅当降水窗口在本窗口内**起始**才提醒。
    static let lookAheadInterval: TimeInterval = 2 * 60 * 60

    // MARK: - 决策结果

    /// 提醒决策（纯派生结果，不含任何系统调用）。
    struct Decision: Equatable, Sendable {

        /// 是否应触发提醒。
        var shouldFire: Bool

        /// 通知标题（shouldFire == false 时无意义）。
        var title: String

        /// 通知正文（含起始时刻与插值标注；shouldFire == false 时无意义）。
        /// 时刻为 "HH:mm" 文本（起始时刻按城市/设备时区由调用方预格式化注入——
        /// 本引擎只接收已格式化文本，保持与 Core 禁 DateFormatter 共享状态一致）。
        var body: String

        /// 降水的起始时刻（窗起始，15 分钟粒度的诚实近似）。
        /// shouldFire == false 时为 nil。
        var onset: Date?

        /// 用于替换判定与测试的规范化载荷（标题+正文）。
        static let none = Decision(shouldFire: false, title: "", body: "", onset: nil)
    }

    // MARK: - 决策入口

    /// 依短时降水序列决定是否触发雨伞提醒。
    ///
    /// 规则（全部可单测）：
    ///   1. `minutely15` 为 nil / 空 / 全干（无任何超阈值点）→ 不触发（无雨无提醒）；
    ///   2. 序列**首点已在下雨** → 不触发（正在下的雨不是"起始"，重复提醒即骚扰）；
    ///   3. 首个超阈值点的窗起始超出前瞻窗口（> 2 小时）→ 不触发；
    ///      （序列本身即 ≤ 8 点 2 小时，此条防御 mapper 未来放宽截窗）
    ///   4. 否则触发：文案含起始 "HH:mm" 与「由逐小时插值」标注。
    ///
    /// - Parameters:
    ///   - minutely15: 快照的 15 分钟粒度短时降水序列（可 nil，等价无数据不提醒）。
    ///   - now: 当前时刻（注入；Core 禁内部 Date()）。
    ///   - timeText: 时刻 → "HH:mm" 文本的格式化闭包（由调用方按城市时区提供，
    ///     与 MinutelyPrecipitationCard 同走 WeatherTimeFormatter，不新建第二套格式器）。
    /// - Returns: 提醒决策；不该提醒时返回 `.none`。
    static func decide(minutely15: [MinutelyPrecipitationPoint]?,
                       now: Date,
                       timeText: (Date) -> String) -> Decision {
        // 规则 1：无数据 / 全干 → 不提醒（复用既有干窗判定，不复制阈值）。
        guard let minutely15, !minutely15.isEmpty,
              MinutelyPrecipitationEngine.hasPrecipitation(minutely15) else {
            return .none
        }

        // 规则 2：首点已在下雨 → 不提醒（避免"雨持续"状态反复骚扰）。
        // 时序口径与 MinutelyPrecipitationEngine.timing 一致：isRainingNow = 首点湿。
        if let timing = MinutelyPrecipitationEngine.timing(minutely15), timing.isRainingNow {
            return .none
        }

        // 找首个超阈值点（dry → wet 的起始窗）。
        guard let onsetIndex = minutely15.firstIndex(where: {
            $0.precipitation > MinutelyPrecipitationEngine.precipitationThreshold
        }) else {
            return .none
        }
        let onset = minutely15[onsetIndex].time

        // 规则 3：起始点必须落在前瞻窗口内（防御性；当前截窗本就 ≤ 2 小时）。
        guard onset >= now, onset.timeIntervalSince(now) <= lookAheadInterval else {
            return .none
        }

        // 规则 4：触发。文案对齐 WeatherSummaryEngine「出门带伞」语气 + 插值诚实标注。
        return Decision(
            shouldFire: true,
            title: "带伞提醒",
            body: "约 \(timeText(onset)) 开始下雨，出门带伞（未来 2 小时 · 由逐小时插值，非实况外推）",
            onset: onset
        )
    }
}

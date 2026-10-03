//
//  MinutelyPrecipitationCopyTests.swift
//  ZhishengWeatherTests
//
//  短时降水卡**顶部结论句**（`MinutelyPrecipitationCopy`）的纯单测（不联网、不渲染）。
//
//  这批用例的存在理由：`Timing.start` 此前**没有任何 UI 消费者**，其"何时开始下"的
//  结论从未被断言过；而本仓纪律要求**句子的产出条件可执行地钉住**，不能靠截图。
//  故此处把「什么情况必须说哪句话」逐条写成断言。
//
//  覆盖清单（与 `MinutelyPrecipitationCopy.compose` 的规则表一一对应）：
//   ①  nil / 空 / 全干          → nil（没下就不显示）
//   ②  首点 wet（正在下雨）     → "正在下雨"
//   ③  稍后转湿                 → "约 N 分钟后开始降水"，N 为 5 的倍数
//   ④  差值 < 5 分钟            → "即将开始降水"
//   ⑤  差值为负（时钟漂移）     → nil（本仓处理：序列已过期，不说）
//   ⑥  start 落在窗口外         → nil（不编造窗口外的时间）
//   ⑦  probability 极低         → "可能有降水，暂不确定"（降级）
//   ⑧  probability 为 nil       → **不降级**（nil = 未知，不是 0%）
//   ⑨  正在下雨时低概率         → 仍为 "正在下雨"（事实陈述不受预报阈值约束）
//   ⑩  取整纯函数              → roundedMinutes 逐点钉死
//

import XCTest
@testable import ZhishengWeather

final class MinutelyPrecipitationCopyTests: XCTestCase {

    /// 序列基准时刻（固定值 → 用例不依赖真实时钟，可重复）。
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// 构造等间隔 15 分钟序列（基准时刻 + index×900s）。
    ///
    /// - Parameters:
    ///   - values: 各点降水量（mm / 15min）。
    ///   - probabilities: 各点概率（%）；**默认空 = 全 nil**（服务端未返回的情形）。
    ///     数组中的 `nil` 项表示"该点未知"，与"该点 0%"严格区分。
    private func points(_ values: [Double],
                        probabilities: [Double?] = []) -> [MinutelyPrecipitationPoint] {
        values.enumerated().map { index, value in
            // 越界安全取概率：缺失即 nil（= 服务端未返回），不是 0%。
            var probability: Double?
            if probabilities.indices.contains(index) {
                probability = probabilities[index]
            }
            return MinutelyPrecipitationPoint(time: base.addingTimeInterval(Double(index) * 900),
                                              precipitation: value,
                                              probability: probability)
        }
    }

    // MARK: - ① nil / 空 / 全干 → nil

    func testHeadlineNilWhenNoUsablePoints() {
        XCTAssertNil(MinutelyPrecipitationCopy.headline(points: nil, now: base))
        XCTAssertNil(MinutelyPrecipitationCopy.headline(points: [], now: base))
        XCTAssertNil(MinutelyPrecipitationCopy.headline(points: points([0, 0, 0]), now: base),
                     "全干 → 沿用既有『没下就不显示』纪律，返回 nil")
        XCTAssertNil(MinutelyPrecipitationCopy.headline(points: points([0, 0.01]), now: base),
                     "等于阈值不算降水（口径须与引擎 precipitationThreshold 一致）")
    }

    // MARK: - ② 正在下雨

    func testHeadlineSaysRainingNowWhenFirstPointWet() throws {
        let text = try XCTUnwrap(
            MinutelyPrecipitationCopy.headline(points: points([0.5, 0.4, 0.0]), now: base))
        XCTAssertEqual(text, "正在下雨")
        XCTAssertNotEqual(text, "约 0 分钟后开始降水",
                          "已在下时**绝不能**说成『即将开始』（语义相反）")
    }

    /// 正在下雨时**不显示分钟数**：结论句与页脚的时刻文案分工不同（页脚给 HH:mm）。
    func testHeadlineRainingNowOmitsMinuteCountdown() throws {
        let list = points([0.5, 0.4, 0.0])
        let text = try XCTUnwrap(MinutelyPrecipitationCopy.headline(points: list, now: base))
        XCTAssertFalse(text.contains("分钟"), "正在下雨不应带倒计时：\(text)")
    }

    // MARK: - ③ 稍后转湿 → 约 N 分钟后开始降水

    func testHeadlineSaysAboutNMinutesWhenStartsLater() throws {
        // start = index 4 → +3600s = 60 分钟后。
        let list = points([0, 0, 0, 0, 0.8, 0.3])
        let text = try XCTUnwrap(MinutelyPrecipitationCopy.headline(points: list, now: base))
        XCTAssertEqual(text, "约 60 分钟后开始降水")
    }

    /// N 必须被四舍五入到 5 的倍数，且**绝不出秒级**。
    func testHeadlineRoundsMinutesToMultipleOfFive() {
        // start = index 4 = base+3600s；now 推到 +2173s → 差值 1427s = 23 分 47 秒。
        let list = points([0, 0, 0, 0, 0.8])
        let text = MinutelyPrecipitationCopy.headline(points: list,
                                                      now: base.addingTimeInterval(2173))
        XCTAssertEqual(text, "约 25 分钟后开始降水",
                       "23 分 47 秒必须被说成 25 分钟，绝不出现秒级（数据是 15 分钟粒度）")
    }

    /// 逐个取整边界（2.5 分 → 5 分；7.5 分 → 10 分）都由 `roundedMinutes` 钉死。
    func testRoundedMinutesSnapsToFiveMinuteGrid() {
        typealias C = MinutelyPrecipitationCopy
        // 不足 2.5 分 → 0 分（但该档由 imminentWindow 分支拦下，不会出现在文案里）。
        XCTAssertEqual(C.roundedMinutes(0), 0)
        XCTAssertEqual(C.roundedMinutes(149), 0)
        // 2.5 分 → 5 分；7.5 分 → 10 分。
        XCTAssertEqual(C.roundedMinutes(150), 5)
        XCTAssertEqual(C.roundedMinutes(450), 10)
        // 常规档位。
        XCTAssertEqual(C.roundedMinutes(600), 10)
        XCTAssertEqual(C.roundedMinutes(900), 15)
        XCTAssertEqual(C.roundedMinutes(3600), 60)
        XCTAssertEqual(C.roundedMinutes(7200), 120)
    }

    // MARK: - ④ 差值 < 5 分钟 → 即将开始降水

    func testHeadlineSaysImminentWhenUnderFiveMinutes() throws {
        // start = index 1 = +900s；now 推到 +601s → 差值 299s < 300s。
        let list = points([0, 0.8, 0.4])
        let text = try XCTUnwrap(
            MinutelyPrecipitationCopy.headline(points: list, now: base.addingTimeInterval(601)))
        XCTAssertEqual(text, "即将开始降水")
        XCTAssertNotEqual(text, "约 0 分钟后开始降水", "不足 5 分钟不得报 0 分钟")
    }

    /// 恰好 5 分钟（300s）**不**算"即将"：5 分钟是数据粒度的一半，说得出来。
    func testHeadlineAtExactlyFiveMinutesGivesMinutes() throws {
        let list = points([0, 0.8, 0.4])
        let text = try XCTUnwrap(
            MinutelyPrecipitationCopy.headline(points: list, now: base.addingTimeInterval(600)))
        XCTAssertEqual(text, "约 5 分钟后开始降水",
                       "差值恰为 5 分钟 → 走分钟分支（判据是 delta < 300 严格小于）")
    }

    // MARK: - ⑤ 差值为负（时钟漂移 / 序列已过期）→ nil

    /// 本仓的处理：`start` 早于 `now` → **返回 nil（不显示结论句）**。
    ///
    /// 理由（钉在用例里，避免以后被"好心"改成"即将开始降水"）：
    /// 引擎判"正在下雨"的唯一依据是**首点已有降水**。若 `start` 已过去，说明这段
    /// 序列相对当前时钟已过期；此时说"即将开始"是拿过期数据下断言，
    /// 说"正在下雨"则与引擎判定直接矛盾 → 唯一不撒谎的选择是不说。
    func testHeadlineNilWhenStartIsInThePast() {
        // start = index 1 = +900s；now 推到 +1800s → 差值 -900s。
        let list = points([0, 0.8, 0.4])
        XCTAssertNil(MinutelyPrecipitationCopy.headline(points: list,
                                                        now: base.addingTimeInterval(1800)),
                     "start 早于 now（时钟漂移/序列过期）→ 不说，绝不输出负数或『约 -15 分钟』")
    }

    /// 负差值**恰好为零**（start == now）走"即将"分支，不被负值分支吞掉。
    func testHeadlineAtExactNowIsImminent() throws {
        let list = points([0, 0.8, 0.4])
        let text = try XCTUnwrap(MinutelyPrecipitationCopy.headline(points: list, now: base.addingTimeInterval(900)))
        XCTAssertEqual(text, "即将开始降水")
    }

    // MARK: - ⑥ start 落在窗口外 → nil

    func testHeadlineNilWhenStartBeyondWindowEnd() {
        // windowEnd = +900s（序列末点）；start = +1800s → 落在窗口外。
        let text = MinutelyPrecipitationCopy.compose(isRainingNow: false,
                                                     start: base.addingTimeInterval(1800),
                                                     windowEnd: base.addingTimeInterval(900),
                                                     probability: nil,
                                                     now: base)
        XCTAssertNil(text, "start 晚于序列末点 → 不编造窗口外的时间")
    }

    /// 反面对照：start 恰在窗口末端（== windowEnd）**合法**，不得被窗口判定误杀。
    func testHeadlineAcceptsStartExactlyAtWindowEnd() {
        let text = MinutelyPrecipitationCopy.compose(isRainingNow: false,
                                                     start: base.addingTimeInterval(900),
                                                     windowEnd: base.addingTimeInterval(900),
                                                     probability: nil,
                                                     now: base)
        XCTAssertEqual(text, "约 15 分钟后开始降水",
                       "start == windowEnd 属窗口内（判据是严格大于才拦截）")
    }

    /// `windowEnd == nil`（窗口未知）→ 不做窗口外拦截，按差值正常出句。
    func testHeadlineWithoutWindowEndStillSpeaks() {
        let text = MinutelyPrecipitationCopy.compose(isRainingNow: false,
                                                     start: base.addingTimeInterval(1800),
                                                     windowEnd: nil,
                                                     probability: nil,
                                                     now: base)
        XCTAssertEqual(text, "约 30 分钟后开始降水")
    }

    // MARK: - ⑦ probability 极低 → 降级

    func testHeadlineDowngradesWhenProbabilityLow() {
        // start 那一点概率 30% < 40% → 不许说"即将下雨"。
        let list = points([0, 0.8, 0.4], probabilities: [nil, 30, 80])
        let text = MinutelyPrecipitationCopy.headline(points: list, now: base)
        XCTAssertEqual(text, "可能有降水，暂不确定",
                       "30% 的概率说『即将开始降水』是编造确定性")
    }

    /// 降级**优先于**分钟数分支：不足 5 分钟时的"即将开始降水"同样是肯定句。
    func testHeadlineLowProbabilityDowngradesEvenWhenImminent() {
        let list = points([0, 0.8, 0.4], probabilities: [nil, 12, 80])
        let text = MinutelyPrecipitationCopy.headline(points: list,
                                                      now: base.addingTimeInterval(601))
        XCTAssertEqual(text, "可能有降水，暂不确定",
                       "概率低时『即将开始降水』也是肯定句，必须一并降级")
    }

    /// 阈值边界：恰好 40% **不降级**（判据是严格小于）。
    func testHeadlineKeepsCertainWordingAtThreshold() {
        let list = points([0, 0.8, 0.4], probabilities: [nil, 40, 80])
        XCTAssertEqual(MinutelyPrecipitationCopy.headline(points: list, now: base),
                       "约 15 分钟后开始降水",
                       "40% 是阈值本身，按『明显偏低』的既定判据不降级")
    }

    /// 高概率 → 正常出句。
    func testHeadlineKeepsCertainWordingWhenProbabilityHigh() {
        let list = points([0, 0.8, 0.4], probabilities: [nil, 85, 90])
        XCTAssertEqual(MinutelyPrecipitationCopy.headline(points: list, now: base),
                       "约 15 分钟后开始降水")
    }

    // MARK: - ⑧ probability 为 nil → 不降级

    /// nil = 服务端未返回 / 元素 null → **不降级**（nil 是"未知"，不是 0%）。
    func testHeadlineDoesNotDowngradeWhenProbabilityNil() {
        let list = points([0, 0.8, 0.4], probabilities: [nil, nil, nil])
        XCTAssertEqual(MinutelyPrecipitationCopy.headline(points: list, now: base),
                       "约 15 分钟后开始降水",
                       "概率未知不得被当成低概率（否则旧载荷会被无端弱化）")
    }

    /// 只看 **start 那一点**的概率：别的点再低也不影响结论句。
    func testHeadlineOnlyConsidersProbabilityAtStartPoint() {
        let list = points([0, 0.8, 0.4], probabilities: [nil, 80, 5])
        XCTAssertEqual(MinutelyPrecipitationCopy.headline(points: list, now: base),
                       "约 15 分钟后开始降水",
                       "降级判据只看 start 那一点；后续点概率低不改变『何时开始』")
    }

    // MARK: - ⑨ 正在下雨时低概率 → 仍为事实陈述

    func testHeadlineRainingNowIgnoresLowProbability() {
        let list = points([0.5, 0.4, 0.0], probabilities: [5, 5, 5])
        XCTAssertEqual(MinutelyPrecipitationCopy.headline(points: list, now: base),
                       "正在下雨",
                       "已在下是**已发生**的事实，不该被预报概率阈值降级成『可能有降水』")
    }

    // MARK: - ⑩ 兜底与不变式

    /// `isRainingNow == true` 时 `start` 必为 nil；即使传入 start 也不应被采用
    /// （引擎的不变式：`isRainingNow` 优先）。
    func testComposeRainingNowWinsOverStart() {
        let text = MinutelyPrecipitationCopy.compose(isRainingNow: true,
                                                     start: base.addingTimeInterval(3600),
                                                     windowEnd: base.addingTimeInterval(3600),
                                                     probability: 90,
                                                     now: base)
        XCTAssertEqual(text, "正在下雨")
    }

    /// `isRainingNow == false` 且 `start == nil` → 兜底 nil（不该发生，但必须有确定行为）。
    func testComposeNilWhenNoStartAndNotRainingNow() {
        XCTAssertNil(MinutelyPrecipitationCopy.compose(isRainingNow: false,
                                                       start: nil,
                                                       windowEnd: base,
                                                       probability: nil,
                                                       now: base))
    }

    /// 阈值常量被钉住，避免以后有人悄悄改数值导致文案行为漂移。
    func testThresholdsArePinned() {
        XCTAssertEqual(MinutelyPrecipitationCopy.lowProbabilityThreshold, 40)
        XCTAssertEqual(MinutelyPrecipitationCopy.imminentWindow, 300)
        XCTAssertEqual(MinutelyPrecipitationCopy.roundingStepMinutes, 5)
    }

    /// 窗口长度以 `points` 实际跨度为准（**不硬编码 2 小时**）：
    /// 一个 4 小时跨度（16 点）的序列，start 在 +3 小时处 → 照旧报分钟数。
    func testHeadlineUsesActualSequenceSpanNotHardcodedTwoHours() {
        let values = [Double](repeating: 0, count: 13) + [0.8] + [Double](repeating: 0.2, count: 2)
        let list = points(values)
        let text = MinutelyPrecipitationCopy.headline(points: list, now: base)
        XCTAssertEqual(text, "约 195 分钟后开始降水",
                       "start 在 +195 分钟（13×15min）处，须如实报出，不得被『2 小时窗口』截断")
    }
}

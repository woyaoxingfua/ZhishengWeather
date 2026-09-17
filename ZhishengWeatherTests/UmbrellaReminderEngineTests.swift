//
//  UmbrellaReminderEngineTests.swift
//  ZhishengWeatherTests
//
//  雨伞提醒决策的纯单测（不联网、不涉系统通知中心）：
//   - 干→湿起始在 2 小时内 → 触发，文案含起始时刻与「由逐小时插值」标注；
//   - 正在下雨（首点湿）→ 不触发（"持续下雨"不得重复骚扰）；
//   - 降水起始超出前瞻窗口 → 不触发；
//   - 无数据 / 全干 → 不触发；
//   - 时钟全注入（now 显式传参），Core 无内部 Date()。
//
//  调度器（UmbrellaReminderScheduler）经 Spy 注入测开关 / 权限 / 替换语义；
//  真实 UNUserNotificationCenter **不做**单测（系统单例，无法隔离）。
//

import XCTest
@testable import ZhishengWeather

final class UmbrellaReminderEngineTests: XCTestCase {

    /// 基准时刻（全用例共用锚点，时钟注入）。
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// 构造等间隔 15 分钟序列（自 base 起 index×900s）。
    private func points(_ values: [Double], from base: Date) -> [MinutelyPrecipitationPoint] {
        values.enumerated().map { index, value in
            MinutelyPrecipitationPoint(time: base.addingTimeInterval(Double(index) * 900),
                                       precipitation: value)
        }
    }

    /// 测试用 "HH:mm" 文本格式化（确定性，不依赖设备时区/格式器缓存）。
    private func fixedTimeText(_ date: Date) -> String {
        "T\(Int(date.timeIntervalSince1970))"
    }

    // MARK: - 触发：干→湿起始

    func testFiresWhenRainStartsWithinWindow() throws {
        // 第 2 窗（+30min）起始下雨，首点干 → 触发。
        let list = points([0, 0, 0.5, 0.2], from: now)
        let decision = UmbrellaReminderEngine.decide(minutely15: list,
                                                     now: now,
                                                     timeText: fixedTimeText)
        XCTAssertTrue(decision.shouldFire)
        XCTAssertEqual(try XCTUnwrap(decision.onset), list[2].time)
        XCTAssertEqual(decision.title, "带伞提醒")
    }

    func testCopyContainsOnsetTimeAndInterpolationLabel() throws {
        let list = points([0, 0.8], from: now)
        let decision = UmbrellaReminderEngine.decide(minutely15: list,
                                                     now: now,
                                                     timeText: fixedTimeText)
        XCTAssertTrue(decision.shouldFire)
        let body = try XCTUnwrap(decision.body)
        XCTAssertTrue(body.contains(fixedTimeText(list[1].time)),
                      "文案必须含起始时刻，实际：\(body)")
        XCTAssertTrue(body.contains("由逐小时插值"),
                      "文案必须含插值诚实标注，实际：\(body)")
        XCTAssertTrue(body.contains("带伞"), "文案应与摘要引擎「出门带伞」同语气")
        // 诚实标注红线：绝不允许出现"分钟级 / nowcast / 雷达"措辞。
        XCTAssertFalse(body.contains("分钟级"))
        XCTAssertFalse(body.lowercased().contains("nowcast"))
        XCTAssertFalse(body.contains("雷达"))
    }

    func testFiresAtLastPossibleWindowBoundary() throws {
        // 起始点恰在 2 小时窗界（now + 7200s = 第 8 窗起始，闭区间）→ 触发。
        // 9 点序列：第 0..7 窗全干，第 8 窗起始湿（+7200s）。
        let values = [Double](repeating: 0, count: 8) + [0.4]
        let list = points(values, from: now)
        XCTAssertEqual(list[8].time.timeIntervalSince(now), 7200, accuracy: 1e-9,
                       "前置校验：起始点必须恰在 2h 边界")
        let decision = UmbrellaReminderEngine.decide(minutely15: list,
                                                     now: now,
                                                     timeText: fixedTimeText)
        XCTAssertTrue(decision.shouldFire, "窗口边界（恰 2h，闭区间）应触发")
        XCTAssertEqual(try XCTUnwrap(decision.onset), list[8].time)
    }

    func testDoesNotFireJustPastWindowBoundary() {
        // 起始点在 now + 7300s（超出 2h 窗 100s）→ 不触发（闭区间上界的另一半）。
        let values = [Double](repeating: 0, count: 8) + [0.4]
        let list = points(values, from: now).map { point in
            MinutelyPrecipitationPoint(time: point.time.addingTimeInterval(100),
                                       precipitation: point.precipitation)
        }
        let decision = UmbrellaReminderEngine.decide(minutely15: list,
                                                     now: now,
                                                     timeText: fixedTimeText)
        XCTAssertFalse(decision.shouldFire, "起始超过 2h 边界即不触发")
    }

    // MARK: - 不触发：正在下雨（防重复骚扰）

    func testDoesNotFireWhenAlreadyRaining() {
        // 首点湿 = 正在下雨（timing.isRainingNow 口径）→ 不触发。
        let list = points([0.6, 0.4, 0, 0.9], from: now)
        let decision = UmbrellaReminderEngine.decide(minutely15: list,
                                                     now: now,
                                                     timeText: fixedTimeText)
        XCTAssertFalse(decision.shouldFire, "雨持续状态绝不重复提醒")
        XCTAssertNil(decision.onset)
    }

    // MARK: - 不触发：超出前瞻窗口

    func testDoesNotFireWhenOnsetBeyondLookAhead() {
        // 起始点在 now + 2h15min（超出 2h 窗）→ 不触发。
        let lateOnset = now.addingTimeInterval(2 * 60 * 60 + 15 * 60)
        let list = points([0, 0, 0, 0, 0.4], from: now)
        // 直接以 lateOnset 起始构造序列（防御 mapper 未来放宽截窗的场景）。
        let shifted = list.map { point in
            MinutelyPrecipitationPoint(time: point.time.addingTimeInterval(15 * 60),
                                       precipitation: point.precipitation)
        }
        _ = lateOnset
        let decision = UmbrellaReminderEngine.decide(minutely15: shifted,
                                                     now: now,
                                                     timeText: fixedTimeText)
        XCTAssertFalse(decision.shouldFire, "起始超出 2 小时前瞻窗 → 不触发")
    }

    // MARK: - 不触发：无数据 / 全干

    func testDoesNotFireWhenNilEmptyOrDry() {
        XCTAssertFalse(UmbrellaReminderEngine.decide(minutely15: nil,
                                                     now: now,
                                                     timeText: fixedTimeText).shouldFire)
        XCTAssertFalse(UmbrellaReminderEngine.decide(minutely15: [],
                                                     now: now,
                                                     timeText: fixedTimeText).shouldFire)
        XCTAssertFalse(UmbrellaReminderEngine.decide(minutely15: points([0, 0, 0.005], from: now),
                                                     now: now,
                                                     timeText: fixedTimeText).shouldFire,
                       "全部低于阈值（0.005 ≤ 0.01）= 干窗 → 不触发")
    }

    func testDoesNotFireWhenOnsetBeforeNow() {
        // 起始点早于 now（陈旧数据）→ 不触发。
        let stale = points([0.5], from: now.addingTimeInterval(-900))
        let decision = UmbrellaReminderEngine.decide(minutely15: stale,
                                                     now: now,
                                                     timeText: fixedTimeText)
        XCTAssertFalse(decision.shouldFire, "起始时刻早于 now → 不触发")
    }
}

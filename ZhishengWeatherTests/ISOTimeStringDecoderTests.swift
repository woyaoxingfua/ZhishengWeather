//
//  ISOTimeStringDecoderTests.swift
//  ZhishengWeatherTests
//
//  ISO 本地墙钟字符串独立解码器的边界用例（ARCH-A1 §5 测试设计，不联网）：
//   - 正常解析（HH:mm 形态）
//   - offset 正 / 负两向正确
//   - 无 T 分隔 / 非数字 / 空串 → nil
//   - 跨日墙钟 + 大 offset
//   - 秒段宽容、非法日期（13 月）→ nil
//
//  ⚠️ 本解码器与 epoch 解码路径完全隔离（PRD R3 / ARCH-A1 §1.4 铁律 1）；
//  本文件只测字符串路径，不触碰 `Date(timeIntervalSince1970:)` 以外的
//  epoch 字段语义。
//

import XCTest
@testable import ZhishengWeather

final class ISOTimeStringDecoderTests: XCTestCase {

    // MARK: - 正常解析

    /// 正常值：北京时间（+8h）05:53 日出 → 当日 UTC 前夜 21:53。
    func testDateWhenNormalBeijingSunriseString() throws {
        let date = try XCTUnwrap(ISOTimeStringDecoder.date(
            from: "2026-09-11T05:53", utcOffsetSeconds: 28_800))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 28_800)!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 9)
        XCTAssertEqual(components.day, 11)
        XCTAssertEqual(components.hour, 5)
        XCTAssertEqual(components.minute, 53)
    }

    /// offset 正向：墙钟 +8h 与 epoch 的关系（用 epoch 侧校验绝对时刻）。
    func testDateWhenPositiveOffsetMatchesEpoch() throws {
        // 2026-09-11 00:00 (+08:00) = 2026-09-10 16:00 UTC = epoch 1_789_056_000。
        // （CI run12 勘误：注释原写 1_786_396_800 是 2026-08-10，算错了 31 天；
        //   实现输出 1_789_056_000 经独立 Python 时区复算验证为正确值。）
        let date = try XCTUnwrap(ISOTimeStringDecoder.date(
            from: "2026-09-11T00:00", utcOffsetSeconds: 28_800))
        XCTAssertEqual(date.timeIntervalSince1970, 1_789_056_000, accuracy: 1.0)
    }

    /// offset 负向：纽约（-5h）墙钟 → UTC = 墙钟 + 5h。
    func testDateWhenNegativeOffsetMatchesEpoch() throws {
        // 2026-09-11 00:00 (-05:00) = 2026-09-11 05:00 UTC = epoch 1_789_102_800。
        // （CI run12 勘误：注释原写 1_786_458_000 同源算错；正确值 1_789_102_800。）
        let date = try XCTUnwrap(ISOTimeStringDecoder.date(
            from: "2026-09-11T00:00", utcOffsetSeconds: -18_000))
        XCTAssertEqual(date.timeIntervalSince1970, 1_789_102_800, accuracy: 1.0)
    }

    /// 跨日墙钟 + 大 offset：+14h（基里蒂马蒂）23:50 → UTC 仍是同一天 09:50。
    func testDateWhenLateNightWithLargePositiveOffset() throws {
        let date = try XCTUnwrap(ISOTimeStringDecoder.date(
            from: "2026-09-11T23:50", utcOffsetSeconds: 50_400))
        // 2026-09-11 23:50 +14:00 = 2026-09-11 09:50 UTC。
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.day, .hour, .minute], from: date)
        XCTAssertEqual(components.day, 11)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 50)
    }

    /// 秒段宽容："T05:53:30" 亦解析成功且秒值正确。
    func testDateWhenSecondsSegmentPresent() throws {
        let date = try XCTUnwrap(ISOTimeStringDecoder.date(
            from: "2026-09-11T05:53:30", utcOffsetSeconds: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        XCTAssertEqual(components.hour, 5)
        XCTAssertEqual(components.minute, 53)
        XCTAssertEqual(components.second, 30)
    }

    // MARK: - 失败路径（一律 nil，不抛错不崩）

    /// 无 T 分隔的纯日期串 → nil。
    func testNilWhenSeparatorMissing() {
        XCTAssertNil(ISOTimeStringDecoder.date(from: "2026-09-11", utcOffsetSeconds: 0))
    }

    /// 非数字分量 → nil。
    func testNilWhenComponentNotNumeric() {
        XCTAssertNil(ISOTimeStringDecoder.date(from: "2026-XX-11T05:53", utcOffsetSeconds: 0))
        XCTAssertNil(ISOTimeStringDecoder.date(from: "2026-09-11Taa:53", utcOffsetSeconds: 0))
    }

    /// 空串 / 纯空白 → nil。
    func testNilWhenStringEmptyOrWhitespace() {
        XCTAssertNil(ISOTimeStringDecoder.date(from: "", utcOffsetSeconds: 0))
        XCTAssertNil(ISOTimeStringDecoder.date(from: "   ", utcOffsetSeconds: 0))
    }

    /// 非法分量：**纯数字但超出语义范围**（13 月 / 32 日）→ **nil**。
    ///
    /// 🔴 **断言翻转记录（2026-10-07 普查，勿再翻回去）**
    ///
    /// 本用例此前**断言 rollover 为期望行为**（13 月 → 2027-01、32 日 → 2026-10-02，
    /// 用 `XCTUnwrap` 断言非 nil），依据是 CI run12 的实测记录
    /// 「Foundation 的 `Calendar.date(from:)` 对越界分量不做裁剪、返回非 nil」
    /// ——**这条实测记录本身是正确且仍然有效的**，被推翻的是它的**结论**。
    ///
    /// 它当时的理由是：「真正的防线在**语义校验**，由调用侧（mapper）对结果再
    /// 校验；解码器的职责是『格式守门』，语义越界交由上层可观测处理」。
    /// 🔴 **该理由已核实为不成立**：8 个生产调用点
    /// （EnsembleMapper:35 / FloodMapper:96 / MarineMapper:109 /
    /// METNorwayMapper:99,109 / OpenMeteoMapper:507 / SunriseSunsetMapper:71,80）
    /// 对 `dateComponents` / `range(of:` / `contains(` 的命中数**全部为 0**
    /// ——**没有任何调用侧再校验**。⇒ rollover 是在一条不成立的前提下被接受的。
    ///
    /// 且函数名 `testNilWhenDateComponentsInvalid` 本来就写着 Nil，
    /// 证明**原始意图一直是 nil**，是断言被改歪了。
    ///
    /// ⇒ 现在**实现与断言同时收紧**为 nil（与 `NmcIssueTimeDecoder` 同一处置）。
    /// 依据纪律「时刻解析绝不猜」：一个凭空编出的时刻形态完全合法、
    /// **不触发任何 stale 兜底**，比nil 糟糕得多。
    func testNilWhenDateComponentsInvalid() {
        // 越界分量必须 nil，绝不返回归一化后的时刻。
        XCTAssertNil(ISOTimeStringDecoder.date(from: "2026-13-01T05:53", utcOffsetSeconds: 0),
                     "13 月必须 nil（不得归一化成 2027-01-01）")
        XCTAssertNil(ISOTimeStringDecoder.date(from: "2026-09-32T05:53", utcOffsetSeconds: 0),
                     "32 日必须 nil（不得归一化成 2026-10-02）")
    }

    /// 🔴 「范围合法但日历上不存在」也必须 nil（`701bf79` 教训的固化护栏）。
    ///
    /// 只查 `1...31` 拦不住这些形态 —— 必须靠实现里的**回读自证**。
    /// Python 复刻依据（`datetime` 与 `Calendar.date(from:)` 归一化规则同构）：
    /// `2026-02-30` → `2026-03-02`、`2026-04-31` → `2026-05-01`、
    /// 平年 `2026-02-29` → `2026-03-01`。
    /// ⚠️ 依据 = Python 复刻 + 仓库既有实测记录，未在 Swift 上实跑。
    func testNilWhenDayDoesNotExistInThatMonth() {
        XCTAssertNil(ISOTimeStringDecoder.date(from: "2026-02-30T05:53", utcOffsetSeconds: 0),
                     "2 月 30 日在日历上不存在，必须 nil（不得归一化成 3-02）")
        XCTAssertNil(ISOTimeStringDecoder.date(from: "2026-04-31T05:53", utcOffsetSeconds: 0),
                     "4 月 31 日在日历上不存在，必须 nil（不得归一化成 5-01）")
        XCTAssertNil(ISOTimeStringDecoder.date(from: "2026-02-29T05:53", utcOffsetSeconds: 0),
                     "2026 是平年，2 月 29 日不存在，必须 nil（不得归一化成 3-01）")
    }

    /// 🔴 时 / 分 / 秒越界同样必须 nil（`25` 时不是「次日 1 时」）。
    ///
    /// 分 99 与秒 61 是 `NmcIssueTimeDecoder` 那次**没覆盖**到的形态，
    /// Python 复刻确认它们同样被溢出改写（20:99 → 21:39、20:28:61 → 20:29:01）。
    func testNilWhenTimeComponentsOutOfRange() {
        XCTAssertNil(ISOTimeStringDecoder.date(from: "2026-10-06T25:28", utcOffsetSeconds: 0),
                     "25 时非法，必须 nil（不得归一化成次日 01 时）")
        XCTAssertNil(ISOTimeStringDecoder.date(from: "2026-10-06T20:99", utcOffsetSeconds: 0),
                     "分 99 非法，必须 nil（不得归一化成 21:39）")
        XCTAssertNil(ISOTimeStringDecoder.date(from: "2026-10-06T20:28:61", utcOffsetSeconds: 0),
                     "秒 61 非法，必须 nil（不得归一化成 20:29:01）")
    }

    /// 时段缺分（只有小时）→ nil。
    func testNilWhenTimePartIncomplete() {
        XCTAssertNil(ISOTimeStringDecoder.date(from: "2026-09-11T05", utcOffsetSeconds: 0))
    }

    /// 闰日格式：2024-02-29 合法（闰年）。
    func testDateWhenLeapDay() throws {
        let date = try XCTUnwrap(ISOTimeStringDecoder.date(
            from: "2024-02-29T06:00", utcOffsetSeconds: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.month, .day], from: date)
        XCTAssertEqual(components.month, 2)
        XCTAssertEqual(components.day, 29)
    }
}

//
//  UVIndexGuideTests.swift
//  ZhishengWeatherTests
//
//  `UVIndexGuide`（P2· AC-B17c）单测 —— 纯逻辑，不联网、不取系统时钟（`now` 全部注入）。
//
//  覆盖：
//   ① WHO 五档的**边界值**（2/3、5/6、7/8、10/11 四个临界点，逐一两侧断言）；
//   ② **`0` 是合法值**（夜间），绝不被当成缺失；
//   ③ **nil → nil**（无数据即隐藏，不返回 "未知/0"档）；
//   ④ 当日峰值：峰值取值 / 峰值时刻 / 跨天排除 / 缺测跳过 / 全缺→nil / 全 0→峰值 0。
//
//  量表出处见 `Core/Logic/UVIndexGuide.swift` 文件头（WHO Global Solar UV Index 五档量表）。
//

import XCTest
@testable import ZhishengWeather

final class UVIndexGuideTests: XCTestCase {

    /// 固定基准时刻：**2026-10-06 00:00:00 UTC**（当日零点，使 0..23 点的偏移
    /// **全部落在同一自然日内**——否则 24 条用例会跨零点而被"当日"过滤掉一部分）。
    private let baseEpoch: TimeInterval = 1_791_244_800
    /// 固定时区（UTC）——峰值"当日"归属必须可复现，绝不能用设备时区。
    private let timeZone = TimeZone(identifier: "UTC")!

    // MARK: - Helpers

    private func point(_ offsetHours: Int,
                       uv: Double?,
                       visibility: Double? = nil,
                       freezingLevel: Double? = nil) -> HourlyPoint {
        HourlyPoint(time: Date(timeIntervalSince1970: baseEpoch + Double(offsetHours) * 3600),
                    temperature: 20,
                    weatherCode: 1,
                    precipitationProbability: nil,
                    precipitation: nil,
                    windSpeed: nil,
                    windGusts: nil,
                    apparentTemperature: nil,
                    windDirection: nil,
                    uvIndex: uv,
                    visibility: visibility,
                    freezingLevelHeight: freezingLevel)
    }

    private var now: Date { Date(timeIntervalSince1970: baseEpoch) }

    // MARK: - ① WHO 五档边界（2/3、5/6、7/8、10/11）

    func testLevelBoundaryLowToModerate() {
        XCTAssertEqual(UVIndexLevel(uv: 0), .low)
        XCTAssertEqual(UVIndexLevel(uv: 2), .low, "2 属低档上沿")
        XCTAssertEqual(UVIndexLevel(uv: 2.9), .low, "2.9 仍是低档")
        XCTAssertEqual(UVIndexLevel(uv: 3), .moderate, "3 是中等档下沿（2/3 临界）")
    }

    func testLevelBoundaryModerateToHigh() {
        XCTAssertEqual(UVIndexLevel(uv: 5), .moderate, "5 属中等档上沿")
        XCTAssertEqual(UVIndexLevel(uv: 5.9), .moderate)
        XCTAssertEqual(UVIndexLevel(uv: 6), .high, "6 是高档下沿（5/6 临界）")
    }

    func testLevelBoundaryHighToVeryHigh() {
        XCTAssertEqual(UVIndexLevel(uv: 7), .high, "7 属高档上沿")
        XCTAssertEqual(UVIndexLevel(uv: 7.9), .high)
        XCTAssertEqual(UVIndexLevel(uv: 8), .veryHigh, "8 是很高档下沿（7/8 临界）")
    }

    func testLevelBoundaryVeryHighToExtreme() {
        XCTAssertEqual(UVIndexLevel(uv: 10), .veryHigh, "10 属很高档上沿")
        XCTAssertEqual(UVIndexLevel(uv: 10.9), .veryHigh)
        XCTAssertEqual(UVIndexLevel(uv: 11), .extreme, "11 是极高档下沿（10/11 临界）")
    }

    func testLevelExtremeUpperUnbounded() {
        XCTAssertEqual(UVIndexLevel(uv: 11.5), .extreme)
        XCTAssertEqual(UVIndexLevel(uv: 40), .extreme, "11+ 无上界（Open-Meteo 极端实测可到 12+）")
    }

    // MARK: - ② UV == 0 是合法值，不得当成缺失

    func testZeroUVIsLowLevelNotMissing() {
        XCTAssertEqual(UVIndexLevel(uv: 0), .low, "0 是合法夜间值，不是缺测")
        let advice = UVIndexGuide.currentAdvice(uv: 0)
        XCTAssertEqual(advice?.level, .low)
        XCTAssertEqual(advice?.adviceText, "无需防护")
    }

    func testCurrentAdviceZeroIsNotNil() {
        XCTAssertNotNil(UVIndexGuide.currentAdvice(uv: 0),
                        "0 必须给出建议（夜间无需防护），不得返回 nil 让调用方隐藏")
    }

    // MARK: - ③ nil / 非法值 → nil（不返回 "未知"档）

    func testNilUVYieldsNilAdvice() {
        XCTAssertNil(UVIndexGuide.currentAdvice(uv: nil), "无数据 → nil，调用方整块隐藏")
        XCTAssertNil(UVIndexLevel(uv: nil))
    }

    func testNonFiniteAndNegativeUVYieldNil() {
        XCTAssertNil(UVIndexLevel(uv: .nan), "NaN 不是 0 档")
        XCTAssertNil(UVIndexLevel(uv: .infinity))
        XCTAssertNil(UVIndexLevel(uv: -1.0), "负值物理上不存在 → nil，绝不当 0 处理")
        XCTAssertNil(UVIndexGuide.currentAdvice(uv: .nan))
    }

    // MARK: - 文案与档位绑定（UI 不另拼句，故一并锁死字面量）

    func testAdviceTextPerLevel() {
        XCTAssertEqual(UVIndexLevel(uv: 1)?.adviceText, "无需防护")
        XCTAssertEqual(UVIndexLevel(uv: 4)?.adviceText, "建议 SPF30+")
        XCTAssertEqual(UVIndexLevel(uv: 6.5)?.adviceText, "建议 SPF50+、减少正午户外")
        XCTAssertEqual(UVIndexLevel(uv: 9)?.adviceText, "尽量避开 11–16 时")
        XCTAssertEqual(UVIndexLevel(uv: 12)?.adviceText, "避免日晒")
    }

    func testLevelDisplayNames() {
        XCTAssertEqual(UVIndexLevel(uv: 1)?.displayName, "低")
        XCTAssertEqual(UVIndexLevel(uv: 4)?.displayName, "中等")
        XCTAssertEqual(UVIndexLevel(uv: 7)?.displayName, "高")
        XCTAssertEqual(UVIndexLevel(uv: 10)?.displayName, "很高")
        XCTAssertEqual(UVIndexLevel(uv: 11)?.displayName, "极高")
    }

    /// 档位与文案必须来自同一处（`Advice.adviceText` 直接取自level），
    /// 杜绝"档位变了文案没变"的脱节。
    func testAdviceTextAlwaysMatchesItsLevel() {
        for level in UVIndexLevel.allCases {
            let uv: Double
            switch level {
            case .low: uv = 1
            case .moderate: uv = 4
            case .high: uv = 7
            case .veryHigh: uv = 9
            case .extreme: uv = 12
            }
            let advice = UVIndexGuide.currentAdvice(uv: uv)
            XCTAssertEqual(advice?.level, level)
            XCTAssertEqual(advice?.adviceText, level.adviceText,
                           "\(level) 档的文案必须与档位同源")
        }
    }

    // MARK: - ④ 当日峰值：取值 + 时刻

    func testDailyPeakReturnsValueAndTime() throws {
        // UV 序列 0,1.95,4.25,4.90,3.25（对齐实测北京正午峰值形态）→ 峰值 4.90 @ 第 4 小时。
        let points = [0.0, 1.95, 4.25, 4.9, 3.25].enumerated().map { point($0.offset, uv: $0.element) }
        let peak = try XCTUnwrap(UVIndexGuide.dailyPeak(points: points, now: now, timeZone: timeZone))
        XCTAssertEqual(peak.value, 4.9, accuracy: 1e-9)
        XCTAssertEqual(peak.time, Date(timeIntervalSince1970: baseEpoch + 3 * 3600),
                       "峰值时刻 = 峰值所在整点，而非别的点")
    }

    func testDailyPeakTiesKeepEarlierHour() throws {
        // 两个小时同为 5.0 → 保留**更早**的那个（结果稳定可复现）。
        let points = [0.0, 5.0, 5.0, 1.0].enumerated().map { point($0.offset, uv: $0.element) }
        let peak = try XCTUnwrap(UVIndexGuide.dailyPeak(points: points, now: now, timeZone: timeZone))
        XCTAssertEqual(peak.value, 5.0, accuracy: 1e-9)
        XCTAssertEqual(peak.time, Date(timeIntervalSince1970: baseEpoch + 3600),
                       "同值取首次出现（更早的时刻）")
    }

    func testDailyPeakAllZeroIsAValidPeakNotNil() throws {
        // 全天无日照：峰值合法地是 0.0，且**必须**返回峰值（而非 nil）。
        let points = (0..<4).map { point($0, uv: 0.0) }
        let peak = try XCTUnwrap(UVIndexGuide.dailyPeak(points: points, now: now, timeZone: timeZone),
                                 "「全天 UV 为 0」是结论，不是无数据")
        XCTAssertEqual(peak.value, 0.0, accuracy: 1e-9)
        XCTAssertEqual(peak.time, Date(timeIntervalSince1970: baseEpoch),
                       "并列 0.0 时取最早的那个整点")
        XCTAssertEqual(UVIndexLevel(uv: peak.value), .low, "峰值 0 → 低档")
    }

    func testDailyPeakSkipsNilHours() throws {
        // 第2 小时缺测（nil），峰值应落在第 3 小时，**不得**把 nil 当 0 参与比较。
        let points = [3.0, nil, 4.9, nil].enumerated().map { point($0.offset, uv: $0.element) }
        let peak = try XCTUnwrap(UVIndexGuide.dailyPeak(points: points, now: now, timeZone: timeZone))
        XCTAssertEqual(peak.value, 4.9, accuracy: 1e-9)
        XCTAssertEqual(peak.time, Date(timeIntervalSince1970: baseEpoch + 2 * 3600))
    }

    func testDailyPeakAllNilYieldsNil() {
        let points = (0..<4).map { point($0, uv: nil) }
        XCTAssertNil(UVIndexGuide.dailyPeak(points: points, now: now, timeZone: timeZone),
                     "全缺测 → nil（整卡隐藏），绝不返回 0当峰值")
    }

    func testDailyPeakNilOrEmptyYieldsNil() {
        XCTAssertNil(UVIndexGuide.dailyPeak(points: nil, now: now, timeZone: timeZone))
        XCTAssertNil(UVIndexGuide.dailyPeak(points: [], now: now, timeZone: timeZone))
    }

    /// 跨天排除：序列里混了"昨天"的点，峰值必须只取`now` 所在自然日。
    func testDailyPeakExcludesOtherLocalDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // 今天 3 个点（峰值 4.0）+ 昨天 2 个点（伪造更高值 9.9 / 9.8）。
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let points = [
            HourlyPoint(time: yesterday, temperature: 20, weatherCode: 1,
                        precipitationProbability: nil, precipitation: nil, windSpeed: nil,
                        windGusts: nil, apparentTemperature: nil, windDirection: nil,
                        uvIndex: 9.9),
            HourlyPoint(time: yesterday.addingTimeInterval(3600), temperature: 20, weatherCode: 1,
                        precipitationProbability: nil, precipitation: nil, windSpeed: nil,
                        windGusts: nil, apparentTemperature: nil, windDirection: nil,
                        uvIndex: 9.8),
            point(0, uv: 1.0),
            point(1, uv: 4.0),
            point(2, uv: 2.0)
        ]
        let peak = try XCTUnwrap(UVIndexGuide.dailyPeak(points: points, now: now, timeZone: timeZone))
        XCTAssertEqual(peak.value, 4.0, accuracy: 1e-9,
                       "昨天的 9.9绝不能当今天的峰值（否则「今日峰值」会说谎）")
        XCTAssertEqual(peak.time, Date(timeIntervalSince1970: baseEpoch + 3600))
    }

    /// 时区影响归属：同一串时刻在不同时区下可能属于不同自然日。
    /// 本用例锁死"**时区由调用方注入**"这一纪律确实生效（不是写死 UTC）。
    func testDailyPeakRespectsInjectedTimeZone() throws {
        // baseEpoch = 2026-10-06T00:00Z，在 UTC+8 下是 10-06 08:00。
        // 前 20 小时 = 10-05 04:00Z = 10-05 12:00 (+0800) → 落在**前一天**。
        let shifted = point(-20, uv: 7.7)
        let today = point(0, uv: 2.0)

        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai
        XCTAssertNotEqual(calendar.startOfDay(for: shifted.time),
                          calendar.startOfDay(for: now),
                           "前置 20 小时的点应落在前一天（UTC+8 下）")

        let peak = try XCTUnwrap(UVIndexGuide.dailyPeak(points: [shifted, today],
                                                         now: now, timeZone: shanghai))
        XCTAssertEqual(peak.value, 2.0, accuracy: 1e-9,
                       "UTC+8 下前 20 小时那个点属昨天 → 不得参与峰值")
    }

    /// 跨天超长序列 → 拒绝出数（避免"当日峰值"名不副实）。
    func testDailyPeakRejectsCrossDayOversizedSequence() {
        let points = (0..<25).map { point($0, uv: 5.0) }
        XCTAssertNil(UVIndexGuide.dailyPeak(points: points, now: now, timeZone: timeZone),
                     "25 条序列跨天，口径会变成多天峰值 → 宁可不给出数")
    }

    /// 单日 24 条（含跨零点前的最后一条）应正常出数——24 是合法上限。
    func testDailyPeakAcceptsFullTwentyFourHours() throws {
        let points = (0..<24).map { point($0, uv: Double($0 % 8)) }
        let peak = try XCTUnwrap(UVIndexGuide.dailyPeak(points: points, now: now, timeZone: timeZone))
        XCTAssertEqual(peak.value, 7.0, accuracy: 1e-9)
    }
}
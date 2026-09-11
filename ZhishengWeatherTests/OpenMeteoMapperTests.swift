//
//  OpenMeteoMapperTests.swift
//  ZhishengWeatherTests
//
//  纯函数 OpenMeteoMapper 的边界用例（不联网）：
//   - 逐小时截窗的 4 种边界（整点命中 / 半点 / now 早于全部点 / now 晚于全部点）
//   - 三数组长度不齐、hourly 为空
//   - daily 存在 / 缺失 / 为空 / 长度不足的回退
//   - 字段透传、fetchedAt 注入、location 不被覆盖
//
//  说明：DTO 与 Mapper 均为 internal，经 `@testable import` 直接构造，
//  无需 JSON 字符串即可覆盖更精细的边界。
//

import XCTest
@testable import ZhishengWeather

final class OpenMeteoMapperTests: XCTestCase {

    private let t0 = 1_700_000_000

    // MARK: - 截窗边界

    /// 边界①：now 恰好落在整点 → 起点即该整点（A1 后上限 24，构造 30 个点取满窗口）。
    func testWindowStartsAtCurrentHourWhenNowIsOnTheHour() {
        let times = (0..<30).map { t0 + $0 * 3_600 }
        let now = Date(timeIntervalSince1970: TimeInterval(t0 + 5 * 3_600))

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: times, temps: doubles(20, count: 30), codes: ints(1, count: 30)),
            location: .beijing,
            now: now
        )

        XCTAssertEqual(snapshot.hourly.count, OpenMeteoMapper.maxHourlyCount)
        XCTAssertEqual(snapshot.hourly.first?.time,
                       Date(timeIntervalSince1970: TimeInterval(t0 + 5 * 3_600)))
        XCTAssertEqual(snapshot.hourly.last?.time,
                       Date(timeIntervalSince1970: TimeInterval(t0 + 28 * 3_600)))
    }

    /// 边界②：now 为半点（14:30）→ 起点仍为所在整点（14:00）。
    func testWindowStartsAtHourFloorWhenNowIsHalfPast() {
        let times = (0..<30).map { t0 + $0 * 3_600 }
        let now = Date(timeIntervalSince1970: TimeInterval(t0 + 5 * 3_600 + 1_800))

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: times, temps: doubles(20, count: 30), codes: ints(1, count: 30)),
            location: .beijing,
            now: now
        )

        XCTAssertEqual(snapshot.hourly.first?.time,
                       Date(timeIntervalSince1970: TimeInterval(t0 + 5 * 3_600)))
        XCTAssertEqual(snapshot.hourly.count, OpenMeteoMapper.maxHourlyCount)
    }

    /// 边界③：now 早于全部点 → 从头开始（不丢首段预报）。
    func testWindowKeepsHeadWhenNowIsBeforeAllPoints() {
        let times = (0..<5).map { t0 + $0 * 3_600 }
        let now = Date(timeIntervalSince1970: TimeInterval(t0 - 7_200))

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: times, temps: doubles(20, count: 5), codes: ints(1, count: 5)),
            location: .beijing,
            now: now
        )

        XCTAssertEqual(snapshot.hourly.count, 5)
        XCTAssertEqual(snapshot.hourly.first?.time, Date(timeIntervalSince1970: TimeInterval(t0)))
    }

    /// 边界④：now 晚于全部点 → 仅保留最后一个点（不空、不崩）。
    func testWindowReturnsOnlyLastPointWhenNowIsAfterAllPoints() {
        let times = (0..<5).map { t0 + $0 * 3_600 }
        let now = Date(timeIntervalSince1970: TimeInterval(t0 + 100 * 3_600))

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: times, temps: doubles(20, count: 5), codes: ints(1, count: 5)),
            location: .beijing,
            now: now
        )

        XCTAssertEqual(snapshot.hourly.count, 1)
        XCTAssertEqual(snapshot.hourly.first?.time,
                       Date(timeIntervalSince1970: TimeInterval(t0 + 4 * 3_600)))
    }

    /// 跨零点连续性：窗口不因日历日切换而断裂。
    func testWindowContinuousAcrossMidnight() {
        // 固定 epoch：2024-01-01 00:00 UTC = 1704067200，取其前 2 小时 = 22:00 UTC 起点，
        // 8 条逐小时点跨越 UTC 零点。
        let startEpoch = 1_704_067_200 - 2 * 3_600
        let times = (0..<8).map { startEpoch + $0 * 3_600 }
        let now = Date(timeIntervalSince1970: TimeInterval(startEpoch + 3 * 3_600)) // 次日 01:00

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: times, temps: doubles(20, count: 8), codes: ints(1, count: 8)),
            location: .beijing,
            now: now
        )

        XCTAssertEqual(snapshot.hourly.count, 5)
        XCTAssertEqual(snapshot.hourly.first?.time,
                       Date(timeIntervalSince1970: TimeInterval(startEpoch + 3 * 3_600)))
        // 逐点间隔恰好 3600s，跨零点不产生空档
        for (a, b) in zip(snapshot.hourly, snapshot.hourly.dropFirst()) {
            XCTAssertEqual(b.time.timeIntervalSince(a.time), 3_600, accuracy: 1e-6)
        }
    }

    // MARK: - 数组长度不齐 / 空数组

    func testMismatchedArraysAlignToMinimum() throws {
        let times = [t0, t0 + 3_600, t0 + 7_200]
        let temps = [20.0]                       // 最短
        let codes = [1, 2, 3]

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: times, temps: temps, codes: codes),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        XCTAssertEqual(snapshot.hourly.count, 1)
        XCTAssertEqual(try XCTUnwrap(snapshot.hourly.first).temperature, 20.0, accuracy: 1e-9)
    }

    func testEmptyHourlyProducesEmptyWindowAndFallsBackToCurrent() {
        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [], temps: [], codes: [], daily: nil, currentTemp: 17.5),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        XCTAssertTrue(snapshot.hourly.isEmpty)
        XCTAssertEqual(snapshot.dailyHigh, 17.5, accuracy: 1e-9)
        XCTAssertEqual(snapshot.dailyLow, 17.5, accuracy: 1e-9)
        XCTAssertEqual(snapshot.temperature, 17.5, accuracy: 1e-9)
    }

    // MARK: - daily 回退矩阵

    func testDailyPresentOverridesHourlyWindow() {
        let times = (0..<12).map { t0 + $0 * 3_600 }
        let temps = (0..<12).map { 10.0 + Double($0) }   // 10...21

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: times, temps: temps, codes: ints(1, count: 12),
                         daily: OpenMeteoResponse.Daily(time: [t0],
                                                        temperature_2m_max: [40.0],
                                                        temperature_2m_min: [-5.0],
                                                        weather_code: nil,
                                                        precipitation_probability_max: nil,
                                                        sunrise: nil, sunset: nil)),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        XCTAssertEqual(snapshot.dailyHigh, 40.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.dailyLow, -5.0, accuracy: 1e-9)
    }

    func testMissingDailyFallsBackToHourlyWindow() {
        let times = (0..<12).map { t0 + $0 * 3_600 }
        let temps = (0..<12).map { 10.0 + Double($0) }   // 10...21

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: times, temps: temps, codes: ints(1, count: 12), daily: nil),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        XCTAssertEqual(snapshot.dailyHigh, 21.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.dailyLow, 10.0, accuracy: 1e-9)
    }

    func testDailyWithEmptyArraysFallsBackToHourlyWindow() {
        let times = (0..<12).map { t0 + $0 * 3_600 }
        let temps = (0..<12).map { 10.0 + Double($0) }

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: times, temps: temps, codes: ints(1, count: 12),
                         daily: OpenMeteoResponse.Daily(time: [],
                                                        temperature_2m_max: [],
                                                        temperature_2m_min: [],
                                                        weather_code: nil,
                                                        precipitation_probability_max: nil,
                                                        sunrise: nil, sunset: nil)),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        XCTAssertEqual(snapshot.dailyHigh, 21.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.dailyLow, 10.0, accuracy: 1e-9)
    }

    /// daily 长度不足时，高温/低温应**各自独立**回退，不能因一个缺失而整体丢弃。
    func testDailyShortArraysFallBackIndependently() {
        let times = (0..<12).map { t0 + $0 * 3_600 }
        let temps = (0..<12).map { 10.0 + Double($0) }   // window min = 10, max = 21

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: times, temps: temps, codes: ints(1, count: 12),
                         daily: OpenMeteoResponse.Daily(time: [t0],
                                                        temperature_2m_max: [30.0],
                                                        temperature_2m_min: [],
                                                        weather_code: nil,
                                                        precipitation_probability_max: nil,
                                                        sunrise: nil, sunset: nil)),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        XCTAssertEqual(snapshot.dailyHigh, 30.0, accuracy: 1e-9, "daily.max 有值应优先")
        XCTAssertEqual(snapshot.dailyLow, 10.0, accuracy: 1e-9, "daily.min 为空应回退 hourly 窗口")
    }

    // MARK: - 字段透传

    func testCurrentFieldsAndIsDayMapCorrectly() {
        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [t0], temps: [18.0], codes: [3], currentTemp: 18.3, isDay: 0),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        XCTAssertFalse(snapshot.isDay)
        XCTAssertEqual(snapshot.temperature, 18.3, accuracy: 1e-9)
        XCTAssertEqual(snapshot.apparentTemperature, 17.3, accuracy: 1e-9)
        XCTAssertEqual(snapshot.weatherCode, 3)
        XCTAssertEqual(snapshot.humidity, 50)
        XCTAssertEqual(snapshot.windSpeed, 1.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.windDirection, 90.0, accuracy: 1e-9)
    }

    func testFetchedAtEqualsInjectedNow() {
        let now = Date(timeIntervalSince1970: 1_700_000_123)
        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [t0], temps: [18.0], codes: [0]),
            location: .beijing,
            now: now
        )
        XCTAssertEqual(snapshot.fetchedAt, now)
    }

    func testLocationIsPreservedVerbatim() {
        let loc = LocationInfo(name: "测试市", latitude: 1.5, longitude: 2.5, isFallback: false)
        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [t0], temps: [18.0], codes: [0]),
            location: loc,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )
        XCTAssertEqual(snapshot.location, loc)
        XCTAssertFalse(snapshot.location.isFallback)
    }

    /// unixtime 语义：hourly.time / current.time 均为 epoch 秒，直接映射为绝对时刻。
    func testUnixtimeFieldsBecomeAbsoluteInstants() throws {
        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [t0], temps: [18.0], codes: [0]),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )
        let first = try XCTUnwrap(snapshot.hourly.first)
        XCTAssertEqual(first.time, Date(timeIntervalSince1970: TimeInterval(t0)))
        XCTAssertEqual(first.time.timeIntervalSince1970, Double(t0), accuracy: 1e-6)
    }

    // MARK: - F-A 逐日映射

    /// ① 7 天正常映射：date / weatherCode / tempMax / tempMin / precip 全对。
    func testDailySevenDaysMapAllFields() throws {
        let times = (0..<7).map { t0 + $0 * 86_400 }
        let daily = makeDaily(times: times,
                              maxTemps: (0..<7).map { 20.0 + Double($0) },
                              minTemps: (0..<7).map { 10.0 + Double($0) },
                              codes: (0..<7).map { $0 % 4 },
                              precip: (0..<7).map { $0 * 10 })

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [t0], temps: [18.0], codes: [1], daily: daily),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        let list = try XCTUnwrap(snapshot.daily)
        XCTAssertEqual(list.count, 7)
        XCTAssertEqual(list[0].date, Date(timeIntervalSince1970: TimeInterval(times[0])))
        XCTAssertEqual(list[3].weatherCode, 3)
        XCTAssertEqual(list[5].tempMax, 25.0, accuracy: 1e-9)
        XCTAssertEqual(list[5].tempMin, 15.0, accuracy: 1e-9)
        XCTAssertEqual(list[5].precipitationProbability, 50)
    }

    /// ② 四必需数组长度不齐 → 按最短截断（AC-A6）。
    func testDailyMismatchedRequiredArraysTruncateToShortest() {
        let daily = makeDaily(times: (0..<5).map { t0 + $0 * 86_400 },
                              maxTemps: (0..<4).map { _ in 20.0 },
                              minTemps: (0..<5).map { _ in 10.0 },
                              codes: [1, 2, 3],
                              precip: nil)

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [t0], temps: [18.0], codes: [1], daily: daily),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        XCTAssertEqual(snapshot.daily?.count, 3, "对齐数组最短长度为 3（AC-A6）")
    }

    /// ③ DTO daily 缺失 → snapshot.daily == nil（AC-A7 数据源头）。
    func testMissingDailyBlockProducesNilSnapshotDaily() {
        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [t0], temps: [18.0], codes: [1], daily: nil),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )
        XCTAssertNil(snapshot.daily, "daily 块缺失必须映射为 nil，而非空数组")
    }

    /// ④ precip 元素 null → 对应行 precipitationProbability == nil（绝不透传 0）。
    func testDailyPrecipitationNullElementMapsToNilRow() {
        let daily = makeDaily(times: (0..<3).map { t0 + $0 * 86_400 },
                              maxTemps: [25.0, 21.0, 23.0],
                              minTemps: [15.0, 14.0, 13.0],
                              codes: [0, 61, 2],
                              precip: [80, nil, 20])

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [t0], temps: [18.0], codes: [1], daily: daily),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        let list = snapshot.daily ?? []
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0].precipitationProbability, 80)
        XCTAssertNil(list[1].precipitationProbability, "null 元素必须映射为 nil（AC-A5）")
        XCTAssertEqual(list[2].precipitationProbability, 20)
    }

    /// ⑤ precip 整键缺失 → 全行 nil（而非 0）。
    func testDailyPrecipitationKeyMissingMapsAllRowsToNil() {
        let daily = makeDaily(times: (0..<3).map { t0 + $0 * 86_400 },
                              maxTemps: [25.0, 21.0, 23.0],
                              minTemps: [15.0, 14.0, 13.0],
                              codes: [0, 61, 2],
                              precip: nil)

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [t0], temps: [18.0], codes: [1], daily: daily),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        let list = snapshot.daily ?? []
        XCTAssertEqual(list.count, 3)
        for (index, day) in list.enumerated() {
            XCTAssertNil(day.precipitationProbability, "第 \(index) 行 precip 整键缺失应为 nil")
        }
    }

    /// ⑥ weather_code 整键缺失 → 按空数组对齐 → snapshot.daily == []（区块隐藏而非脏数据）。
    func testDailyWeatherCodeKeyMissingProducesEmptyDailyArray() {
        let daily = makeDaily(times: (0..<3).map { t0 + $0 * 86_400 },
                              maxTemps: [25.0, 21.0, 23.0],
                              minTemps: [15.0, 14.0, 13.0],
                              codes: nil,
                              precip: [10, 20, 30])

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [t0], temps: [18.0], codes: [1], daily: daily),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        XCTAssertEqual(snapshot.daily, [], "weather_code 缺失 → 空数组（非 nil、非脏数据）")
    }

    /// ⑦ precip 数组比必需数组短 → 越界行 precip 为 nil（元素级兜底）。
    func testDailyPrecipitationShortArrayBoundsRowsToNil() {
        let daily = makeDaily(times: (0..<3).map { t0 + $0 * 86_400 },
                              maxTemps: [25.0, 21.0, 23.0],
                              minTemps: [15.0, 14.0, 13.0],
                              codes: [0, 0, 0],
                              precip: [50])

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [t0], temps: [18.0], codes: [1], daily: daily),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        let list = snapshot.daily ?? []
        XCTAssertEqual(list[0].precipitationProbability, 50)
        XCTAssertNil(list[1].precipitationProbability, "越界行应为 nil")
        XCTAssertNil(list[2].precipitationProbability, "越界行应为 nil")
    }

    /// ⑧ 超过 16 天按 maxDailyCount 截断（A1 后 7→16）。
    func testDailyMoreThanSixteenDaysTruncatedToMaxDailyCount() {
        let count = 18
        let daily = makeDaily(times: (0..<count).map { t0 + $0 * 86_400 },
                              maxTemps: Array(repeating: 25.0, count: count),
                              minTemps: Array(repeating: 15.0, count: count),
                              codes: Array(repeating: 0, count: count),
                              precip: Array(repeating: 0, count: count))

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [t0], temps: [18.0], codes: [1], daily: daily),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        XCTAssertEqual(snapshot.daily?.count, OpenMeteoMapper.maxDailyCount,
                       "逐日条数不得超过 maxDailyCount=\(OpenMeteoMapper.maxDailyCount)")
    }

    /// ⑨ 旧路径回归：无 past_days（time[0]=今天）→ todayIndex=0，输出含全部行。
    func testDailyWhenTodayIsFirstRowKeepsAllRowsFromIndexZero() {
        let daily = makeDaily(times: (0..<4).map { t0 + $0 * 86_400 },
                              maxTemps: [27.0, 26.0, 25.0, 24.0],
                              minTemps: [17.0, 16.0, 15.0, 14.0],
                              codes: [0, 1, 2, 3],
                              precip: nil)

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [t0], temps: [18.0], codes: [0], daily: daily),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        XCTAssertEqual(snapshot.dailyHigh, 27.0, accuracy: 1e-9, "今日行=第 0 行")
        XCTAssertEqual(snapshot.dailyLow, 17.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.daily?.count, 4, "无昨日行时输出不截行")
        XCTAssertNil(snapshot.yesterday, "无 past_days → yesterday 必为 nil（AC-A1-16）")
    }

    // MARK: - A1 位移 / yesterday / daily 首行 / pressure / sunrise（★本批核心）

    /// ★（A1-5，本批最高静默回归风险）past_days=1 位移后：daily[0]=昨天、
    /// daily[1]=今天 → dailyHigh/Low 必须取**今日行**，不得沿用 `.first`。
    func testDailyHighLowWhenYesterdayPresentUsesTodayIndex() {
        let yesterdayEpoch = t0 - 86_400
        let daily = makeDaily(times: [yesterdayEpoch, t0],           // [昨天, 今天]
                              maxTemps: [31.0, 27.0],                // 昨天 31 / 今天 27
                              minTemps: [21.0, 17.0],                // 昨天 21 / 今天 17
                              codes: [1, 2],
                              precip: nil)

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [t0], temps: [18.0], codes: [2], daily: daily),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        XCTAssertEqual(snapshot.dailyHigh, 27.0, accuracy: 1e-9,
                       "位移后 Hero 高温必须取今日行，而非 daily.first（昨天的 31°）")
        XCTAssertEqual(snapshot.dailyLow, 17.0, accuracy: 1e-9,
                       "位移后 Hero 低温必须取今日行")
    }

    /// ★ yesterday 提取：取 todayIndex-1 行的完整对象（温度 / 现象 / 日期）。
    func testYesterdayExtractedFromRowBeforeTodayIndex() throws {
        let yesterdayEpoch = t0 - 86_400
        let daily = makeDaily(times: [yesterdayEpoch, t0],
                              maxTemps: [31.0, 27.0],
                              minTemps: [21.0, 17.0],
                              codes: [3, 2],
                              precip: nil)

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [t0], temps: [18.0], codes: [2], daily: daily),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        let yesterday = try XCTUnwrap(snapshot.yesterday, "有昨日行时 yesterday 必非 nil")
        XCTAssertEqual(yesterday.date, Date(timeIntervalSince1970: TimeInterval(yesterdayEpoch)))
        XCTAssertEqual(yesterday.tempMax, 31.0, accuracy: 1e-9)
        XCTAssertEqual(yesterday.tempMin, 21.0, accuracy: 1e-9)
        XCTAssertEqual(yesterday.weatherCode, 3)
    }

    /// ★ daily 输出自今日起截（§3 关键点 3）：输出首行恒为今天，昨日不混入。
    func testDailyOutputStartsAtTodayWhenYesterdayPresent() throws {
        let yesterdayEpoch = t0 - 86_400
        let daily = makeDaily(times: [yesterdayEpoch, t0, t0 + 86_400],
                              maxTemps: [31.0, 27.0, 26.0],
                              minTemps: [21.0, 17.0, 16.0],
                              codes: [1, 2, 3],
                              precip: nil)

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [t0], temps: [18.0], codes: [2], daily: daily),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        let list = try XCTUnwrap(snapshot.daily)
        XCTAssertEqual(list.first?.date, Date(timeIntervalSince1970: TimeInterval(t0)),
                       "snapshot.daily[0] 必须是今天（下游 prefix(3) 语义依赖）")
        XCTAssertEqual(list.count, 2, "昨日行不得混入 daily 数组")
        XCTAssertFalse(list.contains { $0.date == Date(timeIntervalSince1970: TimeInterval(yesterdayEpoch)) })
    }

    /// pressure 回退链：msl 有值 → msl；msl 缺 → surface；双缺 → nil。
    func testPressureFallbackChain() {
        let make = { (pressureMSL: Double?, surface: Double?) -> WeatherSnapshot in
            OpenMeteoMapper.map(
                self.makeResponse(times: [self.t0], temps: [18.0], codes: [1],
                                  currentPressureMSL: pressureMSL,
                                  currentSurfacePressure: surface),
                location: .beijing,
                now: Date(timeIntervalSince1970: TimeInterval(self.t0))
            )
        }

        XCTAssertEqual(make(1013.2, 1008.7).pressureMSL ?? -1, 1013.2, accuracy: 1e-9,
                       "msl 有值 → msl 优先")
        XCTAssertEqual(make(nil, 1008.7).pressureMSL ?? -1, 1008.7, accuracy: 1e-9,
                       "msl 缺 → surface 回退")
        XCTAssertNil(make(nil, nil).pressureMSL, "双缺 → nil（AC-A1-3）")
    }

    /// sunrise/sunset 注入：今日行合法字符串 → Date；坏串行 → nil。
    func testSunriseSunsetInjectedFromTodayRow() {
        let daily = OpenMeteoResponse.Daily(
            time: [t0],
            temperature_2m_max: [27.0],
            temperature_2m_min: [17.0],
            weather_code: [2],
            precipitation_probability_max: nil,
            sunrise: ["2026-09-11T05:53"],
            sunset: ["garbage"])

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [t0], temps: [18.0], codes: [2], daily: daily),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        // 合法串经独立解码器（+8h 偏移）→ 当地 05:53；坏串 → nil。
        XCTAssertNotNil(snapshot.sunrise, "合法 sunrise 字符串应解码出 Date")
        XCTAssertNil(snapshot.sunset, "坏串必须映射为 nil，绝不冒充")
    }

    /// hourly 24 条截窗（A1-2：12→24，截窗逻辑零改动）。
    func testHourlyWindowCapsAtTwentyFourWhenEnoughPoints() {
        let times = (0..<40).map { t0 + $0 * 3_600 }
        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: times, temps: doubles(20, count: 40), codes: ints(1, count: 40)),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )
        XCTAssertEqual(snapshot.hourly.count, 24, "窗口上限应为 24（A1-2）")
        XCTAssertEqual(snapshot.hourly.first?.time, Date(timeIntervalSince1970: TimeInterval(t0)))
    }

    /// yesterday 的 sunrise/sunset 亦按行注入（A2-5 逐日展开的直接复用面）。
    func testYesterdayCarriesOwnSunTimes() throws {
        let daily = OpenMeteoResponse.Daily(
            time: [t0 - 86_400, t0],
            temperature_2m_max: [31.0, 27.0],
            temperature_2m_min: [21.0, 17.0],
            weather_code: [1, 2],
            precipitation_probability_max: nil,
            sunrise: ["2026-09-10T05:54", "2026-09-11T05:53"],
            sunset: ["2026-09-10T18:23", "2026-09-11T18:22"])

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [t0], temps: [18.0], codes: [2], daily: daily),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        let yesterday = try XCTUnwrap(snapshot.yesterday)
        XCTAssertNotNil(yesterday.sunrise, "昨日行应有自己的日出")
        // 今日行的 sunrise 不应与昨日相同（按行注入而非复制今日值）。
        XCTAssertNotEqual(yesterday.sunrise, snapshot.sunrise)
    }

    /// todayIndex 回退链：daily.time 全部早于 now（时钟漂移形态）→ 兜底索引不越界。
    func testTodayIndexFallsBackWhenNoRowMatchesNow() throws {
        // daily.time 全是 10 天前的日期 → dayNumber 匹配失败 → 回退 min(1, count-1)。
        let pastEpoch = t0 - 10 * 86_400
        let daily = makeDaily(times: [pastEpoch, pastEpoch + 86_400],
                              maxTemps: [30.0, 28.0],
                              minTemps: [20.0, 18.0],
                              codes: [1, 2],
                              precip: nil)

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [t0], temps: [18.0], codes: [2], daily: daily),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        XCTAssertEqual(snapshot.dailyHigh, 28.0, accuracy: 1e-9,
                       "兜底索引 = min(1, count-1) = 1 → 取第 1 行高温")
        // CI run12 勘误：todayIndex=1 时 yesterday = todayIndex-1 = 0 行（合法非 nil），
        // 实现行为正确（取第 0 行做"昨日形态近似"），原断言 XCTAssertNil 自相矛盾。
        let yesterday = try XCTUnwrap(snapshot.yesterday)
        XCTAssertEqual(yesterday.tempMax, 30.0, accuracy: 1e-9,
                       "yesterday 应为兜底索引的前一行（第 0 行，30°）")
    }

    // MARK: - Helpers

    private func doubles(_ value: Double, count: Int) -> [Double] {
        Array(repeating: value, count: count)
    }

    private func ints(_ value: Int, count: Int) -> [Int] {
        Array(repeating: value, count: count)
    }

    private func makeResponse(times: [Int],
                              temps: [Double],
                              codes: [Int],
                              daily: OpenMeteoResponse.Daily? = nil,
                              currentTemp: Double = 20.0,
                              isDay: Int = 1,
                              currentPressureMSL: Double? = nil,
                              currentSurfacePressure: Double? = nil) -> OpenMeteoResponse {
        OpenMeteoResponse(
            timezone: "Asia/Shanghai",
            utc_offset_seconds: 28_800,
            current: OpenMeteoResponse.Current(
                time: times.first ?? t0,
                temperature_2m: currentTemp,
                relative_humidity_2m: 50,
                apparent_temperature: currentTemp - 1,
                weather_code: codes.first ?? 0,
                wind_speed_10m: 1.0,
                wind_direction_10m: 90.0,
                is_day: isDay,
                pressure_msl: currentPressureMSL,
                surface_pressure: currentSurfacePressure
            ),
            hourly: OpenMeteoResponse.Hourly(
                time: times,
                temperature_2m: temps,
                weather_code: codes
            ),
            daily: daily
        )
    }

    /// F-A/A1：构造 DTO 逐日块（codes / precip / sunrise / sunset 可传 nil 模拟键缺失；
    /// sunrise/sunset 为 ISO 墙钟字符串数组，与 time 逐行对应，CI run11 修复）。
    private func makeDaily(times: [Int],
                           maxTemps: [Double],
                           minTemps: [Double],
                           codes: [Int]? = nil,
                           precip: [Int?]? = nil,
                           sunrise: [String?]? = nil,
                           sunset: [String?]? = nil) -> OpenMeteoResponse.Daily {
        OpenMeteoResponse.Daily(
            time: times,
            temperature_2m_max: maxTemps,
            temperature_2m_min: minTemps,
            weather_code: codes,
            precipitation_probability_max: precip,
            sunrise: sunrise,
            sunset: sunset
        )
    }
}

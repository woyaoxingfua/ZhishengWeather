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

    /// 边界①：now 恰好落在整点 → 起点即该整点，共 12 条。
    func testWindowStartsAtCurrentHourWhenNowIsOnTheHour() {
        let times = (0..<20).map { t0 + $0 * 3_600 }
        let now = Date(timeIntervalSince1970: TimeInterval(t0 + 5 * 3_600))

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: times, temps: doubles(20, count: 20), codes: ints(1, count: 20)),
            location: .beijing,
            now: now
        )

        XCTAssertEqual(snapshot.hourly.count, OpenMeteoMapper.maxHourlyCount)
        XCTAssertEqual(snapshot.hourly.first?.time,
                       Date(timeIntervalSince1970: TimeInterval(t0 + 5 * 3_600)))
        XCTAssertEqual(snapshot.hourly.last?.time,
                       Date(timeIntervalSince1970: TimeInterval(t0 + 16 * 3_600)))
    }

    /// 边界②：now 为半点（14:30）→ 起点仍为所在整点（14:00）。
    func testWindowStartsAtHourFloorWhenNowIsHalfPast() {
        let times = (0..<20).map { t0 + $0 * 3_600 }
        let now = Date(timeIntervalSince1970: TimeInterval(t0 + 5 * 3_600 + 1_800))

        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: times, temps: doubles(20, count: 20), codes: ints(1, count: 20)),
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
                                                        precipitation_probability_max: nil)),
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
                                                        precipitation_probability_max: nil)),
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
                                                        precipitation_probability_max: nil)),
            location: .beijing,
            now: Date(timeIntervalSince1970: TimeInterval(t0))
        )

        XCTAssertEqual(snapshot.dailyHigh, 30.0, accuracy: 1e-9, "daily.max 有值应优先")
        XCTAssertEqual(snapshot.dailyLow, 10.0, accuracy: 1e-9, "daily.min 为空应回退 hourly 窗口")
    }

    // MARK: - 字段透传

    func testCurrentFieldsAndIsDayMapCorrectly() {
        let snapshot = OpenMeteoMapper.map(
            makeResponse(times: [t0], temps: [18.0], codes: [3], isDay: 0, currentTemp: 18.3),
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
                              maxTemps: (0..<4).map { 20.0 },
                              minTemps: (0..<5).map { 10.0 },
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

    /// ⑧ 超过 7 天按 maxDailyCount 截断。
    func testDailyMoreThanSevenDaysTruncatedToMaxDailyCount() {
        let count = 9
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
                              isDay: Int = 1) -> OpenMeteoResponse {
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
                is_day: isDay
            ),
            hourly: OpenMeteoResponse.Hourly(
                time: times,
                temperature_2m: temps,
                weather_code: codes
            ),
            daily: daily
        )
    }

    /// F-A：构造 DTO 逐日块（codes / precip 可传 nil 模拟键缺失）。
    private func makeDaily(times: [Int],
                           maxTemps: [Double],
                           minTemps: [Double],
                           codes: [Int]? = nil,
                           precip: [Int?]? = nil) -> OpenMeteoResponse.Daily {
        OpenMeteoResponse.Daily(
            time: times,
            temperature_2m_max: maxTemps,
            temperature_2m_min: minTemps,
            weather_code: codes,
            precipitation_probability_max: precip
        )
    }
}

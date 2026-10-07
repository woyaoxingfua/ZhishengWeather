//
//  ClimateProfileMapperTests.swift
//  ZhishengWeatherTests
//
//  气候档案映射器测试：10 年 fixture、同年同月同日过滤、差值算术、缺失年份、ERA5 滞后。
//  纯构造不联网。
//

import XCTest
@testable import ZhishengWeather

final class ClimateProfileMapperTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return cal
    }

    /// 构造只含目标日期行的 Archive 响应。
    /// - Parameter years: 要包含的年份；tempMax 用 `year % 100` 便于心算。
    /// - Returns: ArchiveResponse（daily.time 仅含各年 9 月 16 日）。
    private func response(years: [Int]) -> ArchiveResponse {
        var times: [String] = []
        var maxTemps: [Double?] = []
        for year in years {
            times.append(String(format: "%04d-09-16", year))
            maxTemps.append(Double(year % 100))
        }
        return ArchiveResponse(daily: ArchiveResponse.Daily(
            time: times,
            temperature_2m_max: maxTemps,
            temperature_2m_min: nil,
            weather_code: nil,
            precipitation_sum: nil
        ))
    }

    private func today(year: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = 9
        comps.day = 16
        comps.timeZone = calendar.timeZone
        return calendar.date(from: comps)!
    }

    // MARK: - 核心过滤与统计

    func testMapsTenYearFixtureAndComputesAverages() throws {
        // 2016..2025 年的 9 月 16 日，今天是 2026-09-16。
        let dto = response(years: Array(2016...2025))
        let profile = ClimateProfileMapper.map(dto, calendar: calendar,
                                               today: today(year: 2026),
                                               currentYearHigh: 35.0)

        XCTAssertEqual(profile.sameDateLastYear?.year, 2025)
        XCTAssertEqual(profile.sameDateLastYear?.tempMax, 25.0)

        XCTAssertEqual(profile.sameDateLast5Years?.count, 5)
        XCTAssertEqual(profile.sameDateLast10Years?.count, 10)

        // 2021..2025 %100 = 21..25，平均 23.0。
        XCTAssertEqual(profile.fiveYearAverageHigh, 23.0)
        // 2016..2025 %100 = 16..25，平均 20.5。
        XCTAssertEqual(profile.tenYearAverageHigh, 20.5)

        XCTAssertEqual(profile.fiveYearHighDelta, 23.0 - 35.0)
        XCTAssertEqual(profile.tenYearHighDelta, 20.5 - 35.0)
    }

    func testMissingYearIsSkippedWithoutCrash() throws {
        var years = Array(2016...2025)
        years.removeAll { $0 == 2020 }
        years.removeAll { $0 == 2023 }
        let dto = response(years: years)
        let profile = ClimateProfileMapper.map(dto, calendar: calendar,
                                               today: today(year: 2026),
                                               currentYearHigh: 30.0)

        XCTAssertFalse((profile.sameDateLast10Years ?? []).contains { $0.year == 2020 })
        XCTAssertFalse((profile.sameDateLast10Years ?? []).contains { $0.year == 2023 })
        XCTAssertEqual(profile.sameDateLast10Years?.count, 8)
        // 2016..2025 去掉 2020、2023 => [2016,2017,2018,2019,2021,2022,2024,2025]
        // last5 (year >= 2021): 2021,2022,2024,2025 => 4
        XCTAssertEqual(profile.sameDateLast5Years?.count, 4)
        XCTAssertNotNil(profile.fiveYearAverageHigh)
    }

    func testCurrentYearExcludedEvenIfPresent() throws {
        let dto = response(years: [2024, 2025, 2026])
        let profile = ClimateProfileMapper.map(dto, calendar: calendar,
                                               today: today(year: 2026),
                                               currentYearHigh: 40.0)

        XCTAssertEqual(profile.sameDateLastYear?.year, 2025)
        XCTAssertEqual(profile.sameDateLast5Years?.count, 2)
        XCTAssertFalse((profile.sameDateLast5Years ?? []).contains { $0.year == 2026 })
        XCTAssertFalse((profile.sameDateLast10Years ?? []).contains { $0.year == 2026 })
    }

    // MARK: - 边界

    func testEra5LagMissingLatestDatesStillProducesProfile() throws {
        // 今天是 2026-09-16，但 archive 响应只到 2025-09-16（ERA5 滞后约 5–6 天）。
        let dto = response(years: Array(2015...2025))
        let profile = ClimateProfileMapper.map(dto, calendar: calendar,
                                               today: today(year: 2026),
                                               currentYearHigh: 33.0)

        XCTAssertEqual(profile.sameDateLastYear?.year, 2025)
        XCTAssertEqual(profile.sameDateLast10Years?.count, 10)
        XCTAssertNotNil(profile.tenYearAverageHigh)
    }

    func testNilCurrentYearHighLeavesDeltasNil() throws {
        let dto = response(years: Array(2016...2025))
        let profile = ClimateProfileMapper.map(dto, calendar: calendar,
                                               today: today(year: 2026),
                                               currentYearHigh: nil)

        XCTAssertNotNil(profile.fiveYearAverageHigh)
        XCTAssertNil(profile.fiveYearHighDelta)
        XCTAssertNil(profile.tenYearHighDelta)
    }

    func testEmptyResponseReturnsEmptyProfile() throws {
        let dto = ArchiveResponse(daily: nil)
        let profile = ClimateProfileMapper.map(dto, calendar: calendar,
                                               today: today(year: 2026),
                                               currentYearHigh: 30.0)
        XCTAssertNil(profile.sameDateLastYear)
        XCTAssertTrue((profile.sameDateLast10Years ?? []).isEmpty)
        XCTAssertNil(profile.fiveYearAverageHigh)
    }

    func testNullTemperatureIsIgnoredInAverage() throws {
        var times: [String] = []
        var maxTemps: [Double?] = []
        for year in 2021...2025 {
            times.append(String(format: "%04d-09-16", year))
            maxTemps.append(year == 2023 ? nil : Double(year % 100))
        }
        let dto = ArchiveResponse(daily: ArchiveResponse.Daily(
            time: times,
            temperature_2m_max: maxTemps,
            temperature_2m_min: nil,
            weather_code: nil,
            precipitation_sum: nil
        ))
        let profile = ClimateProfileMapper.map(dto, calendar: calendar,
                                               today: today(year: 2026),
                                               currentYearHigh: 30.0)
        // 有效样本 21,22,24,25 -> 平均 (21+22+24+25)/4 = 23.0
        XCTAssertEqual(profile.fiveYearAverageHigh, 23.0)
    }

    // MARK: - 🔴 越界分量回归（2026-10-07 普查）

    /// 构造一个只含单条 `dateString` 的 archive 响应。
    private func response(dateString: String, tempMax: Double) -> ArchiveResponse {
        ArchiveResponse(daily: ArchiveResponse.Daily(
            time: [dateString],
            temperature_2m_max: [tempMax],
            temperature_2m_min: nil,
            weather_code: nil,
            precipitation_sum: nil
        ))
    }

    /// 构造「月/日可自定义」的 today（既有`today(year:)` 固定 9 月 16 日）。
    private func today(year: Int, month: Int, day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.timeZone = calendar.timeZone
        return calendar.date(from: comps)!
    }

    /// 🔴 **可复现的绕过反例**：今日为 **3 月 2 日**时，`"2025-02-30"`
    /// （2 月 30 日在日历上不存在）被旧实现归一化成 `2025-03-02`，而调用侧
    /// `:41-45` 的回读**只比对月/日/年**、且恰好要求「月/日 == 今日月/日」
    /// ⇒ 旧实现下它**通过全部 guard**，作为一条**凭空编造的**历史同日快照
    /// 进入 `sameDateLastYear` 与五年/十年均值。形态完全合法、不触发任何兜底。
    ///
    /// 依据：Python 复刻确认 `2025-02-30` → `2025-03-02`（`datetime` 与
    /// `Calendar.date(from:)` 归一化规则同构）。
    /// ⚠️ 依据 = Python 复刻 + 仓库既有实测记录，**未在 Swift 上实跑**。
    func testDayNotExistedInThatMonthIsDropped() {
        let dto = response(dateString: "2025-02-30", tempMax: 25.0)
        // today = 2026-03-02 ⇒ 今日月/日 = 3/2，正是归一化产物的月/日。
        let profile = ClimateProfileMapper.map(dto, calendar: calendar,
                                               today: today(year: 2026, month: 3, day: 2),
                                               currentYearHigh: 30.0)
        XCTAssertNil(profile.sameDateLastYear,
                     "2025-02-30 在日历上不存在，必须丢弃（不得归一化成 2025-03-02）")
        XCTAssertTrue((profile.sameDateLast5Years ?? []).isEmpty)
        XCTAssertTrue((profile.sameDateLast10Years ?? []).isEmpty)
        XCTAssertNil(profile.fiveYearAverageHigh,
                     "编造的条目不得进入五年均值")
    }

    /// 4 月 31 日 / 13 月 / 平年 2 月 29 日（2025 非闰年）同样必须丢弃。
    ///
    /// Python 复刻：`2025-04-31` → `2025-05-01`、`2025-13-01` → `2026-01-01`、
    /// `2025-02-29` → `2025-03-01`。后两者归一化后**月/日都变了**，
    /// 故这里把 today 固定成 1 月 1 日 / 3 月 1 日以覆盖各自形态。
    func testOtherOutOfRangeComponentsAreDropped() {
        // 4 月 31 日 → 2025-05-01；today 固定 5 月 1 日，构造同样的「恰好撞上」。
        let april31 = response(dateString: "2025-04-31", tempMax: 25.0)
        let p1 = ClimateProfileMapper.map(april31, calendar: calendar,
                                          today: today(year: 2026, month: 5, day: 1),
                                          currentYearHigh: 30.0)
        XCTAssertNil(p1.sameDateLastYear, "2025-04-31 不存在，必须丢弃")

        // 13 月 → 2026-01-01；today 固定 1 月 1 日。
        let month13 = response(dateString: "2025-13-01", tempMax: 25.0)
        let p2 = ClimateProfileMapper.map(month13, calendar: calendar,
                                          today: today(year: 2027, month: 1, day: 1),
                                          currentYearHigh: 30.0)
        XCTAssertNil(p2.sameDateLastYear, "2025-13-01 的 13 月不存在，必须丢弃")

        // 平年 2 月 29 日（2025 非闰年）→ 2025-03-01；today 固定 3 月 1 日。
        let feb29 = response(dateString: "2025-02-29", tempMax: 25.0)
        let p3 = ClimateProfileMapper.map(feb29, calendar: calendar,
                                          today: today(year: 2026, month: 3, day: 1),
                                          currentYearHigh: 30.0)
        XCTAssertNil(p3.sameDateLastYear, "2025 是平年，2 月 29 日不存在，必须丢弃")
    }

    /// 合法闰日仍须通过（防止修过头把真实数据也拦掉）。
    /// `today` 必须是**闰年**的 2 月 29 日，否则 today 自己就会被归一化成 3 月 1 日
    /// （2026 / 2025 / 2027 均非闰年）—— 故取 2028（闰年）。
    func testLeapDayInLeapYearStillAccepted() {
        let dto = response(dateString: "2024-02-29", tempMax: 25.0)
        let profile = ClimateProfileMapper.map(dto, calendar: calendar,
                                               today: today(year: 2028, month: 2, day: 29),
                                               currentYearHigh: 30.0)
        XCTAssertEqual(profile.sameDateLastYear?.year, 2024,
                       "2024 是闰年，2 月 29 日是真实日期，必须保留")
    }
}

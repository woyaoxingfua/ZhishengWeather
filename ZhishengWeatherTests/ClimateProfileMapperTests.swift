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
    /// ⚠️ 依据修正（2026-10-07）：本注释此前称「Python 复刻确认 `2025-02-30`
    /// → `2025-03-02`，datetime 与 Calendar.date(from:) 归一化规则同构」——
    /// **该说法不成立**。实测 Python `datetime.date(2025, 2, 30)` 抛
    /// `ValueError: day is out of range for month`，**从不归一化**；Python 与
    /// Swift `Calendar` 在这一点上**并不同构**。故归一化一侧的依据只有仓库既有
    /// Swift 实测记录（`ISOTimeStringDecoderTests` CI run12 / `NmcIssueTimeDecoder`
    /// CI 失败值），Python 只能证明「拒绝」这一侧可实现。
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
    /// 归一化产物分别为 `2025-05-01` / `2026-01-01` / `2025-03-01`，
    /// 后两者归一化后**月/日都变了**，故这里把 today 固定成 1 月 1 日 / 3 月 1 日
    /// 以覆盖各自形态。
    /// ⚠️ 归一化行为依据 = 仓库既有 Swift 实测记录，**非 Python 复刻**
    /// （Python 对这些输入一律 ValueError，不归一化）。
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

    /// 合法闰日必须被**接受**（防止修过头把真实数据也拦掉）。
    ///
    /// 🔴 **2026-10-07 修正**：本测试此前断言的是
    /// `XCTAssertEqual(profile.sameDateLastYear?.year, 2024)`，**该断言在结构上
    /// 永不可满足**，与「校验过严」无关：
    /// - `:58` 的 `lastYear` 定义是 `sorted.last { $0.year == currentYear - 1 }`
    ///   （字面语义「去年今日」）。today = 2028-02-29 ⇒ `currentYear == 2028`
    ///   ⇒ 它去找 `year == 2027`，而 **2027 是平年、2027-02-29 在日历上不存在**，
    ///   本 fixture 只含 `"2024-02-29"` 一行 ⇒ 必然取不到 ⇒ nil。
    /// - 反过来要让 `lastYear == 2024`，须 `currentYear - 1 == 2024` ⇒
    ///   `currentYear == 2025`；但 2025 是平年，today 必被 Foundation 归一化成
    ///   `2025-03-01` ⇒ `targetMonth/targetDay` 变成 3/1，而 `"2024-02-29"` 是
    ///   2/29 ⇒ `:42-43` 的月/日比对不成立 ⇒ 该行被 `continue` 掉。
    /// - 两头夹逼 ⇒ **不存在任何 `today` 取值**能让旧断言成立。
    ///
    /// 正确落点是 `sameDateLast5Years` / `sameDateLast10Years`：today = 2028-02-29 时
    /// `currentYear == 2028`，2024 落在近 5/10 年窗口内（>= 2023 / >= 2018），
    /// 是真实闰日就该出现在那里。**日期校验器本身完全没问题，未做任何放宽。**
    func testLeapDayInLeapYearStillAccepted() {
        let dto = response(dateString: "2024-02-29", tempMax: 25.0)
        // today 必须是**闰年**的 2 月 29 日，否则 today 自己就会被归一化成 3 月 1 日
        // （2026 / 2025 / 2027 均非闰年）—— 故取 2028（闰年）。
        let profile = ClimateProfileMapper.map(dto, calendar: calendar,
                                               today: today(year: 2028, month: 2, day: 29),
                                               currentYearHigh: 30.0)

        XCTAssertEqual((profile.sameDateLast5Years ?? []).map(\.year), [2024],
                       "2024 是闰年，2 月 29 日是真实日期，必须保留在近 5 年窗口")
        XCTAssertEqual((profile.sameDateLast10Years ?? []).map(\.year), [2024],
                       "2024 是闰年，2 月 29 日是真实日期，必须保留在近 10 年窗口")
        XCTAssertEqual((profile.sameDateLast5Years ?? []).first?.tempMax, 25.0)
        XCTAssertEqual(profile.fiveYearAverageHigh, 25.0)

        // 「去年今日」在 2/29 这天**结构性为 nil**：去年（2027）没有 2 月 29 日。
        // 这是字面语义的正确结果，不是校验过严；UI 侧 ClimateProfileView 对此有 nil 兜底。
        XCTAssertNil(profile.sameDateLastYear,
                     "today=2028-02-29 时，去年 2027-02-29 不存在，lastYear 必为 nil")
    }

    // MARK: - 闰年规则全矩阵（世纪闰年是闰年规则里最易写错的一条）

    /// 闰年判定 = `y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)`。
    ///
    /// ⚠️ 用 `sameDateLast10Years`（`year >= currentYear - 10`）而不是 `last5` 作观测点，
    /// 且调用方**必须**保证 `inputYear` 落在该窗口内 —— 否则「日期不存在导致被丢弃」
    /// 与「年份压根不在窗口里」两种原因无法区分，测试就成了永绿的假阴性
    /// （1900 用 today=2008 时就踩过这个坑：`1900 < 1998`，怎么写都false）。
    private func acceptedByValidation(_ dateString: String,
                                      inputYear: Int,
                                      todayYear: Int) -> Bool {
        // 用 XCTAssert 而非 precondition：后者在 CI 上直接 crash，读不出失败原因。
        XCTAssertGreaterThanOrEqual(inputYear, todayYear - 10,
                                    "inputYear 必须落在近 10 年窗口内，否则本 helper 无法区分「被拒」与「不在窗口」")
        XCTAssertLessThan(inputYear, todayYear, "inputYear 必须早于今年（今年当年被 :45 排除）")
        let dto = response(dateString: dateString, tempMax: 25.0)
        let profile = ClimateProfileMapper.map(dto, calendar: calendar,
                                               today: today(year: todayYear, month: 2, day: 29),
                                               currentYearHigh: 30.0)
        return profile.sameDateLast10Years?.contains { $0.year == inputYear } ?? false
    }

    /// ✅ 世纪闰年必须被接受：**2000 % 400 == 0** ⇒ 闰年 ⇒ 2000-02-29 真实存在。
    /// 若校验写成 `y % 4 == 0`（世纪年一律当平年）或 `y % 100 != 0 && y % 4 == 0`，
    /// 这条就会红 —— 它正是「2000 接受 / 1900 拒绝」要防的那类写错。
    func testCenturyLeapYear2000Accepted() {
        XCTAssertTrue(acceptedByValidation("2000-02-29", inputYear: 2000, todayYear: 2004),
                      "2000 能被 400 整除，是闰年，2000-02-29 是真实日期，必须接受")
    }

    /// ❌ 世纪非闰年必须被拒绝：**1900 % 100 == 0 但 1900 % 400 != 0** ⇒ 平年
    /// ⇒ 1900-02-29 不存在。若校验只写 `y % 4 == 0` 就会误收这条。
    /// `todayYear = 1904`（闰年，且 `1900 >= 1904 - 10` 保证 1900 在窗口内）。
    func testCenturyNonLeapYear1900Rejected() {
        XCTAssertFalse(acceptedByValidation("1900-02-29", inputYear: 1900, todayYear: 1904),
                       "1900 能被 100 整除但不能被 400 整除，是平年，1900-02-29 不存在，必须拒绝")
    }

    /// ❌ 平年 2 月 29 日必须被拒绝（2026 非闰年），且**不得**被归一化成 3 月 1 日后混入。
    func testCommonYearFebruary29Rejected() {
        let dto = response(dateString: "2026-02-29", tempMax: 25.0)
        let profile = ClimateProfileMapper.map(dto, calendar: calendar,
                                               today: today(year: 2028, month: 2, day: 29),
                                               currentYearHigh: 30.0)
        XCTAssertFalse((profile.sameDateLast5Years ?? []).contains { $0.year == 2026 },
                       "2026 是平年，2026-02-29 不存在，绝不得进入档案")
        XCTAssertFalse((profile.sameDateLast10Years ?? []).contains { $0.year == 2026 })
        XCTAssertNil(profile.fiveYearAverageHigh,
                     "被拒绝的日期不得污染近 5 年均值")
        XCTAssertNil(profile.tenYearAverageHigh,
                     "被拒绝的日期不得污染近 10 年均值")
    }

    /// 真实存在但「不是 2/29」的边界日期必须**照常接受** ——
    /// 防止「修过头」变成把 31 日、平年 2 月最后一天一并拒掉。
    /// 2027 年的今天与输入同日同月，2026 年那一行必须命中「去年今日」。
    func testValidEndOfMonthDatesStillAccepted() {
        for (dateString, inputYear) in [("2026-02-28", 2026),
                                        ("2026-01-31", 2026),
                                        ("2026-06-15", 2026)] {
            let parts = dateString.split(separator: "-").compactMap { Int($0) }
            let month = parts[1]
            let day = parts[2]
            let dto = response(dateString: dateString, tempMax: 25.0)
            let profile = ClimateProfileMapper.map(dto, calendar: calendar,
                                                   today: today(year: inputYear + 1, month: month, day: day),
                                                   currentYearHigh: 30.0)
            XCTAssertEqual(profile.sameDateLastYear?.year, inputYear,
                           "\(dateString) 是真实日期，\(inputYear + 1) 年的同月同日必须命中去年今日")
            XCTAssertEqual(profile.sameDateLastYear?.tempMax, 25.0)
        }
    }
}

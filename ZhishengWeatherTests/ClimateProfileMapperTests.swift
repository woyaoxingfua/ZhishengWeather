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
}

//
//  ClimateProfileMapper.swift
//  Core / Networking  [App + Widget 共用]
//
//  Open-Meteo Archive DTO → 个人气候档案领域模型。
//  从一次宽范围 archive 响应中，按“同月同日”过滤出去年 / 近 5 年 / 近 10 年记录。
//  今年数据由调用方传入（来自 forecast 主链路），不参与 archive 请求。
//
//  Core 纪律：仅 import Foundation；纯函数；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 气候档案映射器（纯函数）。
enum ClimateProfileMapper {

    /// 将 Archive 响应映射为气候档案。
    /// - Parameters:
    ///   - response: Open-Meteo Archive 原始响应。
    ///   - calendar: 用于解析日期与提取月/日的城市本地日历（由调用方注入，避免 Core 内部 Date()）。
    ///   - today: 今天的绝对时刻。
    ///   - currentYearHigh: 今年今日最高温（来自主天气链路）；nil 时不计算差值。
    /// - Returns: 完整气候档案（缺失年份以空数组 / nil 表示，绝不崩溃）。
    static func map(_ response: ArchiveResponse,
                    calendar: Calendar,
                    today: Date,
                    currentYearHigh: Double?) -> ClimateProfile {
        guard let daily = response.daily, let times = daily.time, !times.isEmpty else {
            return ClimateProfile()
        }

        let todayComponents = calendar.dateComponents([.month, .day], from: today)
        guard let targetMonth = todayComponents.month, let targetDay = todayComponents.day else {
            return ClimateProfile()
        }
        let currentYear = calendar.component(.year, from: today)

        var snapshots: [DailyClimateSnapshot] = []
        for (index, dateString) in times.enumerated() {
            guard let date = Self.date(from: dateString, calendar: calendar) else { continue }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard components.month == targetMonth,
                  components.day == targetDay,
                  let year = components.year,
                  year < currentYear else { continue }

            let snapshot = DailyClimateSnapshot(
                year: year,
                dateString: dateString,
                tempMax: Self.optionalDouble(daily.temperature_2m_max, at: index),
                tempMin: Self.optionalDouble(daily.temperature_2m_min, at: index),
                weatherCode: Self.optionalInt(daily.weather_code, at: index)
            )
            snapshots.append(snapshot)
        }

        let sorted = snapshots.sorted { $0.year < $1.year }
        let lastYear = sorted.last { $0.year == currentYear - 1 }
        let last5 = sorted.filter { $0.year >= currentYear - 5 }
        let last10 = sorted.filter { $0.year >= currentYear - 10 }

        let fiveAvg = Self.averageHigh(last5)
        let tenAvg = Self.averageHigh(last10)

        return ClimateProfile(
            sameDateLastYear: lastYear,
            sameDateLast5Years: last5,
            sameDateLast10Years: last10,
            fiveYearAverageHigh: fiveAvg,
            tenYearAverageHigh: tenAvg,
            fiveYearHighDelta: Self.delta(average: fiveAvg, currentYearHigh: currentYearHigh),
            tenYearHighDelta: Self.delta(average: tenAvg, currentYearHigh: currentYearHigh)
        )
    }

    // MARK: - Private

    private static func optionalDouble(_ array: [Double?]?, at index: Int) -> Double? {
        guard let array, index >= 0, index < array.count else { return nil }
        return array[index]
    }

    private static func optionalInt(_ array: [Int?]?, at index: Int) -> Int? {
        guard let array, index >= 0, index < array.count else { return nil }
        return array[index]
    }

    /// 将 "yyyy-MM-dd" 按 calendar 的时区解析为 Date；格式不符返回 nil。
    private static func date(from dateString: String, calendar: Calendar) -> Date? {
        let parts = dateString.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.timeZone = calendar.timeZone
        return calendar.date(from: components)
    }

    private static func averageHigh(_ snapshots: [DailyClimateSnapshot]) -> Double? {
        let values = snapshots.compactMap(\.tempMax)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func delta(average: Double?, currentYearHigh: Double?) -> Double? {
        guard let average, let currentYearHigh else { return nil }
        return average - currentYearHigh
    }
}

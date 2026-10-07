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

    /// 将 "yyyy-MM-dd" 按 calendar 的时区解析为 Date；格式不符**或分量非法**返回 nil。
    ///
    /// 🔴 **必须显式校验**（2026-10-07 普查发现，与已修的 `NmcIssueTimeDecoder`同型）：
    /// 旧实现把合法性**委托**给 `calendar.date(from:)`。**那不行** ——
    /// Foundation 的 `Calendar.date(from:)` 对越界分量**不做校验、按自然溢出归一化
    /// 并返回非 nil**（2 月 30 日 → 3 月 2 日、13 月 → 次年 1 月）。
    /// 而调用侧 `:41-45` 的回读只比对**月/日/年**、且要求「等于今日月/日」，
    /// 于是 `"2025-02-30"` 在**今日为 3 月 2 日**时会被归一化成 `2025-03-02`
    /// 并**通过全部 guard**，作为一条**凭空编造的**历史同日快照进入
    /// `sameDateLastYear` / 五年 / 十年均值 —— 形态完全合法、不触发任何兜底、
    /// 无人能察觉。故此处采用与 `NmcIssueTimeDecoder` 相同的两招：
    /// **范围 guard** + **回读自证**（后者一次性覆盖「范围合法但日历上不存在」，
    /// 只查 `1...31` 拦不住，而逐日查 `range(of:.day,in:.month)` 又需先造日期（自举））。
    /// ⚠️ 依据 = 仓库既有实测记录（`ISOTimeStringDecoderTests` CI run12 /
    /// `NmcIssueTimeDecoder` CI 失败值）+ Python 复算**验证闰年规则本身**，
    /// **未在 Swift 上实跑**。
    /// 📌 依据修正（2026-10-07）：本注释此前称「Python 复刻确认归一化规则同构」
    /// ——**不成立**。实测 Python `datetime` 对越界日一律抛 `ValueError`、从不归一化，
    /// 与 `Calendar.date(from:)` **并不同构**。归一化一侧只能依据 Swift 实测记录；
    /// Python 仅能证明「拒绝」这一侧可实现、以及 2000 接受 / 1900 拒绝的闰年规则。
    ///
    /// ✅ 本函数对**真实闰日**（2024-02-29 / 2000-02-29）是**接受**的，
    /// 无需任何放宽：范围 guard 放行 2 与 29，且 2 月 29 日在闰年经`Calendar`
    /// 构造后回读分量不变 ⇒ 通过。已被 `ClimateProfileMapperTests` 固化。
    private static func date(from dateString: String, calendar: Calendar) -> Date? {
        let parts = dateString.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        guard (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }

        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.timeZone = calendar.timeZone
        guard let date = calendar.date(from: components) else { return nil }

        // 回读自证：Calendar 一旦做过任何归一化（2 月 30 日 / 4 月 31 日 /
        // 平年 2 月 29 日），回读分量就与输入不等 ⇒ 判 nil。
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == parts[0],
              roundTrip.month == parts[1],
              roundTrip.day == parts[2] else {
            return nil
        }
        return date
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

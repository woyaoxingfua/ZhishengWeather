//
//  OpenMeteoMapper.swift
//  Core / Networking  [App + Widget 共用]
//
//  纯函数：Open-Meteo DTO → WeatherSnapshot。
//  职责：数组长度对齐、按 now 截窗（≤12 条）、daily 高低温填充与回退、
//        F-A 逐日映射（§2.5 装配规则）、空值兜底。
//
//  约束（跨层纪律 §7.3 / 团队硬约束 ⑤）：
//  - 禁止内部调用 `Date()`；`now` 必须由参数传入，保证可测。
//    （注：ARCH §3.1 的签名未含 `now`，与 §7.3「now 注入」冲突；
//      此处按 §7.3 与团队裁定取 `now: Date` 参数版本。）
//

import Foundation

/// DTO → 领域模型映射器（纯函数）。
enum OpenMeteoMapper {

    /// 截取的逐小时条数上限。
    static let maxHourlyCount = 12

    /// F-A：逐日条数上限（服务端最多取 7 天，UI 侧再自行裁剪为 3/7）。
    static let maxDailyCount = 7

    /// 将原始响应映射为领域快照。
    /// - Parameters:
    ///   - response: 解码后的 DTO。
    ///   - location: 查询位置（由上层传入，含城市名）。
    ///   - now: 当前时刻，用于逐小时截窗与 `fetchedAt`。
    /// - Returns: 领域快照；字段缺失/长度不齐时安全兜底，不崩溃。
    static func map(_ response: OpenMeteoResponse, location: LocationInfo, now: Date) -> WeatherSnapshot {
        let current = response.current
        let hourly = response.hourly

        // ── 1. 对齐三个并行数组的最小长度，逐点构造 ──────────────────────
        let alignedCount = min(hourly.time.count,
                               min(hourly.temperature_2m.count, hourly.weather_code.count))
        var points: [HourlyPoint] = []
        if alignedCount > 0 {
            points.reserveCapacity(alignedCount)
            for index in 0..<alignedCount {
                let point = HourlyPoint(
                    time: Date(timeIntervalSince1970: TimeInterval(hourly.time[index])),
                    temperature: hourly.temperature_2m[index],
                    weatherCode: hourly.weather_code[index]
                )
                points.append(point)
            }
        }

        // ── 2. 按 now 截窗：从"当前小时"起取 ≤ maxHourlyCount 条 ──────────
        let windowPoints = window(from: points, now: now)

        // ── 3. 当日高/低温：优先 daily 第 0 项，否则回退 hourly 窗口 ───────
        //（现有回退逻辑一字不改 —— F-A 装配规则 §2.5 明确要求）
        let fallbackHigh = windowPoints.map(\.temperature).max() ?? current.temperature_2m
        let fallbackLow = windowPoints.map(\.temperature).min() ?? current.temperature_2m

        let dailyHigh = response.daily?.temperature_2m_max.first ?? fallbackHigh
        let dailyLow = response.daily?.temperature_2m_min.first ?? fallbackLow

        // ── 4. F-A 逐日装配（快照装配规则写死，避免实现歧义）──────────────
        //  response.daily == nil → snapshot.daily = nil（AC-A7 的数据源头）；
        //  response.daily != nil → snapshot.daily = dailyForecasts(...)
        //  （可能是空数组，如服务端返回空 / 数组不齐）。
        let dailyList: [DailyForecast]?
        if let dailyBlock = response.daily {
            dailyList = dailyForecasts(from: dailyBlock)
        } else {
            dailyList = nil
        }

        // ── 5. 组装快照 ─────────────────────────────────────────────────
        return WeatherSnapshot(
            location: location,
            temperature: current.temperature_2m,
            apparentTemperature: current.apparent_temperature,
            weatherCode: current.weather_code,
            windSpeed: current.wind_speed_10m,
            windDirection: current.wind_direction_10m,
            humidity: current.relative_humidity_2m,
            isDay: current.is_day == 1,
            hourly: windowPoints,
            dailyHigh: dailyHigh,
            dailyLow: dailyLow,
            daily: dailyList,
            fetchedAt: now
        )
    }

    // MARK: - Private

    /// 从"当前小时"起截取 ≤ maxHourlyCount 条逐小时点。
    /// 取最后一个 `time <= now` 的点作为起点（即当前小时）；若不存在则从头开始。
    private static func window(from points: [HourlyPoint], now: Date) -> [HourlyPoint] {
        guard !points.isEmpty else { return [] }

        let startIndex: Int
        if let lastNotAfterNow = points.lastIndex(where: { $0.time <= now }) {
            startIndex = lastNotAfterNow
        } else {
            startIndex = 0
        }

        let slice = points[startIndex...]
        return Array(slice.prefix(maxHourlyCount))
    }

    /// 五并行数组 → [DailyForecast]（F-A 装配规则 §2.5）。
    ///
    /// 对齐规则：
    /// - 必需对齐数组：time / temperature_2m_max / temperature_2m_min / weather_code，
    ///   长度不齐按四者的最短长度截断（AC-A6）；
    ///   `weather_code` 整键缺失按**空数组**参与对齐 → 逐日为空 → 区块隐藏，
    ///   不显示脏数据；
    /// - `precipitation_probability_max`：整体缺失 → 每行 nil；
    ///   元素 null / 越界 → 该行 nil（AC-A5：绝不把「未知」当 0）。
    ///
    /// - Parameter daily: DTO 逐日块（调用方已保证非 nil）。
    /// - Returns: 逐日领域点数组；对齐后无有效行时为空数组。
    private static func dailyForecasts(from daily: OpenMeteoResponse.Daily) -> [DailyForecast] {
        // weather_code 整键缺失 → 空数组参与对齐（结果必然为空，区块隐藏）。
        let weatherCodes = daily.weather_code ?? []
        let precipitations = daily.precipitation_probability_max

        let alignedCount = min(daily.time.count,
                               min(daily.temperature_2m_max.count,
                                   min(daily.temperature_2m_min.count, weatherCodes.count)))
        guard alignedCount > 0 else { return [] }

        var forecasts: [DailyForecast] = []
        forecasts.reserveCapacity(min(alignedCount, maxDailyCount))
        for index in 0..<alignedCount {
            // precip 整键缺失 → nil；元素越界 → nil；元素 null → nil（[Int?] 原生表达）。
            var precipitation: Int?
            if let precipitations, index < precipitations.count {
                precipitation = precipitations[index]
            } else {
                precipitation = nil
            }

            forecasts.append(DailyForecast(
                date: Date(timeIntervalSince1970: TimeInterval(daily.time[index])),
                weatherCode: weatherCodes[index],
                tempMax: daily.temperature_2m_max[index],
                tempMin: daily.temperature_2m_min[index],
                precipitationProbability: precipitation
            ))
        }
        return Array(forecasts.prefix(maxDailyCount))
    }
}

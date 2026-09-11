//
//  OpenMeteoMapper.swift
//  Core / Networking  [App + Widget 共用]
//
//  纯函数：Open-Meteo DTO → WeatherSnapshot。
//  职责：数组长度对齐、按 now 截窗（≤24 条）、daily 高低温填充与回退、
//        F-A 逐日映射（§2.5 装配规则）、空值兜底。
//
//  v1.1 修订（A1，ARCH-A1 §1.1–§1.5）：
//    - maxHourlyCount 12→24（A1-2，截窗逻辑零改动）；
//    - maxDailyCount 7→16（A1-3，对齐 forecast_days=16，UI 侧再裁剪）；
//    - ★ todayIndex 定位（本批最高静默回归风险，§1.5）：past_days=1 使
//      daily[0] 变"昨天"，dailyHigh/dailyLow 取值从 `.first` 改 `[todayIndex]`；
//      **daily 输出自今日起截**（snapshot.daily[0] 恒为今天，§3 关键点 3），
//      下游（逐日区块 / Widget Large prefix(3) / A2 摘要）对位移无感知；
//    - pressureMSL = pressure_msl ?? surface_pressure（一次回退定值）；
//    - sunrise/sunset 经 ISOTimeStringDecoder（offset 时区）解码注入；
//    - yesterday = todayIndex-1 行（<0 → nil）。
//  `now` 注入纪律不变（跨层纪律 §7.3 / 团队硬约束 ⑤）。
//
//  约束（跨层纪律 §7.3 / 团队硬约束 ⑤）：
//  - 禁止内部调用 `Date()`；`now` 必须由参数传入，保证可测。
//    （注：ARCH §3.1 的签名未含 `now`，与 §7.3「now 注入」冲突；
//      此处按 §7.3 与团队裁定取 `now: Date` 参数版本。）
//


import Foundation

/// DTO → 领域模型映射器（纯函数）。
enum OpenMeteoMapper {

    /// 截取的逐小时条数上限（A1-2：12 → 24）。
    static let maxHourlyCount = 24

    /// 逐日条数上限（A1-3：7 → 16，对齐 forecast_days=16；UI 侧再自行裁剪 3/7/15）。
    static let maxDailyCount = 16

    /// 将原始响应映射为领域快照。
    /// - Parameters:
    ///   - response: 解码后的 DTO。
    ///   - location: 查询位置（由上层传入，含城市名）。
    ///   - now: 当前时刻，用于逐小时截窗、todayIndex 定位与 `fetchedAt`。
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

        // ── 3. 今日高/低温：取 daily 今日索引行，否则回退 hourly 窗口 ─────
        //（回退链逐字保留 —— F-A 装配规则 §2.5 明确要求；
        //  A1 变更：取值行由 `.first` 改为今日索引行，§1.5 最高风险点）
        let fallbackHigh = windowPoints.map(\.temperature).max() ?? current.temperature_2m
        let fallbackLow = windowPoints.map(\.temperature).min() ?? current.temperature_2m

        // 今日索引：nil = daily 缺失 / 无效行；先给 safeIndex 兜底，
        // 再配合每日数组各自的前置 guard 实现逐字段独立回退。
        let todayIndex = self.todayIndex(in: response.daily, utcOffsetSeconds: response.utc_offset_seconds, now: now)

        var dailyHigh = fallbackHigh
        var dailyLow = fallbackLow
        if let dailyBlock = response.daily,
           let index = todayIndex,
           index < dailyBlock.temperature_2m_max.count {
            dailyHigh = dailyBlock.temperature_2m_max[index]
        }
        if let dailyBlock = response.daily,
           let index = todayIndex,
           index < dailyBlock.temperature_2m_min.count {
            dailyLow = dailyBlock.temperature_2m_min[index]
        }

        // ── 4. A1-1：气压 msl→surface 一次回退定值（ARCH-A1 §1.1）────────
        let pressureMSL = current.pressure_msl ?? current.surface_pressure

        // ── 5. F-A / A1 逐日装配 ────────────────────────────────────────
        //  response.daily == nil → snapshot.daily = nil（AC-A7 的数据源头）；
        //  response.daily != nil → dailyForecasts(...)（**自今日起截**，§3 关键点 3），
        //  可能是空数组（服务端返回空 / 数组不齐）。
        var dailyList: [DailyForecast]?
        var yesterday: DailyForecast?
        var sunrise: Date?
        var sunset: Date?
        if let dailyBlock = response.daily {
            dailyList = dailyForecasts(from: dailyBlock,
                                       utcOffsetSeconds: response.utc_offset_seconds,
                                       startIndex: todayIndex ?? 0)
            // A1-5：昨日 = 今日索引 - 1 行（<0 / 越界 → nil，整行隐藏 AC-A1-16）。
            if let index = todayIndex, index >= 1 {
                yesterday = yesterdayForecast(from: dailyBlock,
                                              utcOffsetSeconds: response.utc_offset_seconds,
                                              index: index - 1)
            }
            // A1-4：今日日出/日落（字符串经独立解码器；坏串 → nil → UI 隐藏该段）。
            if let index = todayIndex {
                sunrise = decodedSunTime(from: dailyBlock.sunrise, at: index,
                                         utcOffsetSeconds: response.utc_offset_seconds)
                sunset = decodedSunTime(from: dailyBlock.sunset, at: index,
                                        utcOffsetSeconds: response.utc_offset_seconds)
            }
        }

        // ── 6. 组装快照 ─────────────────────────────────────────────────
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
            pressureMSL: pressureMSL,
            sunrise: sunrise,
            sunset: sunset,
            yesterday: yesterday,
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

    /// ★ 定位 daily 数组中的"今日"索引（A1 最高风险点，ARCH-A1 §1.5）。
    ///
    /// 原理：`daily.time[i]` = 当地当日 00:00 epoch 秒；本地日序号
    /// `dayNumber(x) = floor((x.epoch + utcOffset) / 86400)` 对"同一当地自然日"
    /// 恒等（无需解析日期字符串，纯整数运算，无时区/DST 可控面）。
    /// 取首个 `dayNumber(daily.time[i]) == dayNumber(now)` 的下标。
    ///
    /// 回退链：找不到（时钟漂移/请求边界）→ `min(1, count-1)`（默认假定
    /// past_days=1 时第 1 行是今天）→ 仍不可用 → 0。
    ///
    /// - Parameters:
    ///   - daily: DTO 逐日块；nil → nil（上游按回退链取值）。
    ///   - utcOffsetSeconds: 同响应根级时区偏移（秒）。
    ///   - now: 当前时刻（注入，纪律同 map）。
    /// - Returns: 今日下标；daily 缺失或 time 数组为空时 nil。
    private static func todayIndex(in daily: OpenMeteoResponse.Daily?,
                                   utcOffsetSeconds: Int,
                                   now: Date) -> Int? {
        guard let daily, !daily.time.isEmpty else { return nil }

        let nowDayNumber = Self.dayNumber(of: now.timeIntervalSince1970,
                                          utcOffsetSeconds: utcOffsetSeconds)
        if let index = daily.time.firstIndex(where: { epoch in
            Self.dayNumber(of: TimeInterval(epoch), utcOffsetSeconds: utcOffsetSeconds) == nowDayNumber
        }) {
            return index
        }
        // 时钟漂移 / 边界兜底：past_days=1 下默认第 1 行是今天；单行数组 → 0。
        return min(1, daily.time.count - 1)
    }

    /// 本地日序号（ARCH-A1 §1.5 定义）：`floor((epoch + utcOffset) / 86400)`。
    /// 同一当地自然日的任意时刻在该函数下取值相等。
    private static func dayNumber(of epoch: TimeInterval, utcOffsetSeconds: Int) -> Int {
        Int(((epoch + TimeInterval(utcOffsetSeconds)) / 86_400).rounded(.down))
    }

    /// 五并行数组 → [DailyForecast]（F-A 装配规则 §2.5 + A1 位移裁定 §3 关键点 3）。
    ///
    /// 对齐规则：
    /// - 必需对齐数组：time / temperature_2m_max / temperature_2m_min / weather_code，
    ///   长度不齐按四者的最短长度截断（AC-A6）；
    ///   `weather_code` 整键缺失按**空数组**参与对齐 → 逐日为空 → 区块隐藏，
    ///   不显示脏数据；
    /// - `precipitation_probability_max`：整体缺失 → 每行 nil；
    ///   元素 null / 越界 → 该行 nil（AC-A5：绝不把「未知」当 0）；
    /// - `sunrise`/`sunset`：整键缺失 → 全行 nil；元素 null / 坏串 → 该行 nil
    ///   （经 ISOTimeStringDecoder，与 epoch 解码路径隔离）。
    ///
    /// **A1 位移裁定（§3 关键点 3，必守）**：输出**从 `startIndex`（今日）起截**，
    /// 保证「snapshot.daily[0] 恒为今天」的全仓既有语义不变——否则逐日区块、
    /// Widget Large `prefix(3)`、A2 摘要全部要逐个适配位移。
    ///
    /// - Parameters:
    ///   - daily: DTO 逐日块（调用方已保证非 nil）。
    ///   - utcOffsetSeconds: 同响应根级时区偏移（秒）。
    ///   - startIndex: 今日下标（由 `todayIndex` 定位）。
    /// - Returns: 自今日起的逐日领域点数组；对齐后无有效行时为空数组。
    private static func dailyForecasts(from daily: OpenMeteoResponse.Daily,
                                       utcOffsetSeconds: Int,
                                       startIndex: Int) -> [DailyForecast] {
        // weather_code 整键缺失 → 空数组参与对齐（结果必然为空，区块隐藏）。
        let weatherCodes = daily.weather_code ?? []
        let precipitations = daily.precipitation_probability_max

        let alignedCount = min(daily.time.count,
                               min(daily.temperature_2m_max.count,
                                   min(daily.temperature_2m_min.count, weatherCodes.count)))
        guard alignedCount > 0 else { return [] }

        // 今日索引钳入对齐区间（todayIndex 不会越过 alignedCount-1 太远，
        // 但对齐截断可能小于原始 time.count —— 防越界，钳到最后一行）。
        let clampedStart = min(max(startIndex, 0), alignedCount - 1)

        var forecasts: [DailyForecast] = []
        forecasts.reserveCapacity(min(alignedCount - clampedStart, maxDailyCount))
        for index in clampedStart..<alignedCount {
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
                precipitationProbability: precipitation,
                sunrise: decodedSunTime(from: daily.sunrise, at: index, utcOffsetSeconds: utcOffsetSeconds),
                sunset: decodedSunTime(from: daily.sunset, at: index, utcOffsetSeconds: utcOffsetSeconds)
            ))
        }
        return Array(forecasts.prefix(maxDailyCount))
    }

    /// 提取昨日行（A1-5）：按今日索引 - 1 的下标，走与 `dailyForecasts`
    /// 完全相同的对齐与可选字段规则；任何缺失 → nil（UI 整行隐藏，AC-A1-16）。
    ///
    /// - Parameters:
    ///   - daily: DTO 逐日块（调用方已保证非 nil）。
    ///   - utcOffsetSeconds: 同响应根级时区偏移（秒）。
    ///   - index: 昨日下标（= 今日索引 - 1，调用方保证 ≥ 0）。
    /// - Returns: 昨日领域点；对齐后越界（如 weather_code 缺键对齐截断）→ nil。
    private static func yesterdayForecast(from daily: OpenMeteoResponse.Daily,
                                          utcOffsetSeconds: Int,
                                          index: Int) -> DailyForecast? {
        let weatherCodes = daily.weather_code ?? []
        let alignedCount = min(daily.time.count,
                               min(daily.temperature_2m_max.count,
                                   min(daily.temperature_2m_min.count, weatherCodes.count)))
        guard index < alignedCount else { return nil }

        var precipitation: Int?
        if let precipitations = daily.precipitation_probability_max, index < precipitations.count {
            precipitation = precipitations[index]
        }

        return DailyForecast(
            date: Date(timeIntervalSince1970: TimeInterval(daily.time[index])),
            weatherCode: weatherCodes[index],
            tempMax: daily.temperature_2m_max[index],
            tempMin: daily.temperature_2m_min[index],
            precipitationProbability: precipitation,
            sunrise: decodedSunTime(from: daily.sunrise, at: index, utcOffsetSeconds: utcOffsetSeconds),
            sunset: decodedSunTime(from: daily.sunset, at: index, utcOffsetSeconds: utcOffsetSeconds)
        )
    }

    /// 从 DTO 的 sunrise/sunset 字符串数组中解码指定行的绝对时刻。
    /// 唯一调用 `ISOTimeStringDecoder` 的位置（字符串不出 Networking 层，铁律 4）。
    ///
    /// - Parameters:
    ///   - times: DTO 字符串数组（整键缺失为 nil）。
    ///   - index: 行下标；越界 / 元素 null / 坏串 → nil。
    ///   - utcOffsetSeconds: 同响应根级时区偏移（秒）。
    /// - Returns: 解析结果；任何缺失路径均 nil（UI 隐藏对应段，不冒充）。
    private static func decodedSunTime(from times: [String?]?,
                                       at index: Int,
                                       utcOffsetSeconds: Int) -> Date? {
        guard let times, index < times.count, let string = times[index] else { return nil }
        return ISOTimeStringDecoder.date(from: string, utcOffsetSeconds: utcOffsetSeconds)
    }
}

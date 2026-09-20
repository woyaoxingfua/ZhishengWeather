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
//    - sunrise/sunset 经 FlexibleTime 双态归一（epoch 直译 / ISO 走
//      ISOTimeStringDecoder）后注入；
//    - yesterday = todayIndex-1 行（<0 → nil）。
//  `now` 注入纪律不变（跨层纪律 §7.3 / 团队硬约束 ⑤）。
//
//  v1.4 修订（B1-2 短时降水）：新增 `minutelyWindow`（自当前 15 分钟窗起截 ≤ 8 条），
//  无有效点 → snapshot.minutely15 = nil（整卡隐藏）。实况/逐时/逐日映射逻辑零改动。
//
//  v1.6 修订（null 容忍 · 真机崩溃修复）：DTO 的 hourly.temperature_2m /
//    weather_code 与 daily.temperature_2m_max / _min / weather_code 改为
//    **元素可选**后，本层按"缺值就跳过、绝不编造"消费：
//    - 逐小时循环：温度或现象码任一为 null → 该下标不构造 HourlyPoint；
//    - dailyHigh/dailyLow：今日行元素为 null → 保留既有回退链（hourly 窗口 → current）；
//    - 逐日行 / 昨日行：weather_code / tempMax / tempMin 任一为 null →
//      逐日整行丢弃、昨日返回 nil。
//    背景（真机，北京，forecast_days=16 + past_days=1）：hourly 下标 399..407
//    与 daily 下标 16 为 null —— 这是 Open-Meteo 允许的截断日空值，不是接口变更。
//
//  v1.7 修订（P2 数据补全，用户诉求"补全数据吧"）：把新增的实况 / 逐时 / 逐日本体字段
//  从 DTO 映射到领域模型（映射纪律同 v1.6「缺值就跳过、绝不编造」）：
//    - 实况 four 降水键 + uv_index → WeatherSnapshot 对应可选字段；四降水键全 nil 时
//      各自为 nil，UI 整格隐藏，绝不合成 0.0；
//    - 逐时 precipitation / wind_speed_10m / wind_gusts_10m / apparent_temperature →
//      经既有 `optionalDouble(_:at:)` 安全下标（nil / 越界 / 元素 null 一律 nil），
//      元素为 0 的合法值原样保留、不转 nil；
//    - 逐日 10 个新增字段 → DailyForecast（昨日在 `yesterdayForecast` 同款搬运）；
//    - daylight_duration / sunshine_duration 原值是**秒**，本层原样透传（换算归 UI）；
//      snowfall / snowfall_sum 单位 cm，同样透传。
//  所有换算遵守既有风格；Core 层纪律：仅 import Foundation，禁 UIKit / 禁 Date() 直取 /
//  禁 try! / 禁 fatalError。
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

    /// 短时降水条数上限（B1-2：8×15min=2h）。
    static let maxMinutelyCount = 8

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
        // 长度对齐规则不变（v1.0 起）；v1.6 新增"行内 null 跳过"：
        // 温度或现象码任一为 null → 该下标**整点跳过**，不构造 HourlyPoint。
        // 理由：领域模型 HourlyPoint.temperature / weatherCode 是非可选
        // Double / Int，补 0 / 复用上一小时都会把编造值画进逐时折线图；
        // 而"少几个小时"只是尾部截断，用户看不出、也不会被误导。
        let alignedCount = min(hourly.time.count,
                               min(hourly.temperature_2m.count, hourly.weather_code.count))
        var points: [HourlyPoint] = []
        if alignedCount > 0 {
            points.reserveCapacity(alignedCount)
            for index in 0..<alignedCount {
                guard let temperature = hourly.temperature_2m[index],
                      let weatherCode = hourly.weather_code[index] else {
                    continue
                }
                let point = HourlyPoint(
                    time: Date(timeIntervalSince1970: TimeInterval(hourly.time[index])),
                    temperature: temperature,
                    weatherCode: weatherCode,
                    // ⚠️ 哑火线修复（P2 复盘）：本行此前**漏传** `precipitationProbability`，
                    // 而该属性有默认值 `nil`，于是**编译通过、静默失效**：
                    //   · `HourlyStrip` 的逐时概率行恒显示 "--"（D-A1 整条形同虚设）；
                    //   · `WeatherSummaryEngine.rainSummary` 的输入恒为 nil → 摘要永不触发。
                    // 经 git 史核对：**P2 之前那版同样漏传**，故这不是 P2 的回归，
                    // 而是 A2-2 上线时就存在的哑火线（字段/请求/模型都齐，唯独 mapper 没接）。
                    // 纪律：新增可选字段时，**必须**核对 mapper 是否真的赋值 ——
                    // 有默认值的属性不会因漏传而编译失败，只能靠"接线的单测"兜住。
                    precipitationProbability: optionalDouble(hourly.precipitation_probability,
                                                             at: index),
                    // P2 数据补全：逐时新增四字段均为可选，元素 null → nil，绝不补 0
                    //（0 是合法降水/风速值，原样保留；只有 null 才转 nil，AC-A5）。
                    precipitation: optionalDouble(hourly.precipitation, at: index),
                    windSpeed: optionalDouble(hourly.wind_speed_10m, at: index),
                    windGusts: optionalDouble(hourly.wind_gusts_10m, at: index),
                    apparentTemperature: optionalDouble(hourly.apparent_temperature, at: index)
                )
                points.append(point)
            }
        }

        // ── 2. 按 now 截窗：从"当前小时"起取 ≤ maxHourlyCount 条 ──────────
        let windowPoints = window(from: points, now: now)

        // ── 2b. B1-2 短时降水：自"当前 15 分钟窗"起取 ≤ maxMinutelyCount 条 ──
        //  空结果 → nil（短时降水卡整卡隐藏，AC-B1-9）。
        let minutelyRaw = minutelyWindow(from: response.minutely_15, now: now)
        let minutely: [MinutelyPrecipitationPoint]? = minutelyRaw.isEmpty ? nil : minutelyRaw

        // ── 3. 今日高/低温：取 daily 今日索引行，否则回退 hourly 窗口 ─────
        //（回退链逐字保留 —— F-A 装配规则 §2.5 明确要求；
        //  A1 变更：取值行由 `.first` 改为今日索引行，§1.5 最高风险点）
        let fallbackHigh = windowPoints.map(\.temperature).max() ?? current.temperature_2m
        let fallbackLow = windowPoints.map(\.temperature).min() ?? current.temperature_2m

        // 今日索引：nil = daily 缺失 / 无效行；先给 safeIndex 兜底，
        // 再配合每日数组各自的前置 guard 实现逐字段独立回退。
        let todayIndex = self.todayIndex(in: response.daily, utcOffsetSeconds: response.utc_offset_seconds, now: now)

        // v1.6：DTO 元素为 `[Double?]` —— 今日行元素为 null（截断日）时
        // **不写 dailyHigh / dailyLow**，即保留上面的回退链（hourly 窗口 → current）。
        // 越界 guard 原样保留。
        var dailyHigh = fallbackHigh
        var dailyLow = fallbackLow
        if let dailyBlock = response.daily,
           let index = todayIndex,
           index < dailyBlock.temperature_2m_max.count,
           let value = dailyBlock.temperature_2m_max[index] {
            dailyHigh = value
        }
        if let dailyBlock = response.daily,
           let index = todayIndex,
           index < dailyBlock.temperature_2m_min.count,
           let value = dailyBlock.temperature_2m_min[index] {
            dailyLow = value
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
            // A1-4：今日日出/日落（run37 起双态容忍；nil → UI 隐藏该段）。
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
            // B1 遥测补全：实况四字段透传（nil 原样保留 → UI 显示 "--"，不冒充 0）。
            visibility: current.visibility,
            dewPoint: current.dew_point_2m,
            cloudCover: current.cloud_cover,
            windGusts: current.wind_gusts_10m,
            fetchedAt: now,
            // P2 数据补全：实况降水本体 + UV。四降水键（precipitation / rain / showers /
            // snowfall）任一为 nil 时各自为 nil；四者全 nil → UI 整格隐藏，绝不合成 0.0。
            // `uvIndex` 为实况值，与 `DailyForecast.uvIndexMax`（当日峰值）分标签（见模型注释）。
            // snowfall 单位为 cm（Open-Meteo 原值，透传，换算归 UI）。
            precipitation: current.precipitation,
            rain: current.rain,
            showers: current.showers,
            snowfall: current.snowfall,
            uvIndex: current.uv_index,
            minutely15: minutely
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

    /// B1-2：自"当前 15 分钟窗"起截取 ≤ maxMinutelyCount 条短时降水点。
    ///
    /// 与逐小时窗口同款规则：取最后一个 `time <= now` 的点作为起点（即当前窗）；
    /// 若不存在则从头开始。真机实测（杭州）：请求 `forecast_minutely_15=8` 时返回
    /// 恰好 8 条、自当前 15 分钟窗起，本窗口即全量；仍显式截窗以对服务端默认行为免疫。
    ///
    /// 缺失处理：块缺失 / time 为空 → 空数组（上游转 nil → 整卡隐藏）；
    /// 某下标降水缺值 / 元素 null → 记 0（该 15 分钟无降水记录）；概率缺值 → nil（不冒充 0）。
    ///
    /// - Parameters:
    ///   - block: DTO 短时降水块；nil → 空数组。
    ///   - now: 当前时刻（注入，纪律同 map）。
    /// - Returns: 自当前窗起的短时降水点数组（长度 ≤ maxMinutelyCount）。
    private static func minutelyWindow(from block: OpenMeteoResponse.Minutely15?,
                                       now: Date) -> [MinutelyPrecipitationPoint] {
        guard let block, !block.time.isEmpty else { return [] }

        let times = block.time
        let startIndex: Int
        if let lastNotAfterNow = times.lastIndex(where: {
            Date(timeIntervalSince1970: TimeInterval($0)) <= now
        }) {
            startIndex = lastNotAfterNow
        } else {
            startIndex = 0
        }

        let precipitations = block.precipitation ?? []
        let probabilities = block.precipitation_probability ?? []

        var result: [MinutelyPrecipitationPoint] = []
        result.reserveCapacity(maxMinutelyCount)
        var index = startIndex
        while index < times.count, result.count < maxMinutelyCount {
            let precipitation = index < precipitations.count ? (precipitations[index] ?? 0) : 0
            let probability: Double? = index < probabilities.count ? probabilities[index] : nil
            result.append(MinutelyPrecipitationPoint(
                time: Date(timeIntervalSince1970: TimeInterval(times[index])),
                precipitation: precipitation,
                probability: probability
            ))
            index += 1
        }
        return result
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

    /// 可选 Double 数组的安全下标取值（A2-2）：数组为 nil / 越界 / 元素 null → nil。
    /// 可选数组不参与 alignedCount 对齐（服务端未返回时不拖短其他数组），
    /// 逐点取值时以下标判断兜底（ARCH-A2 §1.3）。
    private static func optionalDouble(_ array: [Double?]?, at index: Int) -> Double? {
        guard let array, index < array.count else { return nil }
        return array[index]
    }

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
    /// - **行级 null 跳过（v1.6）**：对齐区间内某行的 weather_code / tempMax /
    ///   tempMin **任一为 null**（真机：forecast_days=16 的截断日，daily 下标 16
    ///   三个字段全 null）→ 该行**整体丢弃**，不补 0、不冒充"晴 / 0°"；
    ///   丢弃是逐行判定的，不会截断其后的有效行；
    /// - `precipitation_probability_max`：整体缺失 → 每行 nil；
    ///   元素 null / 越界 → 该行 nil（AC-A5：绝不把「未知」当 0）；
    /// - `sunrise`/`sunset`：整键缺失 → 全行 nil；元素 null / 坏串 → 该行 nil
    ///   （FlexibleTime 双态：epoch 直译，ISO 走 ISOTimeStringDecoder）。
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
            // v1.6 行级 null 跳过：截断日（真机 daily 下标 16）的 weather_code /
            // tempMax / tempMin 为 null —— 任一为 null 就整行丢弃（AC-A5 纪律）。
            guard let weatherCode = weatherCodes[index],
                  let tempMax = daily.temperature_2m_max[index],
                  let tempMin = daily.temperature_2m_min[index] else {
                continue
            }

            // precip 整键缺失 → nil；元素越界 → nil；元素 null → nil（[Int?] 原生表达）。
            var precipitation: Int?
            if let precipitations, index < precipitations.count {
                precipitation = precipitations[index]
            } else {
                precipitation = nil
            }

            forecasts.append(DailyForecast(
                date: Date(timeIntervalSince1970: TimeInterval(daily.time[index])),
                weatherCode: weatherCode,
                tempMax: tempMax,
                tempMin: tempMin,
                precipitationProbability: precipitation,
                sunrise: decodedSunTime(from: daily.sunrise, at: index, utcOffsetSeconds: utcOffsetSeconds),
                sunset: decodedSunTime(from: daily.sunset, at: index, utcOffsetSeconds: utcOffsetSeconds),
                uvIndexMax: optionalDouble(daily.uv_index_max, at: index),
                // P2 数据补全：逐日新增本体字段，全部可选、元素 null → nil，绝不补 0
                //（`precipitation_sum = 0` 必须保留为 0.0，UI 显示 "0 mm"；只有 null 才 "--"）。
                // daylight_duration / sunshine_duration 单位为**秒**，原样透传（换算归 UI）。
                // snowfall_sum 单位为 cm（Open-Meteo 原值，透传）。
                precipitationSum: optionalDouble(daily.precipitation_sum, at: index),
                rainSum: optionalDouble(daily.rain_sum, at: index),
                snowfallSum: optionalDouble(daily.snowfall_sum, at: index),
                windSpeedMax: optionalDouble(daily.wind_speed_10m_max, at: index),
                windGustsMax: optionalDouble(daily.wind_gusts_10m_max, at: index),
                windDirectionDominant: optionalDouble(daily.wind_direction_10m_dominant, at: index),
                daylightDuration: optionalDouble(daily.daylight_duration, at: index),
                sunshineDuration: optionalDouble(daily.sunshine_duration, at: index),
                apparentTemperatureMax: optionalDouble(daily.apparent_temperature_max, at: index),
                apparentTemperatureMin: optionalDouble(daily.apparent_temperature_min, at: index)
            ))
        }
        return Array(forecasts.prefix(maxDailyCount))
    }

    /// 提取昨日行（A1-5）：按今日索引 - 1 的下标，走与 `dailyForecasts`
    /// 完全相同的对齐与可选字段规则；任何缺失 → nil（UI 整行隐藏，AC-A1-16）。
    ///
    /// v1.6：weather_code / tempMax / tempMin **任一为 null** → 同样返回 nil
    /// （与 `dailyForecasts` 的行级跳过规则一致，不冒充）。
    ///
    /// - Parameters:
    ///   - daily: DTO 逐日块（调用方已保证非 nil）。
    ///   - utcOffsetSeconds: 同响应根级时区偏移（秒）。
    ///   - index: 昨日下标（= 今日索引 - 1，调用方保证 ≥ 0）。
    /// - Returns: 昨日领域点；对齐后越界、或该行任一必需元素为 null → nil。
    private static func yesterdayForecast(from daily: OpenMeteoResponse.Daily,
                                          utcOffsetSeconds: Int,
                                          index: Int) -> DailyForecast? {
        let weatherCodes = daily.weather_code ?? []
        let alignedCount = min(daily.time.count,
                               min(daily.temperature_2m_max.count,
                                   min(daily.temperature_2m_min.count, weatherCodes.count)))
        guard index < alignedCount else { return nil }

        // v1.6：任一必需元素为 null → 整行不给（与 dailyForecasts 同判据）。
        guard let weatherCode = weatherCodes[index],
              let tempMax = daily.temperature_2m_max[index],
              let tempMin = daily.temperature_2m_min[index] else {
            return nil
        }

        var precipitation: Int?
        if let precipitations = daily.precipitation_probability_max, index < precipitations.count {
            precipitation = precipitations[index]
        }

        return DailyForecast(
            date: Date(timeIntervalSince1970: TimeInterval(daily.time[index])),
            weatherCode: weatherCode,
            tempMax: tempMax,
            tempMin: tempMin,
            precipitationProbability: precipitation,
            sunrise: decodedSunTime(from: daily.sunrise, at: index, utcOffsetSeconds: utcOffsetSeconds),
            sunset: decodedSunTime(from: daily.sunset, at: index, utcOffsetSeconds: utcOffsetSeconds),
            uvIndexMax: optionalDouble(daily.uv_index_max, at: index),
            // P2 数据补全：昨日行同样搬运逐日本体字段（可选 + 元素 null → nil）。
            precipitationSum: optionalDouble(daily.precipitation_sum, at: index),
            rainSum: optionalDouble(daily.rain_sum, at: index),
            snowfallSum: optionalDouble(daily.snowfall_sum, at: index),
            windSpeedMax: optionalDouble(daily.wind_speed_10m_max, at: index),
            windGustsMax: optionalDouble(daily.wind_gusts_10m_max, at: index),
            windDirectionDominant: optionalDouble(daily.wind_direction_10m_dominant, at: index),
            daylightDuration: optionalDouble(daily.daylight_duration, at: index),
            sunshineDuration: optionalDouble(daily.sunshine_duration, at: index),
            apparentTemperatureMax: optionalDouble(daily.apparent_temperature_max, at: index),
            apparentTemperatureMin: optionalDouble(daily.apparent_temperature_min, at: index)
        )
    }

    /// 从 DTO 的 sunrise/sunset 数组中解出指定行的绝对时刻（run37 双态）。
    /// epoch 形态直译 `Date(timeIntervalSince1970:)`；
    /// ISO 形态走 `ISOTimeStringDecoder`（字符串不出 Networking 层）。
    ///
    /// - Parameters:
    ///   - times: DTO 字符串数组（整键缺失为 nil）。
    ///   - index: 行下标；越界 / 元素 null / 坏串 → nil。
    ///   - utcOffsetSeconds: 同响应根级时区偏移（秒）。
    /// - Returns: 解析结果；任何缺失路径均 nil（UI 隐藏对应段，不冒充）。
    private static func decodedSunTime(from times: [FlexibleTime?]?,
                                       at index: Int,
                                       utcOffsetSeconds: Int) -> Date? {
        guard let times, index < times.count, let flex = times[index] else { return nil }
        switch flex {
        case .epoch(let seconds):
            // run37 修正：timeformat=unixtime 下实测 API 返回 epoch 数字。
            return Date(timeIntervalSince1970: seconds)
        case .iso(let string):
            // 兼容 ISO 字符串形态（部分部署）。
            return ISOTimeStringDecoder.date(from: string, utcOffsetSeconds: utcOffsetSeconds)
        }
    }
}

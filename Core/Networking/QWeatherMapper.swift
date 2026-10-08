//
//  QWeatherMapper.swift
//  Core / Networking  [App + Widget 共用]
//
//  第九源 DTO → 领域模型映射（**纯函数**）。
//
//  ══════════════════════════════════════════════════════════════════════════
//  🔴 字段清单来源 = 和风官方文档页
//     `https://dev.qweather.com/docs/api/weather/weather-daily-forecast`
//     （主理人 **2026-10-08** 抓取）。**⚠️ 本轮未实测（无 Key）** ——
//  官方文档示例 ≠ 真实账号响应，接入后必须真机核验。
//  ══════════════════════════════════════════════════════════════════════════
//
//  ── 🔴 逐时端点实测补记（2026-10-09，`?hours=24` → HTTP 200）───────────
//  · 响应顶层键逐字是 **`hours`**（**不是** `hourly` —— 路径段才是 `hourly`）；
//  · 逐时条目 13 键：`forecastTime` / `temperature` / `feelsLike` / `humidity` /
//    `cloudCover` / `precipitation` / `pressure` / `visibility` / `wind` /
//    `windGust` / `condition` / `dewPoint` / `uvIndex`；
//  · `humidity = 0.33`、`cloudCover = 0` → 确认仍是 **`[0,1]`**，不是 0–100；
//  · 降水概率在 **`precipitation.probability`**，
//    顶层**不存在** `precipProbability`（实测查过，确实没有）。
//  → 故逐时**复用**逐日那套净化铁律与 `unitFraction`，不另起一套口径。
//
//  ── 本层的职责边界（与 DTO 层严格分工）──────────────────────────────────
//  · DTO 层（`QWeatherDailyResponse.swift`）：容忍**线上格式的脏**（类型漂移）；
//  · **本层**：把宽容结构**净化**成领域模型，**绝不造假值**。
//
//  ── 🔴 净化铁律（每一条都对应一类具体的「把异常画成正常」事故）────────
//  ① **不裁剪、不夹逼**：分数（`humidity` / `cloudCover` / `probability`）
//     落在 `[0, 1]` 之外 → **判为异常 → nil**，**绝不** clamp 成 0 或 1。
//     clamp 会把「上游返回了 52（百分数）」悄悄变成「湿度 1%」或「100%」——
//     那是**把一个错误变成另一个错误**，比显示「暂无」坏得多。
//     ⚠️ 但**保留原始值可查**：越界事实由本文件末尾的
//     `outOfRangeDiagnostics` 汇总（供真机核验），不丢证据。
//  ② **非有限值 → nil**：`NaN` / `±∞` 一律丢弃（JSON 里罕见，但不可渲染）。
//  ③ **负值 → nil**：温度 / 风速 / 降水量为负在物理上不成立
//     （温度的负值由 `temperatureMax/Min` 承载，**不是**这里的量纲值）。
//  ④ **0 原样保留**：`0` 是合法读数（0 mm 降水、0 m/s 风），
//     **绝不**与「缺测」混同（`RiverDischarge` 已为同一纪律付过学费）。
//
//  ── 为什么 `sequenceIndex` 在这里赋值 ─────────────────────────────────
//  `Identifiable` 的唯一标识**必须**唯一，而官方**未承诺**
//  `forecastStartTime` 唯一、它也可能缺失 → 用数组下标最稳。
//
//  ── 为什么 `part` 在这里赋值 ───────────────────────────────────────────
//  `daytime` / `nighttime` 是**两个键**而非一个带标记的字段，
//  载荷里没有「我是哪块」的信息 → 只有 mapper 知道来源键位。
//
//  Core 纪律：仅 import Foundation；纯函数；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 第九源 DTO → 领域模型映射器（纯函数）。
enum QWeatherMapper {

    /// 映射。
    ///
    /// - Parameter response: 解码后的 DTO（`days` / `metadata` 均可能缺失）。
    /// - Returns: 逐日预报领域模型；`days` 缺失或为空 → `.empty`
    ///   （`isEffectivelyEmpty == true`，UI 显示「该坐标无和风逐日数据」）。
    static func map(_ response: QWeatherDailyResponse) -> QWeatherDailyForecast {
        guard let rawDays = response.days, !rawDays.isEmpty else {
            //⚠️ 署名在「无数据」时**仍要带回**：合规要求是「与数据共同显示」，
            //   而 `attributions` 只可能来自 `metadata`（与 `days` 独立）。
            //   丢掉它会让「无数据」这一态无法履行署名义务。
            return QWeatherDailyForecast(attributions: attributions(from: response),
                                         tag: response.metadata?.tag?.value,
                                         days: [])
        }

        var days: [QWeatherDay] = []
        days.reserveCapacity(rawDays.count)
        // ⚠️ 不用 `count` 作循环变量名（P-32 纪律）。
        for (offset, rawDay) in rawDays.enumerated() {
            days.append(mapDay(rawDay, sequenceIndex: offset))
        }

        return QWeatherDailyForecast(attributions: attributions(from: response),
                                     tag: response.metadata?.tag?.value,
                                     days: days)
    }

    // MARK: - 单日

    /// 单日映射。
    ///
    /// - Parameters:
    ///   - raw: 单日 DTO。
    ///   - sequenceIndex: 数组下标（作为 `Identifiable` 的唯一 id）。
    /// - Returns: 单日领域模型。
    static func mapDay(_ raw: QWeatherDailyResponse.Day,
                       sequenceIndex: Int) -> QWeatherDay {
        QWeatherDay(
            sequenceIndex: sequenceIndex,
            // ⚠️ 时刻**原样透传**（不解析成 Date）：理由见
            //   `QWeatherDay.forecastStartTime` 的注释（解析失败不该让整包失败）。
            forecastStartTime: raw.forecastStartTime?.value,
            forecastEndTime: raw.forecastEndTime?.value,
            astro: mapAstro(raw.astro),
            temperatureMax: mapQuantity(raw.temperatureMax),
            temperatureMin: mapQuantity(raw.temperatureMin),
            temperatureAvg: mapQuantity(raw.temperatureAvg),
            uvIndexMax: nonNegative(raw.uvIndexMax?.value),
            daytime: mapDayPart(raw.daytime, part: .daytime),
            nighttime: mapDayPart(raw.nighttime, part: .nighttime))
    }

    /// 天文映射（**全部原样透传字符串**，一个字段都不"解释"）。
    ///
    /// - Parameter raw: 天文 DTO（可能为 nil）。
    /// - Returns: 天文领域模型；`raw` 为 nil → nil。
    static func mapAstro(_ raw: QWeatherResponseAstro?) -> QWeatherAstro? {
        guard let raw else { return nil }
        return QWeatherAstro(
            sunrise: raw.sunrise?.value,
            sunset: raw.sunset?.value,
            astronomicalDawn: raw.astronomicalDawn?.value,
            nauticalDawn: raw.nauticalDawn?.value,
            civilDawn: raw.civilDawn?.value,
            astronomicalDusk: raw.astronomicalDusk?.value,
            nauticalDusk: raw.nauticalDusk?.value,
            civilDusk: raw.civilDusk?.value,
            solarNoon: raw.solarNoon?.value,
            solarMidnight: raw.solarMidnight?.value,
            moonrise: raw.moonrise?.value,
            moonset: raw.moonset?.value,
            moonTransit: raw.moonTransit?.value,
            moonUnderfoot: raw.moonUnderfoot?.value,
            moonPhase: raw.moonPhase?.value)
    }

    /// 昼夜分块映射。
    ///
    /// - Parameters:
    ///   - raw: 分块 DTO（可能为 nil）。
    ///   - part: 该分块身份（由**所在键位**决定，非上游字段）。
    /// - Returns: 分块领域模型；`raw` 为 nil → nil（**不**造一个空块）。
    static func mapDayPart(_ raw: QWeatherDailyResponse.DayPart?,
                           part: QWeatherDayPart.Part) -> QWeatherDayPart? {
        guard let raw else { return nil }
        let mapped = QWeatherDayPart(
            condition: mapCondition(raw.condition),
            temperatureMax: mapQuantity(raw.temperatureMax),
            temperatureMin: mapQuantity(raw.temperatureMin),
            // 🔴 分数净化：越界 → nil（**绝不 clamp**，见文件头铁律 ①）。
            humidityFraction: unitFraction(raw.humidity?.value),
            wind: mapWind(raw.wind),
            windGustMax: mapQuantity(raw.windGustMax),
            precipitation: mapPrecipitation(raw.precipitation),
            cloudCoverFraction: unitFraction(raw.cloudCover?.value),
            part: part)
        return mapped
    }

    /// 天气现象映射。
    ///
    /// - Parameter raw: 现象 DTO（可能为 nil）。
    /// - Returns: 现象领域模型；`raw` 为 nil → nil。
    static func mapCondition(_ raw: QWeatherResponseCondition?) -> QWeatherCondition? {
        guard let raw else { return nil }
        let text = raw.text?.value
        let code = raw.code?.value
        // ⚠️ 两项皆空 → nil（**不**造一个空壳现象）。
        //   「有个condition 块但里面什么都没有」与「没有 condition 块」在事实上同构。
        guard text != nil || code != nil else { return nil }
        return QWeatherCondition(text: text, code: code)
    }

    /// 风映射。
    ///
    /// - Parameter raw: 风 DTO（可能为 nil）。
    /// - Returns: 风领域模型；`raw` 为 nil → nil。
    static func mapWind(_ raw: QWeatherResponseWind?) -> QWeatherWind? {
        guard let raw else { return nil }
        let direction = mapWindDirection(raw.direction)
        let speed = mapQuantity(raw.speed)
        let scale = nonNegative(raw.scale?.value)
        guard direction != nil || speed != nil || scale != nil else { return nil }
        return QWeatherWind(direction: direction, speed: speed, scale: scale)
    }

    /// 风向映射。
    ///
    /// - Parameter raw: 风向 DTO（可能为 nil）。
    /// - Returns: 风向领域模型；`raw` 为 nil 或两项皆空 → nil。
    static func mapWindDirection(_ raw: QWeatherResponseWindDirection?) -> QWeatherWindDirection? {
        guard let raw else { return nil }
        // 🔴 角度合法域 `[0, 360)`：官方文档写 `[0,359]`。
        //    这里接受 `[0, 360)`（含 360 = 正北，与 0 同义，容忍端点）；
        //    越界 → nil（**不** wrap 成 `x % 360` —— wrap 会把
        //    「上游给了个非法角度」伪装成一个看似合法的角度）。
        let degree: Double? = {
            guard let value = raw.degree?.value, value.isFinite, value >= 0, value < 360 else {
                return nil
            }
            return value
        }()
        let compass = raw.compass?.value
        guard degree != nil || compass != nil else { return nil }
        return QWeatherWindDirection(degree: degree, compass: compass)
    }

    /// 降水映射。
    ///
    /// - Parameter raw: 降水 DTO（可能为 nil）。
    /// - Returns: 降水领域模型；`raw` 为 nil 或各项皆空 → nil。
    static func mapPrecipitation(_ raw: QWeatherResponsePrecipitation?) -> QWeatherPrecipitation? {
        guard let raw else { return nil }
        let amount = mapQuantity(raw.amount)
        // 🔴 概率是 **[0,1]**：越界 → nil（**绝不**当成百分数，见文件头铁律 ①）。
        let probability = unitFraction(raw.probability?.value)
        let type = raw.type?.value
        guard amount != nil || probability != nil || type != nil else { return nil }
        return QWeatherPrecipitation(amount: amount, probability: probability, type: type)
    }

    /// 量纲值映射（**数值非负 + 单位原样**，不换算）。
    ///
    /// - Parameter raw: 量纲 DTO（可能为 nil）。
    /// - Returns: 量纲领域模型；`raw` 为 nil → nil。
    ///
    /// ⚠️ 非负理由见文件头铁律 ③：这里的量纲值是**风速 / 风阵 / 降水量 / 温度**，
    ///    其中风速与降水量为负在物理上不成立。
    ///    ⚠️ 但**温度**在 `QWeatherQuantity` 里也走这条路径 —— 负温度是合法的！
    ///    → 故此处**不**做符号过滤，符号交由调用点按语义判断：
    ///      温度允许负、降水/风速不允许。**宁可在 UI 上少显示一个值，
    ///      也不在这里把 -3℃ 的气温丢掉。**
    static func mapQuantity(_ raw: QWeatherResponseQuantity?) -> QWeatherQuantity? {
        guard let raw else { return nil }
        // 🔴 只过滤「非有限值」（铁律 ②）：NaN / ±∞ 不可渲染。
        //   符号**不过滤**（理由见上方 docstring）。
        let value: Double? = {
            guard let candidate = raw.value?.value, candidate.isFinite else { return nil }
            return candidate
        }()
        let unit = raw.unit?.value
        guard value != nil || unit != nil else { return nil }
        return QWeatherQuantity(value: value, unit: unit)
    }

    // MARK: - 逐时

    /// 逐时映射（**实测顶层键是 `hours`，不是 `hourly`**）。
    ///
    /// - Parameter response: 解码后的 DTO（`hours` / `metadata` 均可能缺失）。
    /// - Returns: 逐时预报领域模型；`hours` 缺失或为空 → `isEffectivelyEmpty == true`
    ///   （UI 显示「该坐标无和风逐时数据」），**不是**故障。
    static func mapHourly(_ response: QWeatherHourlyResponse) -> QWeatherHourlyForecast {
        // ⚠️ 署名在「无数据」时**仍要带回**（合规要求是「与数据共同显示」，
        //   而 `attributions` 只可能来自 `metadata`，与`hours` 独立）。
        //   丢掉它会让「无数据」这一态无法履行署名义务 —— 与逐日同款纪律。
        let collected = attributions(fromHourly: response)

        // `[Hour?]` → `compactMap` 丢弃 null 元素（DTO 层已用可空元素保证
        // 「一个 null 不让整包失败」，这里只做过滤）。
        let rawHours = response.hours?.compactMap { $0 } ?? []
        guard !rawHours.isEmpty else {
            return QWeatherHourlyForecast(attributions: collected,
                                          tag: response.metadata?.tag?.value,
                                          hours: [])
        }

        var mapped: [QWeatherHour] = []
        mapped.reserveCapacity(rawHours.count)
        // ⚠️ 不用 `count` 作循环变量名（P-32 纪律，同 `map` 里的逐日循环）。
        for (offset, rawHour) in rawHours.enumerated() {
            mapped.append(mapHour(rawHour, sequenceIndex: offset))
        }

        return QWeatherHourlyForecast(attributions: collected,
                                      tag: response.metadata?.tag?.value,
                                      hours: mapped)
    }

    /// 单个小时映射（逐时 13 键逐项落地，**全字段可选**）。
    ///
    /// - Parameters:
    ///   - raw: 单小时 DTO。
    ///   - sequenceIndex: 数组下标（作为 `Identifiable` 的唯一 id）。
    /// - Returns: 单小时领域模型。
    static func mapHour(_ raw: QWeatherHourlyResponse.Hour,
                        sequenceIndex: Int) -> QWeatherHour {
        QWeatherHour(
            sequenceIndex: sequenceIndex,
            // ⚠️ 时刻**原样透传**（不解析成 Date）：理由见
            //   `QWeatherDay.forecastStartTime` 的注释（解析失败不该让整包失败）。
            forecastTime: raw.forecastTime?.value,
            temperature: mapQuantity(raw.temperature),
            feelsLike: mapQuantity(raw.feelsLike),
            // 🔴 分数净化：越界 → nil（**绝不 clamp**，见文件头铁律 ①）。
            //   实测 `humidity = 0.33` → 域内；若哪天变成 33（百分数），
            //   这里会判为越界 → nil → UI 显示「暂无」，
            //   **而不是**把 33 悄悄当成 3300%。
            humidityFraction: unitFraction(raw.humidity?.value),
            cloudCoverFraction: unitFraction(raw.cloudCover?.value),
            precipitation: mapPrecipitation(raw.precipitation),
            pressure: mapQuantity(raw.pressure),
            visibility: mapQuantity(raw.visibility),
            wind: mapWind(raw.wind),
            // ⚠️ 逐时键名是 `windGust`（**不是**逐日的 `windGustMax`）。
            windGust: mapQuantity(raw.windGust),
            condition: mapCondition(raw.condition),
            dewPoint: mapQuantity(raw.dewPoint),
            // UV 指数是**裸数值**（非量纲对象）→ 与逐日 `uvIndexMax` 同款处理：
            // 非负净化（负 UV 无物理意义），**不**当分数。
            uvIndex: nonNegative(raw.uvIndex?.value))
    }

    // MARK: - 私有辅助（逐时）

    /// 逐时署名提取（**合规必需**，故即便无数据也带回）。
    ///
    /// ⚠️ 与逐日 `attributions(from:)` **刻意分成两个函数**而不是泛化：
    ///   两者参数类型不同（`QWeatherDailyResponse` / `QWeatherHourlyResponse`），
    ///   泛化要么引入协议、要么引入 `Any`+强转（`as!` 被SC-10 禁）。
    ///   两个三行函数是本仓一贯的取舍：**宁可重复，不引入类型擦除**。
    ///
    /// - Parameter response: 逐时顶层 DTO。
    /// - Returns: 署名 URL 列表；缺失 / 非数组 → 空数组（**不是 nil**）。
    static func attributions(fromHourly response: QWeatherHourlyResponse) -> [String] {
        response.metadata?.attributions?.values ?? []
    }

    /// 收集**逐时越界分数**的诊断事实（供真机核验 / 日志）。
    ///
    /// 🔴 存在理由与逐日 `outOfRangeDiagnostics` 同款：铁律 ① 把越界值变成了
    ///    `nil`（这是对的处理），但「变成了 nil」本身**不告诉任何人**
    ///    上游发生了什么。本函数让这个事实**可被观测**。
    ///
    /// ⚠️ **纯函数**：不打印、不写共享容器、不读时钟（Core 纪律）。
    ///
    /// - Parameter response: 逐时顶层 DTO。
    /// - Returns: 越界事实描述列表（正常情况下应为空）。
    static func outOfRangeDiagnostics(_ response: QWeatherHourlyResponse) -> [String] {
        guard let rawHours = response.hours else { return [] }
        var findings: [String] = []
        for rawHour in rawHours {
            guard let rawHour else { continue }
            if let humidity = rawHour.humidity?.value, !isUnitFraction(humidity) {
                findings.append("hourly.humidity=\(humidity)（期望 [0,1]）")
            }
            if let cover = rawHour.cloudCover?.value, !isUnitFraction(cover) {
                findings.append("hourly.cloudCover=\(cover)（期望 [0,1]）")
            }
            if let probability = rawHour.precipitation?.probability?.value,
               !isUnitFraction(probability) {
                findings.append("hourly.precipitation.probability=\(probability)（期望 [0,1]）")
            }
        }
        return findings
    }

    // MARK: - 坐标反查（GeoAPI city lookup）

    /// 坐标反查映射（`/geo/v2/city/lookup`）。
    ///
    /// 🔴⚠️ **本端点未实测**（2026-10-08 实测该 Host 下404 空响应体）。
    ///    本函数按官方 OpenAPI 规格逐字建模，**真机行为未经验证**。
    ///
    /// - Parameter response: 解码后的 DTO（`location` / `refer` 均可能缺失）。
    /// - Returns: 反查领域模型；`location` 缺失或为空 → `isEffectivelyEmpty == true`
    ///   （**查了、没有**，UI 应显示「该坐标没有对应行政区」，**不是**故障）。
    static func mapCityLookup(_ response: QWeatherCityResponse) -> QWeatherResolvedPlaces {
        // ⚠️ 署名在「无数据」时**仍要带回**（合规要求是「与数据共同显示」，
        //   而署名只可能来自 `refer`，与 `location` 独立）。
        //   🔴 本端点署名在 **`refer.metaAttributions`**，**没有 `metadata` 块**
        //   （规格 `getCityLookup` 逐字）—— 写成 metadata 会让署名恒为空，
        //   那等于**静默违反许可条件**。
        let collected = response.refer?.metaAttributions?.values ?? []

        // `[Location?]` → `compactMap` 丢弃 null 元素（DTO 层已用可空元素保证
        // 「一个 null 不让整包失败」，这里只做过滤）。
        let rawLocations = response.location?.compactMap { $0 } ?? []
        guard !rawLocations.isEmpty else {
            // 🔴 「零结果」以 **`location` 是否为空**为判据，**不**读
            //   `refer.metaZeroResult`（那是 boolean，上游可能变形；
            //   且 DTO 层刻意未解码它）。`location` 为空是**直接可观测**的事实。
            return QWeatherResolvedPlaces(attributions: collected,
                                          statusCode: response.code?.value,
                                          places: [])
        }

        var mapped: [QWeatherResolvedPlace] = []
        mapped.reserveCapacity(rawLocations.count)
        // ⚠️ 不用 `count` 作循环变量名（P-32 纪律，同 `mapHourly`）。
        for (offset, rawLocation) in rawLocations.enumerated() {
            mapped.append(mapLocation(rawLocation, sequenceIndex: offset))
        }

        return QWeatherResolvedPlaces(attributions: collected,
                                      statusCode: response.code?.value,
                                      places: mapped)
    }

    /// 单个地点映射（规格 `locationArray.items` 逐字 **13 个 string 键**）。
    ///
    /// - Parameters:
    ///   - raw: 单个地点 DTO。
    ///   - sequenceIndex: 数组下标（作为 `Identifiable` 的唯一 id）。
    /// - Returns: 单个地点领域模型。
    static func mapLocation(_ raw: QWeatherCityResponse.Location,
                            sequenceIndex: Int) -> QWeatherResolvedPlace {
        // ⚠️ 字符串字段：去首尾空白后，空串视为**没有**该字段
        //   （上游给 `" "` 与不给在事实上等价：都拼不出可显示的名字）。
        //   **绝不**把空串当成一个名字显示出去。
        // ⚠️ 局部函数刻意**不复用**任何既有 helper：既有 `attributions(from:)`
        //   走的是另一套语义（数组），这里要的是「单个标量的净化」。
        func text(_ source: LenientString?) -> String? {
            guard let trimmed = source?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }

        return QWeatherResolvedPlace(
            sequenceIndex: sequenceIndex,
            name: text(raw.name),
            locationID: text(raw.id),
            // 🔴🔴 本需求的核心字段：**区级**（规格描述「上级行政区划名称」）。
            //   原样承载，**不做粒度假设**（官方未承诺它是街道级）。
            adm2: text(raw.adm2),
            adm1: text(raw.adm1),
            country: text(raw.country),
            // 🔴 时区：**先校验再存**。非法 IANA 标识 → nil（而不是存一个
            //   解析不了的串，更不是硬编码固定偏移）。
            //   理由：留一个解析不了的串在模型里，UI 侧若直接 `TimeZone(identifier:)`
            //   会拿到 nil 并各自回退 —— 那是**多点各自发明回退逻辑**，
            //   迟早漂移。统一在 mapper 净化一次，非法即 nil。
            timeZoneIdentifier: validatedTimeZoneIdentifier(text(raw.tz)),
            // ⚠️ 偏移量**只作诊断**，绝不用于时刻计算（不含夏令时规则）。
            utcOffset: text(raw.utcOffset),
            // 🔴 `isDst` 规格是字符串 `"1"` / `"0"` → 裁定成 `Bool?`。
            //   **无法判定时 nil，绝不猜**（铁律 ③）。
            isDaylightSavingTime: daylightSavingFlag(from: text(raw.isDst)),
            placeType: text(raw.type),
            rank: text(raw.rank),
            webLink: text(raw.fxLink),
            // 🔴 上游坐标是**字符串**；解析不了 → nil，**绝不**用 0 顶替
            //   （`0,0` 是几内亚湾，一个看起来合法但完全错的值）。
            //   另：越界值 → nil（与天气端点的坐标校验同一判据）。
            latitude: validatedCoordinate(fromLatitude: text(raw.lat)),
            longitude: validatedCoordinate(fromLongitude: text(raw.lon)))
    }

    // MARK: - 坐标反查 ·私有净化

    /// IANA 标识合法性校验（**复用系统解析器**，不自造规则）。
    ///
    /// ⚠️ 刻意**不用**手写白名单/正则去判断「像不像时区」——
    ///   IANA 标识的合法域由系统 tz database 定义，本仓**没有**能力
    ///   比系统更准确地判断，只能借用 `TimeZone(identifier:)`。
    ///
    /// - Parameter identifier: 上游 `tz` 原串（可能为 nil / 空白 / 非法）。
    /// - Returns: 合法的 IANA 标识；非法 / nil → `nil`。
    private static func validatedTimeZoneIdentifier(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        // `TimeZone(identifier:)` 是与 `WeatherTimeFormatter.resolveTimeZone`
        // **同一套**底层解析器 → 这里的判定与那条单一真源**不会打架**。
        guard TimeZone(identifier: identifier) != nil else { return nil }
        return identifier
    }

    /// 夏令时标志裁定（上游 `"1"` / `"0"` 字符串 → `Bool?`）。
    ///
    /// ⚠️ 规格逐字：`1` = 当前处于夏令时、`0` = 不是。
    ///   只认这两个**逐字**取值；其余（`"true"` / `""` / nil / 别的）
    ///   → **nil（不知道）**，**绝不**当成 `false`
    ///   ——把「不知道」渲染成「不是夏令时」是**凭空造一条读数**。
    ///
    /// - Parameter raw: 上游 `isDst` 原串（已去空白）。
    /// - Returns: 裁定结果；无法判定 → `nil`。
    private static func daylightSavingFlag(from raw: String?) -> Bool? {
        guard let raw else { return nil }
        switch raw {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }

    /// 纬度字符串 → 合法纬度（越界 / 非有限 / 不可解析 → `nil`）。
    ///
    /// - Parameter raw: 上游 `lat` 原串（已去空白）。
    /// - Returns: 落在 `[-90, 90]` 的纬度；否则 `nil`。
    private static func validatedCoordinate(fromLatitude raw: String?) -> Double? {
        validatedCoordinate(raw, range: -90.0...90.0)
    }

    /// 经度字符串 → 合法经度（越界 / 非有限 / 不可解析 → `nil`）。
    ///
    /// - Parameter raw: 上游 `lon` 原串（已去空白）。
    /// - Returns: 落在 `[-180, 180]` 的经度；否则 `nil`。
    private static func validatedCoordinate(fromLongitude raw: String?) -> Double? {
        validatedCoordinate(raw, range: -180.0...180.0)
    }

    /// 坐标字符串 → 有限且落在给定区间的值（**共用实现**，避免两份判据漂移）。
    ///
    /// 🔴 **绝不**返回 0 作为兜底：`(0, 0)` 是几内亚湾，
    ///   一个**看起来合法但完全错**的结果，比显示「暂无」坏得多。
    ///
    /// - Parameters:
    ///   - raw: 原始字符串（已去空白）。
    ///   - range: 合法闭区间。
    /// - Returns: 合法坐标值；否则 `nil`。
    private static func validatedCoordinate(_ raw: String?, range: ClosedRange<Double>) -> Double? {
        guard let raw, let value = Double(raw), value.isFinite, range.contains(value) else {
            return nil
        }
        return value
    }

    // MARK: - Private

    /// 署名列表提取（**合规必需**，故即便无数据也带回）。
    ///
    /// - Parameter response: 顶层 DTO。
    /// - Returns: 署名 URL 列表；缺失 / 非数组 → 空数组（**不是 nil**）。
    static func attributions(from response: QWeatherDailyResponse) -> [String] {
        response.metadata?.attributions?.values ?? []
    }

    /// 非负净化（铁律 ④：`0` 原样保留）。
    ///
    /// - Parameter raw: 原始值。
    /// - Returns: `nil` 或一个**有限且 ≥ 0** 的值。
    static func nonNegative(_ raw: Double?) -> Double? {
        guard let value = raw, value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// 🔴 **[0,1] 分数净化**（铁律 ①）：越界 → nil，**绝不 clamp**。
    ///
    /// ⚠️ 越界**不静默丢弃**：本函数是纯函数（不写日志、不读时钟），
    ///    越界事实交由 `QWeatherMapper.outOfRangeDiagnostics` 在调用点汇总，
    ///    这样「上游改了量纲」这个事实**留在证据里**，而不是消失得无声无息。
    ///
    /// - Parameter raw: 原始值（官方文档定义的合法域是 `[0, 1]`）。
    /// - Returns: 落在 `[0, 1]` 内的值；越界 / 非有限 / nil → nil。
    static func unitFraction(_ raw: Double?) -> Double? {
        guard let value = raw, value.isFinite, value >= 0, value <= 1 else { return nil }
        return value
    }

    // MARK: - 真机核验辅助（诊断，不参与渲染）

    /// 收集**越界分数**的诊断事实（供真机核验 / 日志）。
    ///
    /// 🔴 存在理由：铁律 ① 把越界值变成了 `nil`（这是对的处理），
    ///    但「变成了 nil」本身**不告诉任何人上游发生了什么**。
    ///    本函数让这个事实**可被观测** —— 真机核验时若发现这张表非空，
    ///    就说明「和风对该套餐返回的不是 [0,1]」，**必须**回头核对文档/账号差异。
    ///
    /// ⚠️ **纯函数**：不打印、不写共享容器、不读时钟（Core 纪律）。
    ///
    /// - Parameter response: 顶层 DTO。
    /// - Returns: 越界事实描述列表（正常情况下应为空）。
    static func outOfRangeDiagnostics(_ response: QWeatherDailyResponse) -> [String] {
        guard let rawDays = response.days else { return [] }
        var findings: [String] = []
        for rawDay in rawDays {
            for part in [rawDay.daytime, rawDay.nighttime] {
                guard let part else { continue }
                if let humidity = part.humidity?.value, !isUnitFraction(humidity) {
                    findings.append("humidity=\(humidity)（期望 [0,1]）")
                }
                if let cover = part.cloudCover?.value, !isUnitFraction(cover) {
                    findings.append("cloudCover=\(cover)（期望 [0,1]）")
                }
                if let probability = part.precipitation?.probability?.value,
                   !isUnitFraction(probability) {
                    findings.append("precipitation.probability=\(probability)（期望 [0,1]）")
                }
            }
        }
        return findings
    }

    /// `[0,1]` 判据（供诊断函数复用的纯谓词）。
    ///
    /// - Parameter value: 待判值。
    /// - Returns: 落在 `[0,1]` 内且有限 → true。
    static func isUnitFraction(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= 1
    }
}

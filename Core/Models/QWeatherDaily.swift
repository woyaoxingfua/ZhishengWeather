//
//  QWeatherDaily.swift
//  Core / Models  [App + Widget 共用]
//
//  第九源「和风天气」（QWeather）逐日预报**领域模型**。
//
//  ══════════════════════════════════════════════════════════════════════════
//  🔴🔴 字段清单来源 = 和风官方文档页
//     `https://dev.qweather.com/docs/api/weather/weather-daily-forecast`
//     （主理人于 **2026-10-08** 抓取）。
//
//  ⚠️⚠️ **本轮未实测（无 Key）** —— 这是本文件最重要的一句话。
//     · 主理人拿不到和风 Key，**本仓库从未收到过该账号的真实响应**；
//     · 实测 `devapi.qweather.com` → **HTTP 403 Invalid Host**（带 Key 也 403，
//       是主机名问题，不是鉴权问题）；
//     · 官方文档站 `dev.qweather.com/docs/api/` 在抓取机上 **403**（需登录/防爬）。
//  → 因此：**官方文档示例 ≠ 该账号的真实响应**（不同套餐返回字段可能不同）。
//  → **接入后必须真机核验**，逐条比对本文件注释里标「文档如此（未实测）」的字段。
//
//  ══════════════════════════════════════════════════════════════════════════
//  🔴 为什么**每一个字段都是可选**（本任务的核心防线，务必读完再改）
//  ══════════════════════════════════════════════════════════════════════════
//  本仓 P-18 血泪：**Stub 与实现共享同一套假设 → 真机缺陷必然逃逸**。
//  单元测试喂的是「我们写的 fixture」，fixture 又照着「我们读的文档」写——
//  于是「文档与真实响应的差异」这一类缺陷**在测试里天然不可见**。
//  若把字段声明成非可选（`let x: Double`），真实响应里少一个字段
//  → 合成解码器抛 `keyNotFound` → **整包解码失败** → 整个数据源**静默消失**
//  （卡片空白、无任何提示）。这是本仓最坏的失败模式。
//
//  → 故采用**三重防御**：
//     ① 本领域模型**全部字段可选**（`?`）：缺字段 → nil → 该项显示「暂无」；
//     ② 弱类型兜底放在**上游 DTO 层**（`QWeatherDailyResponse.swift` 的
//        `LenientDouble` / `LenientString`）：上游把 `29.94` 写成 `"29.94"`、
//        把 `"305"` 写成 `305` 时也能解出。**宁可宽松，不要整包失败。**
//     ③ mapper 逐项净化（负湿度 / 超 range 的分数一律 → nil，绝不裁剪成假值）。
//
//  ⚠️ 唯一**非可选**的是 `attributions`（`[String]`，默认 `[]`，永不解码失败）。
//
//  ══════════════════════════════════════════════════════════════════════════
//  🔴 量纲纪律（官方文档明确标注，**最容易错的地方**）
//  ══════════════════════════════════════════════════════════════════════════
//  · `humidity` / `cloudCover` / `precipitation.probability` 取值是 **[0, 1]**
//    ——**不是 0–100**！渲染必须 ×100，否则「湿度 0.52%」是错的。
//    字段名刻意带 `Fraction` 后缀，把量纲写进名字（沿用
//    `RiverDischargePoint.cubicMetresPerSecond` 的既有做法）。
//  · `wind.direction.degree` 是 **[0, 359]**（角度，不是 8 方位编号）。
//  · `temperature*.value` 是 **number**（JSON 数值）。⚠️ 本项目其他源的温度字段
//    多为 Int —— **已逐字核对官方示例是 `29.94`（小数）**，故此处用 `Double`。
//  · `wind.scale`（风力等级）是整数档位（官方示例 `2`），与 `speed`（物理量）
//    **不是一回事**，不可互推（档位码定义随源而异，见 `SevenTimerMapper` 教训）。
//
//  ⚠️ `astro.moonPhase` 值域（官方文档逐字，**8 个**，分隔符是连字符）：
//     `new-moon` / `waxing-crescent` / `first-quarter` / `waxing-gibbous`
//     `full-moon` / `waning-gibbous` / `last-quarter` / `waning-crescent`
//  ⚠️ 它与本仓既有 `MoonPhase.Name` 的 rawValue（中文「朔月」等）**不是同一套编码**
//     → 故**不**复用那个类型，只保留原始串 + 一个宽容的中文映射（`moonPhaseText`）。
//
//  ── 与快照的关系 ─────────────────────────────────────────────────────────
//  本模型**不在** `WeatherFieldKey` 域内 → 不进 `WeatherSnapshot` / 共享容器
//  → **Widget 载荷契约零改动**（与 `RiverDischarge` / `MarineConditions` 同处境）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

// MARK: - 量纲值对象

/// 和风的「量纲值」：数值与单位**成对下发**（如 `{"value": 29.94, "unit": "°C"}`）。
///
/// ⚠️ 官方文档如此（**未实测**）。本仓其他源的同类量都是「裸数字 + 单位写在别处」，
/// 这里必须成对 —— 故单列一个类型，**不让调用点把 `value` 当裸数字误用**。
struct QWeatherQuantity: Codable, Equatable, Sendable {

    /// 数值（单位见 `unit`）。nil = 上游未下发**或** mapper 净化丢弃。
    var value: Double?

    /// 单位串（官方示例 `"°C"` / `"m/s"` / `"mm"`）。
    ///
    /// ⚠️ **原样保留，不做任何换算** —— 服务端给什么就是什么
    /// （本仓纪律：换算只在明确的转换点做，且必须留下可核对的代码）。
    var unit: String?
}

// MARK: - 天气现象

/// 天气现象（`condition`）。
///
/// ⚠️ 官方文档如此（**未实测**）：`{"text": "小雨", "code": "305"}`。
struct QWeatherCondition: Codable, Equatable, Sendable {

    /// 现象中文描述（官方示例「小雨」）。**已是中文，不需也不得**再做映射。
    var text: String?

    /// 现象代码（官方示例是**字符串** `"305"`）。
    ///
    /// ⚠️ 这是**和风自有码**，**不是**本仓 `WMOCodeMapper` 用的 WMO 码
    ///    → 绝不可混用（混用会把「小雨」画成另一种天气）。
    var code: String?
}

// MARK: - 风

/// 风向（`wind.direction`）。
///
/// ⚠️ 官方文档如此（**未实测**）：`{"degree": 270, "compass": "w"}`。
struct QWeatherWindDirection: Codable, Equatable, Sendable {

    /// 风向角度（**[0, 359]**）。⚠️ 不是 8 方位编号。
    var degree: Double?

    /// 英文方位缩写（官方示例 `"w"` = west）。**原样保留**（不做八方位转换）。
    var compass: String?
}

/// 风（`wind`）。
///
/// ⚠️ 官方文档如此（**未实测**）。
struct QWeatherWind: Codable, Equatable, Sendable {

    /// 风向。
    var direction: QWeatherWindDirection?

    /// 风速（量纲值，官方示例单位 `"m/s"`）。
    var speed: QWeatherQuantity?

    /// 风力等级（**整数档位**，官方示例 `2`）。见类型注释：与 `speed` 不可互推。
    var scale: Double?
}

// MARK: - 降水

/// 降水（`precipitation`）。
///
/// 🔴 量纲陷阱（官方文档明确，**未实测**）：`probability` 取值 **[0, 1]**，不是 0–100。
struct QWeatherPrecipitation: Codable, Equatable, Sendable {

    /// 降水量（量纲值，官方示例单位 `"mm"`）。
    var amount: QWeatherQuantity?

    /// 降水概率（**[0, 1]** —— 🔴 不是百分数！渲染须 ×100）。
    var probability: Double?

    /// 降水类型（官方示例 `"rain"`）。**原样保留**（值域未在文档中逐字列出，
    /// 故**不**建枚举——枚举会把未知值变成丢数据）。
    var type: String?
}

// MARK: - 昼夜分块

/// 昼夜分块（`daytime` 与 `nighttime` **同构**，官方文档写 `...同构...`）。
///
/// ⚠️ 官方文档如此（**未实测**）——「同构」是文档的**文字描述**，
/// 本轮**未见** `nighttime` 的完整字段清单 → 故**逐字段可选**，
/// 靠 DTO 层的弱类型兜底抗住两侧字段集不一致。
struct QWeatherDayPart: Codable, Equatable, Sendable {

    /// 该分块的天气现象。
    var condition: QWeatherCondition?

    /// 该分块的最高温（量纲值）。
    var temperatureMax: QWeatherQuantity?

    /// 该分块的最低温（量纲值）。
    var temperatureMin: QWeatherQuantity?

    /// 🔴 相对湿度（**[0, 1]** —— 不是 0–100！）。
    var humidityFraction: Double?

    /// 风。
    var wind: QWeatherWind?

    /// 阵风峰值（量纲值，官方示例单位 `"m/s"`）。
    var windGustMax: QWeatherQuantity?

    /// 降水。
    var precipitation: QWeatherPrecipitation?

    /// 🔴 云量（**[0, 1]** —— 不是 0–100！）。
    var cloudCoverFraction: Double?

    /// 区分「白天块」与「夜晚块」的判据（**由 mapper 依所在键位赋值，非上游字段**）。
    ///
    /// ⚠️ 和风用 `daytime` / `nighttime` 两个**键**区分，载荷内**没有**布尔标记。
    ///    放进模型是为了让 UI 不必自己记「我是哪个块」。
    var part: Part?

    /// 分块身份（**本地派生**，非上游字段）。
    enum Part: String, Equatable, Sendable {
        /// 白天块（响应键 `daytime`）。
        case daytime
        /// 夜晚块（响应键 `nighttime`）。
        case nighttime
    }
}

// MARK: - 天文

/// 天文（`astro`）：日出日落、曙暮光、太阳正午、升落月、月相。
///
/// ⚠️ 官方文档如此（**未实测**）。全部时刻都是 **UTC 的 ISO8601 带 Z 串**
///   （官方示例 `"2024-08-11T04:22Z"`）→ 用 `String` **原样承载**，
///   **不**在此处解析成 `Date`：
///   ① Core 纪律禁内部 `Date()`，而正确解析需要偏移上下文；
///   ② 上游若改格式（带偏移 / 改精度），**解析失败不该让整包失败**——
///      保留原始串最诚实（拿不准就原样显示，好过显示错时刻）。
///   → 需要人类可读时刻时由 UI 层按需格式化（见 `QWeatherCard`）。
struct QWeatherAstro: Codable, Equatable, Sendable {

    /// 日出（UTC ISO8601 原始串）。
    var sunrise: String?
    /// 日落（UTC ISO8601 原始串）。
    var sunset: String?
    /// 天文晨光始。
    var astronomicalDawn: String?
    /// 航海晨光始。
    var nauticalDawn: String?
    /// 民用晨光始。
    var civilDawn: String?
    /// 天文暮光终。
    var astronomicalDusk: String?
    /// 航海暮光终。
    var nauticalDusk: String?
    /// 民用暮光终。
    var civilDusk: String?
    /// 太阳正午（`solarNoon`）。
    var solarNoon: String?
    /// 太阳子夜（`solarMidnight`）。
    var solarMidnight: String?
    /// 月出。
    var moonrise: String?
    /// 月落。
    var moonset: String?
    /// 月过中天（`moonTransit`）。
    var moonTransit: String?
    /// 月下中天（`moonUnderfoot`）。
    var moonUnderfoot: String?
    /// 月相（英文连字符串，值域见文件头）。
    var moonPhase: String?

    /// 月相 → 中文（**宽容映射**：未知值返回 nil，**绝不猜**）。
    ///
    /// ⚠️ 为什么不用本仓既有的 `MoonPhase.Name`：它的 rawValue 是中文
    ///   （「朔月」「上弦月」…），与和风的英文连字符串**不是同一套编码**，
    ///   硬转会引入一处「看起来对、实际错位」的映射。
    /// ⚠️ 未知取值 → nil（UI 显示「暂无」）。**宁可空着，也不显示一个可能错误的月相。**
    var moonPhaseText: String? {
        switch moonPhase {
        case "new-moon": return "朔月"
        case "waxing-crescent": return "娥眉月"
        case "first-quarter": return "上弦月"
        case "waxing-gibbous": return "盈凸月"
        case "full-moon": return "满月"
        case "waning-gibbous": return "亏凸月"
        case "last-quarter": return "下弦月"
        case "waning-crescent": return "残月"
        default: return nil
        }
    }
}

// MARK: - 逐日

/// 逐日预报中的一日。
///
/// ⚠️ 官方文档如此（**未实测**）。`forecastStartTime` / `forecastEndTime`
/// 为 UTC ISO8601 原始串（官方示例 `"2024-08-10T22:00Z"`），
/// 理由同 `QWeatherAstro` 的时刻字段。
struct QWeatherDay: Codable, Equatable, Identifiable, Sendable {

    /// 序号（**由 mapper 按数组下标赋值**，非上游字段）。
    ///
    /// ⚠️ 它就是 `Identifiable` 的 `id`，**必须唯一**。
    ///    刻意**不用** `forecastStartTime` 当 id：官方**未承诺**它唯一，
    ///    且它可能缺失 → `ForEach` 拿到重复/全空 id 会静默错渲甚至崩。
    ///    下标由 mapper 保证唯一且确定，是最稳的标识。
    var sequenceIndex: Int

    /// 预报起始时刻（UTC ISO8601 原始串）。
    var forecastStartTime: String?

    /// 预报结束时刻（UTC ISO8601 原始串）。
    var forecastEndTime: String?

    /// 天文。
    var astro: QWeatherAstro?

    /// 当日最高温（量纲值，官方示例 `{"value": 29.94, "unit": "°C"}`）。
    var temperatureMax: QWeatherQuantity?

    /// 当日最低温（量纲值）。
    var temperatureMin: QWeatherQuantity?

    /// 当日均温（量纲值）。
    var temperatureAvg: QWeatherQuantity?

    /// 当日 UV 指数峰值（官方示例 `6`）。
    var uvIndexMax: Double?

    /// 白天分块（响应键 `daytime`）。⚠️ 其 `part` 由 mapper 置为 `.daytime`。
    var daytime: QWeatherDayPart?

    /// 夜晚分块（响应键 `nighttime`）。⚠️ 其 `part` 由 mapper 置为 `.nighttime`。
    var nighttime: QWeatherDayPart?

    /// 稳定标识（= `sequenceIndex`，满足 `Identifiable`）。
    var id: Int { sequenceIndex }
}

// MARK: - 顶层

/// 和风逐日预报（一次 daily 链路的完整领域模型）。
struct QWeatherDailyForecast: Codable, Equatable, Sendable {

    /// 🔴 **署名（合规硬要求，非可选）**。
    ///
    /// 官方文档写明 `metadata.attributions` **必须与当前数据共同显示**。
    /// → 本字段**一路传到 UI 并在卡片上逐条渲染**（见 `QWeatherCard`）。
    /// → 缺省为 `[]`（不是 nil）：**「上游没给署名」与「有署名却没解出来」**
    ///   必须可区分 —— 前者要如实告知"上游未提供署名内容"，后者是缺陷。
    ///   用 nil 会把两者混同成同一件事。
    var attributions: [String]

    /// 响应标签（官方示例 `metadata.tag`）。仅供诊断，UI 不展示。
    var tag: String?

    /// 逐日序列（官方键 `days`）。空数组 = 上游未下发任何一天（→ `.noData`）。
    var days: [QWeatherDay]

    /// **实质无数据**判定：逐日序列为空。
    ///
    /// ⚠️ 判据只问「有没有天」，**不**问「字段填得满不满」——
    ///    一天里字段几乎全缺，**仍是上游下发的一天**，应如实展示
    ///    （各项显示「暂无」）而不是整块隐藏。反之（0 天）才是真的没数据。
    var isEffectivelyEmpty: Bool {
        days.isEmpty
    }

    /// 无任何数据的空值（供 mapper 的「缺块」回落路径使用）。
    static let empty = QWeatherDailyForecast(attributions: [], tag: nil, days: [])
}

//
//  QWeatherHourly.swift
//  Core / Models  [App + Widget 共用]
//
//  第九源「和风天气」（QWeather）逐时预报（hourly）**领域模型**。
//
//  ══════════════════════════════════════════════════════════════════════════
//  ✅ 实测基准：2026-10-09（主理人用真实凭据打通，`?hours=24` → **HTTP 200**）
//实测样本：`humidity = 0.33`、`cloudCover = 0`、
//    `precipitation.probability = 0`、`temperature = {value: 26.01, unit: "°C"}`
//  ══════════════════════════════════════════════════════════════════════════
//
//  ── 🔴 为什么**逐时**要另立模型，而不是复用 `QWeatherDay` ────────────────
//  两者字段集**几乎不重叠**：逐日是「高低温 + 昼夜分块 + 天文」，
//  逐时是「温度 / 体感 / 湿度 / 云量 / 降水 / 气压 / 能见度 / 风 / 阵风 /
//  现象 / 露点 / UV」，**逐时一条里没有任何 astronomy，也没有 Max/Min**。
//  → 强行复用会产生一个「大部分字段恒为 nil」的巨大模型，
//    且 `ForEach` 的id 语义也会被污染（逐时按小时、逐日按天）。
//
//  ── 🔴 为什么**每一个字段都是可选**（P-18 防线，理由同 `QWeatherDaily`）──
//  任一字段非可选 → 真实响应缺该键 → 合成解码器抛 `keyNotFound`
//  → **整包解码失败 → 整个源静默消失**（卡片空白、无提示）。
//  → 三重防御：① 全部可选；② 弱类型兜底在 DTO 层；③ mapper 逐项净化。
//
//  ── 🔴 量纲纪律（实测，别当百分数） ─────────────────────────────────────
//  · `humidityFraction` / `cloudCoverFraction` 是 **[0, 1]**
//    （实测 `humidity = 0.33`，**不是 33**）→ 渲染须 ×100。
//    字段名带 `Fraction` 后缀，把量纲写进名字（沿用 `QWeatherDayPart` 的做法）。
//  · `precipitation.probability` 同样 **[0, 1]**，且**只在 `precipitation` 内**
//    （顶层**不存在** `precipProbability`，实测确认）。
//  · `temperature` / `feelsLike` / `dewPoint` / `pressure` / `visibility`
//    / `wind.speed` / `windGust` 都是**自带单位的量纲对象**（`QWeatherQuantity`），
//    跨源复用同款类型（与逐日共用 `QWeatherQuantity` / `QWeatherWind` /
//    `QWeatherCondition` / `QWeatherPrecipitation` —— 它们本来就是和风**源级**类型，
//    不是逐日专属，故复用是正确分层，不是将就）。
//
//  ── 与快照的关系 ─────────────────────────────────────────────────────────
//  本模型**不在** `WeatherFieldKey` 域内 → 不进 `WeatherSnapshot` / 共享容器
//  → **Widget 载荷契约零改动**（同 `QWeatherDailyForecast` 的处境）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

// MARK: - 逐时

/// 逐时预报中的一个小时。
///
/// 🔴 逐时 13 键全部映射（**逐字实测**），字段全可选（P-18 防线）。
struct QWeatherHour: Codable, Equatable, Identifiable, Sendable {

    /// 序号（**由 mapper 按数组下标赋值**，非上游字段）。
    ///
    /// ⚠️ 它就是 `Identifiable` 的 `id`，**必须唯一**。
    ///    刻意**不用** `forecastTime` 当 id：官方**未承诺**它唯一、
    ///    且它可能缺失 → `ForEach` 拿到重复/全空 id 会静默错渲。
    ///    下标由 mapper 保证唯一且确定。
    var sequenceIndex: Int

    /// 预报时刻（**UTC ISO8601 原始串**，实测形如 `2026-10-08T15:00Z`）。
    ///
    /// ⚠️ **原样透传**，理由同 `QWeatherDay.forecastStartTime`：
    ///   解析失败不该让整包失败，且拿不准时显示原文比显示错时刻诚实。
    var forecastTime: String?

    /// 温度（量纲值，实测 `{"value": 26.01, "unit": "°C"}`）。
    var temperature: QWeatherQuantity?

    /// 体感温度（量纲值）。
    var feelsLike: QWeatherQuantity?

    /// 🔴 相对湿度（**[0, 1]** —— 实测 `0.33`，**不是 33**！）。
    var humidityFraction: Double?

    /// 🔴 云量（**[0, 1]** —— 实测 `0`，**不是 0–100**）。
    var cloudCoverFraction: Double?

    /// 降水（概率在 `probability`，**[0, 1]**；顶层无`precipProbability`）。
    var precipitation: QWeatherPrecipitation?

    /// 气压（量纲值）。
    var pressure: QWeatherQuantity?

    /// 能见度（量纲值）。
    var visibility: QWeatherQuantity?

    /// 风（风向 + 风速 + 风力等级）。
    var wind: QWeatherWind?

    /// 阵风（量纲值）。
    ///
    /// ⚠️ 逐时端点键名逐字是 `windGust`（**不是**逐日的 `windGustMax`）。
    var windGust: QWeatherQuantity?

    /// 天气现象（上游已本地化，**不翻译**）。
    var condition: QWeatherCondition?

    /// 露点（量纲值）。
    var dewPoint: QWeatherQuantity?

    /// UV 指数（**裸数值**，非量纲对象）。
    ///
    /// ⚠️ 本字段载荷形态是逐时 13 键里**唯一未实测**的（见 DTO 文件头）。
    var uvIndex: Double?

    /// 稳定标识（= `sequenceIndex`，满足 `Identifiable`）。
    var id: Int { sequenceIndex }
}

// MARK: - 顶层

/// 和风逐时预报（一次hourly 链路的完整领域模型）。
struct QWeatherHourlyForecast: Codable, Equatable, Sendable {

    /// 🔴 **署名（合规硬要求，非可选）**。
    ///
    /// 和风官方文档明文：`metadata.attributions` **必须与当前数据共同显示**
    /// → 本字段**一路传到 UI 并渲染**（见 `QWeatherCard` 的逐时区块页脚）。
    /// 与逐日模型的 `attributions` 是**两个独立列表**（两次请求各自的 `metadata`），
    /// 合并去重由 UI 侧决定，Core 不替用户做展示决策。
    var attributions: [String]

    /// 响应标签（`metadata.tag`）。仅供诊断，UI 不展示。
    var tag: String?

    /// 逐时序列（官方键 `hours`）。空数组 = 上游未下发任何小时（→ `.noData`）。
    var hours: [QWeatherHour]

    /// **实质无数据**判定：逐时序列为空。
    ///
    /// ⚠️ 判据只问「有没有小时」，**不**问「字段填得满不满」——
    ///    一小时里字段几乎全缺，**仍是上游下发的一小时**，应如实展示
    ///    （各项显示「暂无」）而不是整块隐藏。反之（0 小时）才是真的没数据。
    var isEffectivelyEmpty: Bool {
        hours.isEmpty
    }

    /// 无任何数据的空值（供 mapper 的「缺块」回落路径使用）。
    static let empty = QWeatherHourlyForecast(attributions: [], tag: nil, hours: [])
}

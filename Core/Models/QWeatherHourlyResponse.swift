//
//  QWeatherHourlyResponse.swift
//  Core / Models  [App + Widget 共用]
//
//  第九源「和风天气」逐时预报（hourly）**原始响应 DTO** + 弱类型兜底解码。
//
//  ══════════════════════════════════════════════════════════════════════════
//  ✅ 实测基准：2026-10-09（主理人用真实凭据打通，`?hours=24` → **HTTP 200**）
//  ══════════════════════════════════════════════════════════════════════════
//
//  ── 🔴🔴 顶层键是 `hours`，**不是** `hourly`**（实测逐字确认） ────────────
//  端点路径是 `/weather/v1/hourly/{lat}/{lon}`（路径里是 `hourly`），
//  但**响应体的顶层数组键实测逐字为 `hours`**：
//
//      {"metadata":{"tag":"…","attributions":["…"]},
//       "hours":[ {…}, {…} ]}
//
//  → DTO 的属性名**必须**是 `hours`。写成 `hourly` 时解码**不会报错**
//    （`CodingKeys` 找不到键 → 该字段为 nil），而是让整源**静默变成「无数据」**
//    —— 这正是 P-18 最坏的失败模式。`QWeatherHourlyTests` 用两条断言钉死这一点。
//
//  ── 逐时条目实测 13 个键（逐字，缺一即解码失败风险） ────────────────────
//      forecastTime / temperature / feelsLike / humidity / cloudCover /
//      precipitation / pressure / visibility / wind / windGust /
//      condition / dewPoint / uvIndex
//
//  ⚠️ **`windGust` 不是 `windGustMax`** —— 逐日端点用 `windGustMax`（峰值语义），
//    逐时端点逐字是 `windGust`（瞬时值语义）。两者拼错不会编译报错
//    （属性名与 JSON 键由 `CodingKeys` 自动对应，写错只是解出 nil），
//    故 `QWeatherHourlyTests` 专门断言 `windGust` 能解出、`windGustMax` 解不出。
//
//  ── 🔴 量纲纪律（实测，**别当百分数**） ──────────────────────────────────
//  · `humidity` 实测 `0.33` → **`[0, 1]`**，**不是 33**；
//  · `cloudCover` 实测 `0` → **`[0, 1]`**；
//  · 降水概率在 **`precipitation.probability`**，
//    **顶层不存在** `precipProbability`（实测查过，确实没有）。
//
//  ── 🔴 `uvIndex` 的载荷形态是本文件**唯一未实测**的字段 ─────────────────
//  逐时条目的 13 个键名是实测逐字确认的，但 lead 只逐字给出了
//  `humidity` / `cloudCover` / `precipitation` 三项的**值形态**。
//  `uvIndex` 本文件按**裸数值**（`LenientDouble`）建模，理由是
//  **已实测的逐日 `uvIndexMax` 就是裸数值**（官方文档亦然，UV 指数无量纲）。
//  ⚠️ 若真机发现它其实是 `{value, unit}` 对象，本文件需改**一处类型**。
//    这是本轮**最可能**需要返工的点，已在交付报告里单列。
//
//  ── 弱类型兜底三条铁律（同 `QWeatherDailyResponse.swift`，不重复论证）──
//  ① 字段缺失 → nil，绝不抛错；
//  ② 类型漂移 → nil，绝不抛错（`LenientDouble` / `LenientString` 吸收）；
//  ③ 绝不猜值。
//
//  ── 为什么 `hours` 声明成 `[Hour?]?` 而不是 `[Hour]?` ───────────────────
//  数组元素**逐个可空**：`[null, {…}]` 这种形态会让 `[Hour]` 整体解码抛错
//  → 整源消失。本仓已在海浪源实测到「元素给 null」的形态，
//  故这里用 `[Hour?]` + mapper 侧 `compactMap` 过滤，
//  代价是丢弃一个 null 元素，收益是**保住其余全部数据**。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

// MARK: - DTO

/// 和风逐时预报原始响应（**解码失败安全**：逐字段可选 + 弱类型兜底）。
///
/// 🔴 顶层键是 **`hours`**（实测），**不是** `hourly`。见文件头。
struct QWeatherHourlyResponse: Decodable, Sendable {

    /// `metadata` 块（与逐日端点同构：`{"tag": "…", "attributions": ["…"]}`）。
    struct Metadata: Decodable, Sendable {
        /// 响应标签（仅供诊断）。
        var tag: LenientString?
        /// 🔴 **署名列表（许可条件：必须与数据共同显示）**。
        var attributions: LenientStringArray?
    }

    /// 单个逐时条目（实测 13 键，见文件头）。
    struct Hour: Decodable, Sendable {

        /// 预报时刻（**UTC ISO8601 原始串**，实测形如 `2026-10-08T15:00Z`）。
        ///
        /// ⚠️ **原样透传，不在 Core 解析成 `Date`**（理由同 `QWeatherAstro`）：
        ///   Core 禁内部 `Date()`，且解析失败不该让整包失败。
        var forecastTime: LenientString?

        /// 温度（量纲值，实测 `{"value": 26.01, "unit": "°C"}`）。
        var temperature: QWeatherResponseQuantity?

        /// 体感温度（量纲值）。
        var feelsLike: QWeatherResponseQuantity?

        /// 🔴 相对湿度（**`[0, 1]`**，实测 `0.33` —— **不是 33**）。
        var humidity: LenientDouble?

        /// 🔴 云量（**`[0, 1]`**，实测 `0` —— **不是 0–100**）。
        var cloudCover: LenientDouble?

        /// 降水。
        ///
        /// ⚠️ 实测载荷有**四项**：`amount` / `intensity` / `type` / `probability`。
        ///    本字段复用 `QWeatherResponsePrecipitation`，它**只解前三个里的
        ///    `amount` / `type` / `probability`** —— `intensity`（mm/h 降水强度）
        ///    **未建模**。这是**有意的**：JSON 解码默认**忽略未知键**，
        ///    故不建模**不会**导致解码失败（不违反 P-18），
        ///    而建模它就得给逐日模型也加一个恒为 nil 的字段（污染那一层）。
        ///    → 代价是「降水强度」这个量暂不呈现，已如实记录待后续批次补。
        var precipitation: QWeatherResponsePrecipitation?

        /// 气压（量纲值）。
        var pressure: QWeatherResponseQuantity?

        /// 能见度（量纲值）。
        var visibility: QWeatherResponseQuantity?

        /// 风（风向 + 风速 + 风力等级，与逐日端点同构）。
        var wind: QWeatherResponseWind?

        /// 🔴 阵风（量纲值）。
        ///
        /// ⚠️ 键名逐字是 **`windGust`**，**不是**逐日端点的 `windGustMax`。
        ///    逐时是瞬时值、逐日是区间峰值，语义不同，故键名不同。
        var windGust: QWeatherResponseQuantity?

        /// 天气现象（上游已本地化为中文，**不翻译**）。
        var condition: QWeatherResponseCondition?

        /// 露点（量纲值）。
        var dewPoint: QWeatherResponseQuantity?

        /// 🔴 UV 指数（**裸数值**，非量纲对象）。
        ///
        /// ⚠️ 本字段的载荷形态是逐时 13 键里**唯一未实测**的，
        ///    按已实测的逐日 `uvIndexMax` 形态取「裸数值」。见文件头。
        var uvIndex: LenientDouble?
    }

    /// `metadata` 块。整键可选：缺失时署名视为「上游未提供」。
    var metadata: Metadata?

    /// 🔴 **`hours`** 块（实测顶层键）。整键可选：缺失 = 上游没给逐时数据。
    ///
    /// ⚠️ 元素逐个可空（`[Hour?]`）：`[null, {…}]` 不应让整包解码失败。
    var hours: [Hour?]?
}

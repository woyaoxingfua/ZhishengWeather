//
//  QWeatherDailyResponse.swift
//  Core / Models  [App + Widget 共用]
//
//  第九源「和风天气」逐日预报**原始响应 DTO** + 弱类型兜底解码。
//
//  ══════════════════════════════════════════════════════════════════════════
//  🔴🔴 字段清单来源 = 和风官方文档页
//     `https://dev.qweather.com/docs/api/weather/weather-daily-forecast`
//     （主理人 **2026-10-08** 抓取）。
//
//  ⚠️⚠️ **本轮未实测（无 Key）**：
//     · 主理人拿不到和风 Key，**本仓库从未收到该账号的真实响应**；
//     · 实测 `devapi.qweather.com` → **HTTP 403 Invalid Host**（带 Key 也 403）；
//     · 官方文档站 `dev.qweather.com/docs/api/` 在抓取机上 **403**（需登录/防爬）。
//  → **官方文档示例 ≠ 真实账号响应**；不同套餐返回字段可能不同。
//  → **接入后必须真机核验**（逐条对照本文件与 `QWeatherDaily.swift` 的字段注释）。
//
//  ══════════════════════════════════════════════════════════════════════════
//  🔴 本文件为何存在（为什么不直接把 DTO 写成领域模型）
//  ══════════════════════════════════════════════════════════════════════════
//  领域模型（`QWeatherDaily.swift`）保持「干净的可选值」，本文件承担
//  **「线上格式的脏」**这一层，两者职责分离：
//
//  ·本文件 = **线上字节 → 宽容结构**（容忍类型漂移，绝不整包失败）
//  ·`QWeatherMapper` = **宽容结构 → 领域模型**（逐项净化，绝不造假值）
//
//  ── 弱类型兜底的三条铁律（P-18 血泪的直接对策）────────────────────────
//  ① **字段缺失 → nil，绝不抛错**（否则整源静默消失，史上最坏的失败模式）；
//  ② **类型漂移 → nil，绝不抛错**（`29.94` 变`"29.94"`、`"305"` 变 `305`
//     是最常见的真实漂移，由 `LenientDouble` / `LenientString` 吸收）；
//  ③ **绝不"猜值"**：`"abc"` 不转 0、缺字段不填默认值 ——
//     宁可显示「暂无」，不可显示一个看似合理的假数。
//
//  ── 为什么**不**复用 `FlexibleTime` ─────────────────────────────────────
//  `FlexibleTime` 解的是「epoch 数字 **或** ISO 字符串」的**时间**双态。
//  本源的时刻按官方文档**恒为 UTC ISO8601 带 Z 串**，且我们**刻意保留原始串**
//  （理由见 `QWeatherDay.forecastStartTime` 注释）→ 不需要时间双态解析。
//  复用它反而会把一个「无需解析的原始串」变成「可能被误解析的 Date」。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

// MARK: - 弱类型兜底标量

/// 宽容数字：接受 JSON 数值**或**可解析为数字的字符串。
///
/// 🔴 存在理由见文件头铁律 ②。**这是一个通用兜底类型，不是和风专属**——
///    它不认识任何和风字段名，纯粹是「标量类型漂移」的吸收器。
///
/// ⚠️ 刻意**不可变 + 无 `public` 成员**：它只服务于本文件内的解码，
///    mapper 立刻取 `.value` 转成领域模型的 `Double?`。
struct LenientDouble: Decodable, Equatable, Sendable {

    /// 解出的数值；键缺失 / null / 类型不符 / 字符串不可解析 → nil。
    let value: Double?

    /// 解码（**永不抛错**）。
    /// - Parameter decoder: 解码器。
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // ① 原生数值（最常见路径）。
        if let direct = try? container.decode(Double.self) {
            value = direct
            return
        }
        // ② 字符串形态（`"29.94"` / `"0.52"`）—— 逐字trim 后再解析。
        if let text = try? container.decode(String.self) {
            value = Double(text.trimmingCharacters(in: .whitespaces))
            return
        }
        // ③ null / 数组 / 对象 / 布尔 → nil（**不猜值**，铁律 ③）。
        value = nil
    }
}

/// 宽容字符串：接受 JSON 字符串**或**标量数值（转为字符串）。
///
/// 🔴 用于 `condition.code`：官方示例是字符串 `"305"`，
///    但若上游改下发数字 `305`，合成解码会抛 `typeMismatch` → 整包失败。
///
/// ⚠️ 数值 → 字符串时**整数不带 `.0`**（`305` 而非 `305.0`）——
///    免得把一个代码显示成小数。
struct LenientString: Decodable, Equatable, Sendable {

    /// 解出的字符串；键缺失 / null / 类型不符 → nil。
    let value: String?

    /// 解码（**永不抛错**）。
    /// - Parameter decoder: 解码器。
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let direct = try? container.decode(String.self) {
            value = direct
            return
        }
        if let number = try? container.decode(Double.self) {
            if number == number.rounded(), number.magnitude < 1e15 {
                value = String(Int64(number))
            } else {
                value = String(number)
            }
            return
        }
        value = nil
    }
}

/// 宽容字符串数组：逐元素宽容解码，**跳过**空/非字符串元素（而不是整包失败）。
///
/// 🔴 用于 `metadata.attributions`：它是**合规必需字段**，万一上游某天下发
///    一个非字符串元素，**绝不能**让整份逐日数据消失（署名重要，但比数据次要）。
///
/// ⚠️ 刻意**不用 `while !container.isAtEnd` 手写循环**：
///    元素解码失败时无法保证 unkeyed 容器的游标一定推进，
///    手写循环存在**死循环**风险（无法静态排除的运行期挂起）。
///    改用「整体解码 `[LenientString]` + 过滤」——`LenientString` **永不抛错**，
///    故数组解码唯一可能失败的点是「该键根本不是数组」，那种情况整体退化为 nil，
///    **不存在**逐元素卡死的可能。
///
/// ⚠️「跳过」是刻意的：保留能解出的元素，比丢掉整包数据划算。
///    被跳过的事实由 `values.isEmpty` 暴露给 UI（如实显示"上游未提供署名"）。
struct LenientStringArray: Decodable, Equatable, Sendable {

    /// 成功解出的字符串（保持上游顺序）。
    let values: [String]

    /// 解码（**永不抛错**）。
    /// - Parameter decoder: 解码器。
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let elements = try? container.decode([LenientString].self) else {
            // 不是数组 → 视为「上游未提供」，**不**抛错。
            values = []
            return
        }
        var collected: [String] = []
        collected.reserveCapacity(elements.count)
        for element in elements {
            // nil / 空串都跳过：署名列表里一个空链接对用户毫无价值。
            if let text = element.value, !text.isEmpty {
                collected.append(text)
            }
        }
        values = collected
    }
}

// MARK: - DTO

/// 和风逐日预报原始响应（**解码失败安全**：逐字段可选 + 弱类型兜底）。
///
/// ⚠️ 官方文档如此（**未实测**）。顶层只有两个键：`metadata` 与 `days`。
struct QWeatherDailyResponse: Decodable, Sendable {

    /// `metadata` 块（官方示例 `{"tag": "...", "attributions": ["https://…"]}`）。
    struct Metadata: Decodable, Sendable {
        /// 响应标签（仅供诊断）。
        var tag: LenientString?
        /// 🔴 **署名列表（许可条件：必须与数据共同显示）**。
        ///
        /// 用 `LenientStringArray` 而非 `[String]`：逐元素宽容，
        /// 绝不让一个畸形元素导致整包消失。
        var attributions: LenientStringArray?
    }

    /// 昼夜分块 DTO（`daytime` 与 `nighttime` 共用此类型 —— 官方称「同构」）。
    struct DayPart: Decodable, Sendable {
        /// 天气现象。
        var condition: QWeatherResponseCondition?
        /// 该分块最高温（量纲值）。
        var temperatureMax: QWeatherResponseQuantity?
        /// 该分块最低温（量纲值）。
        var temperatureMin: QWeatherResponseQuantity?
        /// 🔴 相对湿度（**[0, 1]**，不是 0–100）。
        var humidity: LenientDouble?
        /// 风。
        var wind: QWeatherResponseWind?
        /// 阵风峰值（量纲值）。
        var windGustMax: QWeatherResponseQuantity?
        /// 降水。
        var precipitation: QWeatherResponsePrecipitation?
        /// 🔴 云量（**[0, 1]**，不是 0–100）。
        var cloudCover: LenientDouble?
    }

    /// 单日 DTO。
    struct Day: Decodable, Sendable {
        /// 预报起始时刻（UTC ISO8601 原始串）。
        var forecastStartTime: LenientString?
        /// 预报结束时刻（UTC ISO8601 原始串）。
        var forecastEndTime: LenientString?
        /// 天文。
        var astro: QWeatherResponseAstro?
        /// 当日最高温（量纲值）。
        var temperatureMax: QWeatherResponseQuantity?
        /// 当日最低温（量纲值）。
        var temperatureMin: QWeatherResponseQuantity?
        /// 当日均温（量纲值）。
        var temperatureAvg: QWeatherResponseQuantity?
        /// 当日 UV 峰值。
        var uvIndexMax: LenientDouble?
        /// 白天分块（响应键 `daytime`）。
        var daytime: DayPart?
        /// 夜晚分块（响应键 `nighttime`）。
        var nighttime: DayPart?
    }

    /// `metadata` 块。整键可选：缺失时署名视为「上游未提供」。
    var metadata: Metadata?

    /// `days` 块。整键可选：缺失 = 上游没给逐日数据。
    var days: [Day]?
}

/// 量纲值 DTO（`{"value": …, "unit": …}`）。
///
/// ⚠️ 官方文档如此（**未实测**）。
struct QWeatherResponseQuantity: Decodable, Sendable {
    /// 数值。
    var value: LenientDouble?
    /// 单位串（**原样保留，不换算**）。
    var unit: LenientString?
}

/// 天气现象 DTO。
///
/// ⚠️ 官方文档如此（**未实测**）：`{"text": "小雨", "code": "305"}`。
struct QWeatherResponseCondition: Decodable, Sendable {
    /// 现象中文描述（上游已是中文）。
    var text: LenientString?
    /// 现象代码（官方示例是字符串 `"305"`；用 `LenientString` 抗数字漂移）。
    ///
    /// ⚠️ **和风自有码，不是 WMO 码** → 不可与 `WMOCodeMapper` 混用。
    var code: LenientString?
}

/// 风向 DTO。
///
/// ⚠️ 官方文档如此（**未实测**）：`{"degree": 270, "compass": "w"}`。
struct QWeatherResponseWindDirection: Decodable, Sendable {
    /// 风向角度（**[0, 359]**）。
    var degree: LenientDouble?
    /// 英文方位缩写（原样保留）。
    var compass: LenientString?
}

/// 风 DTO。
struct QWeatherResponseWind: Decodable, Sendable {
    /// 风向。
    var direction: QWeatherResponseWindDirection?
    /// 风速（量纲值）。
    var speed: QWeatherResponseQuantity?
    /// 风力等级（整数档位；与 `speed` **不可互推**）。
    var scale: LenientDouble?
}

/// 降水 DTO。
///
/// 🔴 `probability` 是 **[0, 1]**，不是百分数。
struct QWeatherResponsePrecipitation: Decodable, Sendable {
    /// 降水量（量纲值）。
    var amount: QWeatherResponseQuantity?
    /// 降水概率（**[0, 1]**）。
    var probability: LenientDouble?
    /// 降水类型（原样保留，不建枚举——枚举会把未知值变成丢数据）。
    var type: LenientString?
}

/// 天文 DTO（全部为 UTC ISO8601 原始串，**不在此解析**）。
///
/// ⚠️ 官方文档如此（**未实测**）。
struct QWeatherResponseAstro: Decodable, Sendable {
    /// 日出。
    var sunrise: LenientString?
    /// 日落。
    var sunset: LenientString?
    /// 天文晨光始。
    var astronomicalDawn: LenientString?
    /// 航海晨光始。
    var nauticalDawn: LenientString?
    /// 民用晨光始。
    var civilDawn: LenientString?
    /// 天文暮光终。
    var astronomicalDusk: LenientString?
    /// 航海暮光终。
    var nauticalDusk: LenientString?
    /// 民用暮光终。
    var civilDusk: LenientString?
    /// 太阳正午。
    var solarNoon: LenientString?
    /// 太阳子夜。
    var solarMidnight: LenientString?
    /// 月出。
    var moonrise: LenientString?
    /// 月落。
    var moonset: LenientString?
    /// 月过中天。
    var moonTransit: LenientString?
    /// 月下中天。
    var moonUnderfoot: LenientString?
    /// 月相（英文连字符串）。
    var moonPhase: LenientString?
}

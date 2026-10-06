//
//  MarineConditionsResponse.swift
//  Core / Models  [App + Widget 共用]
//
//  第四源 Open-Meteo Marine 原始响应 DTO（独立子域名
//  `marine-api.open-meteo.com/v1/marine`）。
//
//  ═══════════════════════════════════════════════════════════════════════
//  ⚠️ 为什么必须**新建 DTO**，绝不复用 `OpenMeteoResponse`
//  ═══════════════════════════════════════════════════════════════════════
//  `OpenMeteoResponse.swift:202-203` 里 `current` / `hourly` 是**非可选**字段：
//
//      let current: Current
//      let hourly: Hourly
//
//  而 marine / flood 端点**根本不返回** `hourly`（实测 marine 只有 `current`，
//  flood 只有 `daily`）。复用主链路 DTO 会让合成解码器在**缺 `hourly` 键**时
//  直接抛 `keyNotFound` —— 整包解码失败。这不是"解码容错"能救的，是类型层面的
// 硬冲突。故 marine / flood 各自新建 DTO。
//
//  ── 容错纪律（全部整键可选 + 元素可选）──────────────────────────────
//  · 整块缺失 → 对应属性 nil；
//  · **元素为 `null` → 解码为 nil，绝不补 0**。
//  ⚠️ 本仓库真机事故：DTO 把数组元素声明为非可选，响应末尾一个 `null` 元素
//  就让**整包**解码失败 → 主屏与小组件同时无数据。故 `[T?]?` 是硬要求。
//
//  ── 实测形态（2026-10-06 探针，青岛 36.07,120.38）──────────────────────
//  {
//    "current_units":{"time":"unixtime","interval":"seconds",
//                     "wave_height":"m","wave_direction":"°","wave_period":"s",
//                     "swell_wave_height":"m","swell_wave_direction":"°",
//                     "swell_wave_period":"s"},
//    "current":{"time":1791285300,"interval":900,
//               "wave_height":0.34,"wave_direction":197,"wave_period":3.10,
//               "swell_wave_height":0.22,"swell_wave_direction":181,
//               "swell_wave_period":3.50}
//  }
//
//  ⚠️ **单位是 `m` / `°` / `s`**（浪向是**度**，不是 0–1 的小数，也不是百分数）。
//  ⚠️ `time` 因端点钉死 `timeformat=unixtime` 而是 **epoch 整数**，故用
//    `FlexibleTime` 双态容忍（复用既有类型，**不新造第二套时间解码**）。
//
//  ── ⚠️ 不建模的字段（刻意）──────────────────────────────────────────
//  · `latitude/longitude/elevation/timezone/...` 顶层元信息：
//    本项目不需要（城市名由上层覆盖，与 `WeatherService` 的做法一致）。
//  · `current_units`：**刻意不建模**。它的存在价值只在于暴露那个字面量
//    `"undefined"`（变量名在词表里但该端点不支持时出现，见 MarineEndpoint 文件头）。
//    我们不据此做分支 —— 判据是**值是否为 null**，那更直接、也更不容易被
//    部署差异带偏。建模它反而会诱使后人写"看单位串来判断支不支持"的脆弱逻辑。
//
//  ⚠️ 但 `utc_offset_seconds` **必须建模**（它不在上面那个"刻意不建模"清单里）：
//  它是 `ISOTimeStringDecoder` 的**必需入参**（ARCH §4.1 铁律：ISO 墙钟串
//  必须搭配它所属响应的偏移来解释）。漏掉它就只能拿 `0` 硬解，那会让时刻
//  **静默偏移**若干小时 —— 无报错、无崩溃的最坏一类缺陷。即便端点已钉死
//  `timeformat=unixtime`、实测走不到兜底分支，兜底路径也必须是对的，
//  不能是"看起来能跑"的假正确。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// Open-Meteo Marine 原始响应（仅保留本项目所需字段；解码失败安全：全部可选）。
struct MarineConditionsResponse: Decodable, Sendable {

    /// `current` 块（瞬时海况）。整键可选：缺失 → nil（mapper 回落到空模型）。
    struct Current: Decodable, Sendable {
        /// 观测时刻（端点已钉死 `timeformat=unixtime` → epoch 秒；
        /// 用 `FlexibleTime` 容忍个别部署返回 ISO 字符串）。
        var time: FlexibleTime?
        /// 有效浪高（m）。元素/键缺失或为 null → nil（**绝不补 0**）。
        var wave_height: Double?
        /// 浪来向（**度**，0–360）。`0`（正北）是合法取值，不是缺失。
        var wave_direction: Double?
        /// 浪周期（s）。
        var wave_period: Double?
        /// 涌浪有效浪高（m）。
        var swell_wave_height: Double?
        /// 涌浪来向（度）。`0` 是合法取值。
        var swell_wave_direction: Double?
        /// 涌浪周期（s）。
        var swell_wave_period: Double?
    }

    /// `current` 块。marine 端点实测**只有** `current`（无 `hourly`）。
    let current: Current?

    /// 该响应的 UTC 偏移（**秒**）。
    ///
    /// 存在的唯一理由：让 `ISOTimeStringDecoder` 能正确解释 ISO 形态的时刻
    /// （实测青岛为 `28800` = +08:00）。**不要**用它去换算 epoch ——
    /// epoch 本身就是绝对时刻，加偏移是错的。
    ///
    /// 整键可选：缺失时 mapper 的兜底分支会**放弃**解析 ISO 时刻（留 nil），
    /// 而**不是**拿 0 硬解。宁可卡片少一个时间戳，也不静默偏移几小时。
    var utc_offset_seconds: Int?
}
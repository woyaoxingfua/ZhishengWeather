//
//  FloodResponse.swift
//  Core / Models  [App + Widget 共用]
//
//  第五源 Open-Meteo Flood 原始响应 DTO（独立子域名
//  `flood-api.open-meteo.com/v1/flood`）。
//
//  ⚠️ 为什么**新建 DTO** 而不复用 `OpenMeteoResponse`：
//  `OpenMeteoResponse.swift:202-203` 的 `current` / `hourly` 是**非可选**
//  （`let current: Current` / `let hourly: Hourly`），而 flood 端点
//  **既不返回 `current` 也不返回 `hourly`**（实测只有 `daily`）。
//  复用会让合成解码器在缺键时直接抛 `keyNotFound` —— 整包失败。
//
//  ── 实测形态（2026-10-06 探针，武汉 30.6,114.3，`forecast_days=7`）──────
//  {
//    "daily_units":{"time":"unixtime","river_discharge":"m³/s"},
//    "daily":{"time":[1791216000,1791302400,1791388800,1791475200,
//                    1791561600,1791648000,1791734400],
//             "river_discharge":[5.70,2.35,1.29,0.64,0.28,0.16,0.12]}
//  }
//
//  ⚠️ 单位是 **m³/s**（`daily_units.river_discharge` 实测就是 `"m³/s"`）。
//  ⚠️ `time` 因 `timeformat=unixtime` 而是 **epoch 整数**，且实测是
//  **当地零点**（1791216000 = 2026-10-06T00:00+08:00，不是 UTC 零点）。
//
//  ── ⚠️ ⚠️ 「静默失败」在本端点有一个**已实测的陷阱**，必须防 ────────────
//  变量名**在全局词表存在、但该端点不支持** → **HTTP 200 且整块被静默省略**
//  （`daily` 键整个不存在）。而变量名**压根不在词表** → **HTTP 400**。
//
//  本仓库实测过的那个"部分支持"形态（`daily=river_discharge,temperature_2m_max`）：
//  HTTP 200、`river_discharge` **有值**，而 `temperature_2m_max` 为 **`[null]`**，
//  且它的单位串是**字面量 `"undefined"`**。
//
//  → 故 DTO 的数组元素**必须**是可选（`[Double?]`），且 mapper **必须**逐元素
//  判非空。否则"没数据"会被当成"流量 0"画到屏幕上 —— 把一条缺测说成断流。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// Open-Meteo Flood 原始响应（解码失败安全：全部可选）。
struct FloodResponse: Decodable, Sendable {

    /// `daily` 块（逐日）。整键可选：静默省略时为 nil。
    struct Daily: Decodable, Sendable {
        /// 逐日日期（端点钉死 `timeformat=unixtime` → epoch 秒，当地零点）。
        ///
        /// 整键可选 + **元素也可选**（`null` 元素不得让整包解码失败 ——
        /// 本仓库真机事故：元素非可选时一个尾部 null 就让主屏与小组件同时无数据）。
        ///
        /// ⚠️ 用 `FlexibleTime`（**不是** `Int`）：run37 真机事故的根因就是
        /// "DTO 声明 epoch 整数、实际收到 ISO 字符串" → 整包解码失败 →
        /// 主屏与小组件同时无数据。`FlexibleTime` 双态容忍正是为这条而存在，
        /// 这里**复用**它（不新造第二套时间解码）。
        var time: [FlexibleTime?]?

        /// 逐日河道流量（**m³/s**）。
        ///
        /// 元素为 `null` = 该日缺测（**绝不补 0**：`0.00` 是合法读数 ——
        /// 实测乌鲁木齐断流时返回的就是 `0.00`）。
        var river_discharge: [Double?]?
    }

    /// `daily` 块。flood 端点实测**只有** `daily`（无 `current` / `hourly`）。
    let daily: Daily?

    /// 该响应的 UTC 偏移（秒），供 `FlexibleTime` 落在 ISO 形态时解释墙钟。
    ///
    /// 端点已钉死 unixtime、实测走不到 ISO 兜底分支，但兜底也必须是对的：
    /// 缺失时 mapper **放弃**解析该日（跳过），**绝不**拿 `0` 硬解。
    var utc_offset_seconds: Int?
}
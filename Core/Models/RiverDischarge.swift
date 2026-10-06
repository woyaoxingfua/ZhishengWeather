//
//  RiverDischarge.swift
//  Core / Models  [App + Widget 共用]
//
//  河道流量领域模型（第五源 Open-Meteo Flood，独立子域名
//  `flood-api.open-meteo.com/v1/flood`，**免 Key**）。
//
//  ── 量纲纪律（本文件最容易出错的地方，务必钉死）─────────────────────────
//  `river_discharge` 的单位是 **m³/s（立方米每秒）**，实测
//  `daily_units.river_discharge == "m³/s"`（武汉 30.6,114.3 实测
//  `[5.70, 2.35, 1.29, 0.64, ...]`）。
//  它**不是**：流量（kg/s）、水量（m³）、降水量（mm）、水位（m）。
//  模型字段名刻意带 `cubicMetresPerSecond` 量纲后缀，让"单位写错"变成
//  一眼可见的事 —— 沿用 `AqiHourlyPoint` 把单位写进字段名的既有做法。
//
//  ── 语义纪律 ───────────────────────────────────────────────────────────
//  1. `0` 是**合法读数**（断流 / 断流后的干涸河道），**绝不**与"缺测"混同。
//  2. **负值视为服务端异常 → nil**（流量不可能为负）。
//  3. **内陆坐标照样可能有值**（⚠️ 与 marine 相反的实测结论）：
//     北京 39.9,116.4 实测 `river_discharge:[5.07, 5.05, ...]`（有值），
//     拉萨 29.65,91.1 实测 `[0.24, 0.17, 0.15]`。故 flood **不按"是否沿海"过滤**
//     —— 洪水 / 河道流量对内陆城市同样有意义。只有 marine 需要坐标判据。
//
//  ── 与快照的关系 ───────────────────────────────────────────────────────
//  与 `MarineConditions` 同处境：`river_discharge` **不在** `WeatherFieldKey` 域内，
//  故不进 `WeatherSnapshot` / 共享容器 → **Widget 载荷契约零改动**。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 河道流量逐日序列中的一个点。
struct RiverDischargePoint: Codable, Equatable, Identifiable, Sendable {

    /// 该点对应的**当地日期 00:00**（epoch 秒，由端点 `timeformat=unixtime` 解析）。
    ///
    /// ⚠️ marine/flood 端点钉死 `timeformat=unixtime`，故 `daily.time` 为 epoch 秒，
    /// 且实测是**当地时间**的零点（如 epoch 1791216000 = 2026-10-06T00:00+08:00，
    /// 而非 UTC 零点）。这是 Open-Meteo 的既有约定，与主链路的 `FlexibleTime`
    /// 同一口径 —— **不新造第二套时间解析**。
    var date: Date

    /// 当日河道流量（**m³/s**）。nil = 该日缺测（**绝不补 0**：`0` 是合法读数）。
    var cubicMetresPerSecond: Double?

    /// 以日期作为稳定标识（同一当地日期唯一）。
    var id: Date { date }
}

/// 河道流量（一次 flood 链路的完整领域模型）。
struct RiverDischarge: Codable, Equatable, Sendable {

    /// 逐日流量序列（实测端点默认返回 92 天，端点已用 `forecast_days` 收窄）。
    ///
    /// 空数组 = 无任何可用数据（见 `isEffectivelyEmpty`）。
    var daily: [RiverDischargePoint]
}

extension RiverDischarge {

    /// **实质无数据**判定 → 转发到 `SnapshotCompleteness.isEffectivelyEmpty(_ discharge:)`。
    ///
    /// ⚠️ 判据的**权威不在本模型**，而在 `SnapshotCompleteness`（与天气快照 /
    /// 海浪共用同一处，见该文件「独立链路」小节）。
    var isEffectivelyEmpty: Bool {
        SnapshotCompleteness.isEffectivelyEmpty(self)
    }

    /// 无任何数据的空模型（供 mapper 的"缺块"回落路径使用）。
    static let empty = RiverDischarge(daily: [])
}
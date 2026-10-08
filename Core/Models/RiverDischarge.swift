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

/// 河道流量数据的**地理来源**：请求点 vs 实际网格点。
///
/// 🔴 **存在理由（诚实性）**：上游**不返回河名**，用户问「这是哪条河」时
/// 本应用**无法回答**（官方文档 + 本机实测双重确认）。唯一能如实给出的
/// 是「数据取自距你多远的网格点」。
///
/// ⚠️ **距离由本应用按 Haversine 算出**（复用既有的 `GeoDistance`，R = 6371 km），
/// **不是**上游测距 —— 页脚必须如实标注这一点（同 `EarthquakeCard` 纪律）。
///
/// ⚠️ **距离为 nil 有两种截然不同的原因，UI 必须分开说**：
///   1. 上游没回显网格坐标（`gridLatitude` / `gridLongitude` 为 nil）→ **不知道**；
///   2. 坐标非有限值 → `GeoDistance` 返回 nil（**如实缺测，绝不返回 0** ——
///      返回 0 会被渲染成「数据点就在你脚下」）。
/// 绝不用请求坐标回填网格坐标来「凑出」一个距离。
struct FloodGridOrigin: Codable, Equatable, Sendable {

    /// **请求点**纬度（调用方传入的城市 / 当前位置坐标）。
    var requestedLatitude: Double

    /// **请求点**经度。
    var requestedLongitude: Double

    /// 上游**回显**的网格中心纬度。nil = 上游未回显（距离不可知）。
    var gridLatitude: Double?

    /// 上游**回显**的网格中心经度。nil = 上游未回显。
    var gridLongitude: Double?

    /// 请求点到网格点的球面距离（**km**；由 `GeoDistance` 计算）。
    ///
    /// nil = 网格坐标缺失，或坐标非有限值（**绝不用 0 顶替**）。
    var distanceKilometers: Double?

    /// 由请求坐标 + DTO 回显坐标构造（**唯一构造入口**）。
    ///
    /// - Parameters:
    ///   - requestedLatitude: 请求纬度。
    ///   - requestedLongitude: 请求经度。
    ///   - gridLatitude: 响应回显纬度（可缺）。
    ///   - gridLongitude: 响应回显经度（可缺）。
    init(requestedLatitude: Double,
         requestedLongitude: Double,
         gridLatitude: Double?,
         gridLongitude: Double?) {
        self.requestedLatitude = requestedLatitude
        self.requestedLongitude = requestedLongitude
        self.gridLatitude = gridLatitude
        self.gridLongitude = gridLongitude
        // 🔴 网格坐标**任一**缺失 → 距离不可知（nil）。
        // 绝不用请求坐标回填 —— 那会把「偏移几公里」永远显示成 0。
        if let gridLatitude, let gridLongitude {
            self.distanceKilometers = GeoDistance.kilometers(
                originLatitude: requestedLatitude,
                originLongitude: requestedLongitude,
                targetLatitude: gridLatitude,
                targetLongitude: gridLongitude
            )
        } else {
            self.distanceKilometers = nil
        }
    }

    /// 网格坐标是否**确实**回显了（两者皆非 nil）。
    var hasEchoedGridPoint: Bool {
        gridLatitude != nil && gridLongitude != nil
    }
}

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

    /// 🔴 数据实际取自哪个网格点（2026-10-11 新增）。
    ///
    /// ⚠️ **默认 nil**：无请求坐标上下文时（如 mapper 的「缺 `daily` 块」回落路径、
    /// 单测直接构造）**不编造网格来源**。nil ≠ 距离为 0。
    ///
    /// ⚠️ **合成 Codable 兼容**：可选 + 默认值 → 旧载荷缺此键解码为 nil、
    ///    解码不失败（同 `WeatherSnapshot` 的 v1.1 范式）。本类型**不落盘**
    ///    （不在 `WeatherSnapshot` 域内），但保持解码安全是本仓纪律。
    var gridOrigin: FloodGridOrigin? = nil
}

extension RiverDischarge {

    /// **实质无数据**判定 → 转发到 `SnapshotCompleteness.isEffectivelyEmpty(_ discharge:)`。
    ///
    /// ⚠️ 判据的**权威不在本模型**，而在 `SnapshotCompleteness`（与天气快照 /
    /// 海浪共用同一处，见该文件「独立链路」小节）。
    ///
    /// ⚠️ **只看 `daily`，不看 `gridOrigin`**：网格来源缺失**不是**「没有河道数据」
    ///   （那是两件事）。有网格坐标但序列为空 → 仍是实质无数据。
    var isEffectivelyEmpty: Bool {
        SnapshotCompleteness.isEffectivelyEmpty(self)
    }

    /// 无任何数据的空模型（供 mapper 的"缺块"回落路径使用）。
    ///
    /// ⚠️ `gridOrigin` 恒为 nil：回落路径**不知道**网格来源，**不编造**。
    static let empty = RiverDischarge(daily: [])
}
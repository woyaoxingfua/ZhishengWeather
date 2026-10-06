//
//  HourlyPoint.swift
//  Core / Models  [App + Widget 共用]
//
//  单个逐小时预报点。
//

import Foundation

/// 逐小时预报中的一个时间点。
struct HourlyPoint: Codable, Equatable, Identifiable, Sendable {

    /// 该小时的时刻（epoch 秒解析而来）。
    var time: Date
    /// 气温（℃）。
    var temperature: Double
    /// WMO 天气码（0–99）。
    var weatherCode: Int
    /// 降水概率（%，0–100）。A2-2 摘要引擎输入（A2 新增，可选）：
    /// nil = 服务端未返回 / 元素 null / 旧缓存无此键（Widget 不消费，仅主屏摘要用）。
    var precipitationProbability: Double? = nil
    /// P2 数据补全：该小时降水量（mm）。可选：
    /// nil = 服务端未返回 / 元素 null / 旧缓存无此键。0.0 是合法值（原样保留，不转 nil）。
    var precipitation: Double? = nil
    /// P2 数据补全：该小时风速（m/s，随 wind_speed_unit=ms）。可选，nil 语义同上。
    var windSpeed: Double? = nil
    /// P2 数据补全：该小时阵风（m/s）。可选，nil 语义同上。
    var windGusts: Double? = nil
    /// P2 数据补全：该小时体感温度（℃）。可选，nil 语义同上。
    var apparentTemperature: Double? = nil
    /// P2 · AC-B17b：该小时风向（**度**，0–360，气象约定为「风来的方向」）。
    ///
    /// 可选，nil 语义同 `precipitation`：
    /// nil = 服务端未返回 / 元素 null / 旧缓存无此键（旧缓存**必然**无此键 → nil）。
    ///
    /// ⚠️ 两条纪律：
    /// 1. **`0°` 与 `360°` 都是合法值**（都表示正北），原样保留，**绝不转 nil**；
    ///    只有元素为 `null` 才是 nil（AC-A5 同款）。
    /// 2. **绝不允许**用 `WeatherSnapshot.windDirection`（实况**单值**）去填充任何逐时点
    ///    —— 那是拿一个时刻的值冒充整条时间序列，属**编造数据**（AC-C4c 红线）。
    ///    本字段缺失时就该让下游**如实空态**（AC-C4b：该小时不画箭头，且不影响风速柱）。
    var windDirection: Double? = nil
    /// P2 · AC-B17c：该小时 UV 指数（**无量纲**，WHO 标准量表 0–11+，越高越强）。
    ///
    /// 可选，nil 语义同 `precipitation`：
    /// nil = 服务端未返回 / 元素 null / 旧缓存无此键。
    ///
    /// ⚠️ **`0.0` 是合法值**（夜间 UV 为 0），**不得**被转成 nil 或被下游当"缺测"处理
    /// —— 与 `WeatherSnapshot.uvIndex`（此刻实况）、`DailyForecast.uvIndexMax`（当日峰值）
    /// 三者语义不同，UI 不许共用一个标签。分级规则见 `UVIndexGuide`（WHO 标准）。
    var uvIndex: Double? = nil
    /// P2 · AC-B17c：该小时能见度（**米**，Open-Meteo 原生单位；m→km 换算归展示层）。
    /// 可选，nil 语义同 `precipitation`。`0 m` 不合法但若出现仍**原样保留**（只 null 才转 nil）。
    var visibility: Double? = nil
    /// P2 · AC-B17c：该小时**零度层高度**（**米**）——该海拔高度处气温为 0℃，
    /// 即雨/雪分界高度。可选，nil 语义同 `precipitation`。⚠️ 不是海拔、不是地面前 0℃ 高度。
    var freezingLevelHeight: Double? = nil

    /// 以时刻作为稳定标识（同一小时内唯一）。
    var id: Date { time }
}

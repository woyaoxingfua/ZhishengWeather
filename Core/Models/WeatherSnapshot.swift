//
//  WeatherSnapshot.swift
//  Core / Models  [App + Widget 共用]
//
//  领域主模型：一次成功取数的完整天气快照。
//
//  v1.1 修订（团队裁定）：`dailyHigh` / `dailyLow` 由「计算属性」改为「存储属性」，
//  取值自 Open-Meteo `daily` 的第 0 项；仅当 `daily` 缺失或长度不足时，
//  才由 OpenMeteoMapper 回退按 hourly 窗口的 min/max 派生。
//
//  v1.2 修订（F-A 逐日预报）：新增可选存储属性 `daily: [DailyForecast]?`
//  （插在 `dailyLow` 与 `fetchedAt` 之间）。其余字段一律不动；
//  旧缓存兼容依赖合成 Codable 对缺失键返回 nil（详见字段注释）。
//

import Foundation

/// 一次成功取数得到的天气快照（落盘 / 展示 / 小组件共用）。
struct WeatherSnapshot: Codable, Equatable, Sendable {

    /// 查询所用的位置。
    var location: LocationInfo
    /// 当前气温（℃）。
    var temperature: Double
    /// 当前体感温度（℃）。
    var apparentTemperature: Double
    /// 当前 WMO 天气码。
    var weatherCode: Int
    /// 当前风速（m/s）。
    var windSpeed: Double
    /// 当前风向（0–360 度）。
    var windDirection: Double
    /// 当前相对湿度（%）。
    var humidity: Int
    /// 当前是否白天。
    var isDay: Bool
    /// 逐小时预报（已按 now 起截取，≤ 12 条）。
    var hourly: [HourlyPoint]
    /// 今日最高温（℃）。来自 daily 第 0 项；缺失时回退 hourly 窗口 max。
    var dailyHigh: Double
    /// 今日最低温（℃）。来自 daily 第 0 项；缺失时回退 hourly 窗口 min。
    var dailyLow: Double
    /// 逐日预报（F-A 新增，可选）。
    ///
    /// 兼容性核心（F-A-9）：**必须**保持合成 Codable + 可选类型 ——
    /// 旧版 App 写入的共享容器 JSON 没有 `daily` 键，合成解码器对缺失键
    /// 天然返回 nil、不抛错，旧缓存读取必然成功。
    /// **禁止**为本字段手写 `init(from:)` 或引入 payloadVersion（会击穿兼容保证）。
    ///
    /// 取值约定：
    /// - 服务端返回且映射成功 → 数组（可能为空，空数组同样整块隐藏）；
    /// - DTO `daily` 缺失 → nil；
    /// - 旧缓存无此键 → nil。
    var daily: [DailyForecast]? = nil
    /// 本次取数时间。
    var fetchedAt: Date

    // MARK: - 派生属性（不参与 Codable 存储）

    /// 月相，由 `fetchedAt` 纯计算得出。
    var moonPhase: MoonPhase {
        MoonCalculator.phase(for: fetchedAt)
    }
}

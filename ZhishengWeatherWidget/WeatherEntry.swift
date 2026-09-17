//
//  WeatherEntry.swift
//  ZhishengWeatherWidget（Widget target）
//
//  TimelineEntry：只有一个存储 = `resolution`（`WidgetEntryResolution`），
//  其余（payload / city / payloadStatus / displayCityName）都是**转发计算属性**
//  —— 故既有视图调用点零改动，而新增的来源 / 空因字段自动随 entry 下发。
//
//  F-C 语义收窄（R-C2）仍然成立：`payload` **仅当载荷属于本实例目标城市时才非 nil**
//  （旧：共享容器归属匹配；本轮：容器归属匹配或 L1 自力取数取回），
//  绝不拿其他城市的数据冒充（AC-C6）。
//
//  ⚠️ 本轮前提修订（原文件头「全程无网络、无同步阻塞调用」**作废**）：
//  小组件允许**自力取数**（L1）。数据阶梯 L0 容器 → L1 自力取数 → L2 如实空态，
//  见 docs/handover/ARCH-zhisheng-ios-widget-selfsufficiency.md。
//  故 `payload` 的语义新增一条：**可来自自力取数**（`dataSource == .selfFetched`，
//  此时 `updatedAt == 生成 entry 的时刻`，是真实且刚取回的数据，无折扣需标注）。
//
//  `WeatherEntry` 是 `TimelineEntry`：**非 Codable**，系统每次重新调用 provider
//  重建，因此改字段**无持久化兼容问题**。
//

import WidgetKit
import Foundation

/// 小组件时间线条目。
struct WeatherEntry: TimelineEntry {

    /// 条目时间。
    let date: Date
    /// 唯一存储：城市 + 载荷 + 状态 + 来源 + 空因（判定全在 Core，见 `WidgetDataResolver`）。
    let resolution: WidgetEntryResolution
    /// 底色三档（A3-5，per-instance AppIntent 参数；默认玻璃）。
    var backgroundStyle: WidgetBackgroundStyle = .glass

    // MARK: - 转发（既有视图调用点零改动）

    /// 下发的载荷；nil = 空态（随后有可操作提示）。
    ///
    /// 来源可能是共享容器（L0）或小组件自力取数（L1）——由 `resolution.dataSource` 区分。
    var payload: SharedWeatherPayload? { resolution.payload }
    /// 本实例解析出的目标城市；nil = 无城市（「请配置城市」空态）。
    var city: City? { resolution.city }
    /// 载荷状态（有无 / 新旧）。
    ///
    /// 由 Core 给出（L0 判定复用 `WidgetPayloadResolver`，已被单测覆盖）：
    ///   - `.available`：正常；
    ///   - `.stale`：有数据但过旧 → 照常渲染 + 标注「已过期」；
    ///   - `.missing`：从未写入 / 归属不匹配 / 该城市无数据 → 见 `emptyReason` 细分；
    ///   - `.unavailable`：共享容器不可用 / 载荷损坏 / 取数失败 → 见 `emptyReason` 细分。
    /// ⚠️ 视图**不要**再用 `==` 拼状态句：文案统一走 `WidgetCopy`（单一真源）。
    var payloadStatus: WidgetPayloadStatus { resolution.status }
    /// 视图取名唯一入口（实现与文案真源都在 Core 的 `WidgetCopy`）。
    var displayCityName: String? { WidgetCopy.cityText(resolution: resolution) }
}

// MARK: - 示例数据（空态 / 预览兜底）

extension WeatherSnapshot {
    /// 小组件无真实数据时使用的示例快照。
    static let placeholder = WeatherSnapshot(
        location: .beijing,
        temperature: 23,
        apparentTemperature: 21,
        weatherCode: 2,
        windSpeed: 3.2,
        windDirection: 135,
        humidity: 58,
        isDay: true,
        hourly: [],
        dailyHigh: 25,
        dailyLow: 15,
        fetchedAt: Date()
    )
}

extension SharedWeatherPayload {
    /// 示例载荷。
    static let placeholder = SharedWeatherPayload(snapshot: .placeholder, updatedAt: Date())
}

extension WidgetEntryResolution {
    /// 画廊预览 / 占位条目用的示例收敛值（city 传 nil，示例数据路径不变）。
    static let placeholder = WidgetEntryResolution(city: nil,
                                                  payload: .placeholder,
                                                  status: .available,
                                                  dataSource: .none,
                                                  emptyReason: nil)
}

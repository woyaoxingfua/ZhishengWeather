//
//  WeatherEntry.swift
//  ZhishengWeatherWidget（Widget target）
//
//  TimelineEntry：日期 + 载荷 + 实例目标城市。
//  同时提供 placeholder 示例数据，供 placeholder / snapshot 预览与空态渲染。
//
//  F-C 语义收窄（R-C2）：`payload` **仅当快照属于本实例目标城市时才非 nil**；
//  固定城市实例在归属不匹配时渲染"城市名 + --° + 暂无数据"（AC-C6），
//  绝不拿其他城市的数据冒充。
//

import WidgetKit
import Foundation

/// 小组件时间线条目。
struct WeatherEntry: TimelineEntry {
    /// 条目时间。
    let date: Date
    /// 共享容器中的载荷；F-C 起语义收窄：仅当快照归属匹配本实例目标城市才非 nil。
    let payload: SharedWeatherPayload?
    /// 本实例解析出的目标城市（F-C）；nil = 目录不可用 → 空态（AC-C9 空表兜底）。
    let city: City?
    /// 视图取名唯一入口：实例目标城市优先，回退快照 location（placeholder 预览路径）。
    var displayCityName: String? { city?.name ?? payload?.snapshot.location.name }
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

//
//  HistoricalWeather.swift
//  Core / Models  [App + Widget 共用]
//
//  历史天气领域模型（A3-1）。仅历史页消费，不进共享容器。
//  日期以 `yyyy-MM-dd` 字符串保留（Archive API 原生形态），展示层换算。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 历史单日记录。
struct HistoricalDay: Equatable, Identifiable, Sendable {

    /// 日期（ISO `yyyy-MM-dd`）。
    let dateString: String
    /// 日最高温（℃）。
    let tempMax: Double?
    /// 日最低温（℃）。
    let tempMin: Double?
    /// WMO 天气码。
    let weatherCode: Int?
    /// 日降水量合计（mm）。
    let precipitationSum: Double?

    /// 稳定标识（日期即唯一）。
    var id: String { dateString }
}

/// 近 N 日历史序列。
struct HistoricalWeather: Equatable, Sendable {

    /// 按日期升序的逐日记录。
    let days: [HistoricalDay]

    /// ERA5 再分析资料声明（页面脚注，AC-A2-3 / AC-A3-3）。
    static let dataSourceNotice = "再分析资料（ERA5），非实况观测"
}

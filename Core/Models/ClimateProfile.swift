//
//  ClimateProfile.swift
//  Core / Models  [App + Widget 共用]
//
//  个人气候档案领域模型：给定城市与“今天”，提取往年同日记录与派生统计。
//  所有字段一律 Optional + 默认 nil + 合成 Codable（禁手写 init(from:)、禁 payloadVersion）。
//  不进共享容器，仅存于页面内存。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 某年同月同日的气候快照（构成个人气候档案的基本单元）。
struct DailyClimateSnapshot: Codable, Equatable, Identifiable, Sendable {

    /// 公历年份。
    var year: Int
    /// 原始日期字符串（yyyy-MM-dd）。
    var dateString: String
    /// 当日最高温（℃）；nil = 该日无有效数据。
    var tempMax: Double? = nil
    /// 当日最低温（℃）；nil = 该日无有效数据。
    var tempMin: Double? = nil
    /// 当日 WMO 天气码；nil = 无有效数据。
    var weatherCode: Int? = nil

    /// 以年份作为稳定标识（ForEach 用）。
    var id: Int { year }
}

/// 个人气候档案：去年今日、近 5 年 / 10 年同日集合，以及相对今年的平均高温差值。
struct ClimateProfile: Codable, Equatable, Sendable {

    /// 去年今日。
    var sameDateLastYear: DailyClimateSnapshot? = nil
    /// 近 5 年同日（不含今年），按年份升序；nil = 无有效样本。
    var sameDateLast5Years: [DailyClimateSnapshot]? = nil
    /// 近 10 年同日（不含今年），按年份升序；nil = 无有效样本。
    var sameDateLast10Years: [DailyClimateSnapshot]? = nil
    /// 近 5 年同日平均最高温；nil = 无有效样本。
    var fiveYearAverageHigh: Double? = nil
    /// 近 10 年同日平均最高温；nil = 无有效样本。
    var tenYearAverageHigh: Double? = nil
    /// 近 5 年同日平均最高温较今年今日最高温的差值（平均 − 今年）；nil = 缺今年高温。
    var fiveYearHighDelta: Double? = nil
    /// 近 10 年同日平均最高温较今年今日最高温的差值；nil = 缺今年高温。
    var tenYearHighDelta: Double? = nil
}

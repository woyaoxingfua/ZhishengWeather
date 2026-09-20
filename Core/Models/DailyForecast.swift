//
//  DailyForecast.swift
//  Core / Models  [App + Widget 共用]
//
//  F-A 逐日预报：单个自然日的领域点。
//  风格与 `HourlyPoint` 保持一致：Codable + Equatable + Identifiable + Sendable。
//
//  v1.1 修订（A1-4）：追加可选 `sunrise` / `sunset`（按日存，而非只在
//  snapshot 存今天 —— A2-5「逐日行展开看日落」直接复用，避免二次迁移，
//  ARCH-A1 §1.4）。全部可选 + 合成 Codable，旧缓存解码不失败。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 逐日预报中的一个自然日。
struct DailyForecast: Codable, Equatable, Identifiable, Sendable {

    /// 当日零点（epoch 秒解析而来；Open-Meteo daily.time = 当地当日 00:00）。
    var date: Date
    /// 当日 WMO 天气码。
    var weatherCode: Int
    /// 当日最高温（℃）。
    var tempMax: Double
    /// 当日最低温（℃）。
    var tempMin: Double
    /// 当日最大降水概率（%）。
    /// nil = 服务端未返回 / null → UI 显示 "--"，**绝不显示 0%**（AC-A5）。
    var precipitationProbability: Int?
    /// 当日日出（A1 新增，可选）。
    /// 由 mapper 归一：epoch 形态直译 `Date(timeIntervalSince1970:)`，
    /// ISO 形态经 `ISOTimeStringDecoder`；
    /// nil = 值缺失 / 解析失败 / 旧缓存无此键（UI 隐藏该段）。
    var sunrise: Date? = nil
    /// 当日日落（A1 新增，可选）。语义同 `sunrise`。
    var sunset: Date? = nil
    /// 当日 UV 指数峰值（A2 新增，可选）。
    /// nil = 服务端未返回 / 元素 null / 旧缓存无此键（A2-5 逐日展开直接复用）。
    var uvIndexMax: Double? = nil
    /// P2 数据补全：当日降水合计（mm）。可选：
    /// nil = 服务端未返回 / 元素 null / 旧缓存无此键。`0 mm` 是合法值（UI 原样显示），
    /// 只有 nil 才显示 "--"（与 precipitation_sum = 0 必须区分）。
    var precipitationSum: Double? = nil
    /// P2 数据补全：当日液态降水合计（mm）。可选，nil 语义同上。
    var rainSum: Double? = nil
    /// P2 数据补全：当日降雪合计（**cm**，Open-Meteo 原值；UI 换算归展示层）。可选，nil 语义同上。
    var snowfallSum: Double? = nil
    /// P2 数据补全：当日最大风速（m/s）。可选，nil 语义同上。
    var windSpeedMax: Double? = nil
    /// P2 数据补全：当日最大阵风（m/s）。可选，nil 语义同上。
    var windGustsMax: Double? = nil
    /// P2 数据补全：当日主导风向（度，0=北顺时针；Open-Meteo 原值）。可选，nil 语义同上。
    var windDirectionDominant: Double? = nil
    /// P2 数据补全：当日昼长（**秒**，Open-Meteo 原值；UI 换算为「X 小时 Y 分」）。
    /// 可选，nil 语义同上。⚠️ **昼长 ≠ 日照时数**，二者语义不同，UI 不许共用一个标签。
    var daylightDuration: Double? = nil
    /// P2 数据补全：当日日照时数（**秒**，Open-Meteo 原值；UI 换算为「X 小时 Y 分」）。
    /// 可选，nil 语义同上。⚠️ **日照时数 ≠ 昼长**（见 `daylightDuration`），UI 不许共用一个标签。
    var sunshineDuration: Double? = nil
    /// P2 数据补全：当日体感高温（℃）。可选，nil 语义同上。
    var apparentTemperatureMax: Double? = nil
    /// P2 数据补全：当日体感低温（℃）。可选，nil 语义同上。
    var apparentTemperatureMin: Double? = nil

    /// 以日期作为稳定标识（自然日唯一）。
    var id: Date { date }

    // MARK: - P2 数据补全：展开详情的展示文案（纯函数，便于单测）

    /// 日降水合计文案（mm）。nil → nil（对应段不渲染）。
    /// `0 mm` 是合法值，原样显示；只有 nil 才返回 nil（UI 显示 "--"）。
    /// 单位 mm 由 `PrecipitationFormatter` 锁定（换算责任层），此处只负责前缀与 nil 隐藏。
    var precipitationSumText: String? {
        guard let sum = precipitationSum else { return nil }
        return "降水 " + PrecipitationFormatter.text(fromMillimeters: sum)
    }

    /// 日降雪合计文案（**cm**，Open-Meteo 原值）。nil → nil（对应段不渲染）。
    /// `0 cm` 是合法值，原样显示；只有 nil 才返回 nil。
    /// 单位 cm 由 `SnowfallFormatter` 锁定（换算责任层，禁止改为 mm），
    /// 此处只负责前缀与 nil 隐藏。
    var snowfallSumText: String? {
        guard let sum = snowfallSum else { return nil }
        return "降雪 " + SnowfallFormatter.text(fromCentimeters: sum)
    }

    /// 风摘要文案：按可用值拼接「最大风 / 阵风 / 主导风向」，中间用 " · " 连接。
    /// 三段全 nil → nil（对应段不渲染）。主导风向经 `WindDirectionFormatter`
    /// 转为 8 方位中文（与实况风同向算法，单一真相源）。
    var windSummaryText: String? {
        var parts: [String] = []
        if let max = windSpeedMax {
            parts.append("最大风 \(String(format: "%.1f", max)) m/s")
        }
        if let gust = windGustsMax {
            parts.append("阵风 \(String(format: "%.1f", gust)) m/s")
        }
        if let dir = windDirectionDominant {
            parts.append("主导风向 \(WindDirectionFormatter.text(from: dir))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 体感高低温文案：与实测高低温分列显示，不合并成一个数字。
    /// 至少一个非 nil 才出段（某一边 nil 只显示可用的一边的温度）。
    var apparentSummaryText: String? {
        var parts: [String] = []
        if let max = apparentTemperatureMax { parts.append("\(Int(max.rounded()))°") }
        if let min = apparentTemperatureMin { parts.append("\(Int(min.rounded()))°") }
        guard !parts.isEmpty else { return nil }
        return "体感 " + parts.joined(separator: " / ")
    }

    /// 昼长文案（秒 → 「X 小时 Y 分」）。nil → nil（对应段不渲染）。
    /// 与 `sunshineText` 分标签：昼长 ≠ 日照时数。
    var daylightText: String? {
        guard let seconds = daylightDuration else { return nil }
        return "昼长 " + DurationFormatter.hoursMinutesText(fromSeconds: seconds)
    }

    /// 日照时数文案（秒 → 「X 小时 Y 分」）。nil → nil（对应段不渲染）。
    /// 与 `daylightText` 分标签：日照时数 ≠ 昼长。
    var sunshineText: String? {
        guard let seconds = sunshineDuration else { return nil }
        return "日照 " + DurationFormatter.hoursMinutesText(fromSeconds: seconds)
    }
}

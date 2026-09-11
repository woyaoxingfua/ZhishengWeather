//
//  WMOCodeMapper.swift
//  Core / Logic  [App + Widget 共用]
//
//  WMO 0–99 天气码 → SF Symbol（含夜版）+ 中文现象名；未知码兜底。
//  纯函数、无状态、无网络。
//

import Foundation

/// 一个天气码对应的展示信息。
struct WeatherCondition: Equatable, Sendable {
    /// 日间 SF Symbol 名。
    let symbolName: String
    /// 夜间 SF Symbol 名。
    let nightSymbolName: String
    /// 中文现象名。
    let description: String
}

/// WMO 天气码映射器。
enum WMOCodeMapper {

    /// 未知码兜底：问号图标 + 「未知」。
    static let unknown = WeatherCondition(
        symbolName: "questionmark.circle.fill",
        nightSymbolName: "questionmark.circle.fill",
        description: "未知"
    )

    /// 依据天气码与昼夜，返回对应展示信息（未知码返回 `unknown`）。
    static func condition(for code: Int, isDay: Bool) -> WeatherCondition {
        let base: WeatherCondition
        switch code {
        case 0:
            base = WeatherCondition(symbolName: "sun.max.fill",
                                    nightSymbolName: "moon.stars.fill",
                                    description: "晴")
        case 1:
            base = WeatherCondition(symbolName: "sun.max.fill",
                                    nightSymbolName: "moon.fill",
                                    description: "晴间多云")
        case 2:
            base = WeatherCondition(symbolName: "cloud.sun.fill",
                                    nightSymbolName: "cloud.moon.fill",
                                    description: "多云")
        case 3:
            base = WeatherCondition(symbolName: "cloud.fill",
                                    nightSymbolName: "cloud.fill",
                                    description: "阴")
        case 45, 48:
            base = WeatherCondition(symbolName: "cloud.fog.fill",
                                    nightSymbolName: "cloud.fog.fill",
                                    description: code == 45 ? "有雾" : "雾凇")
        case 51:
            base = WeatherCondition(symbolName: "cloud.drizzle.fill",
                                    nightSymbolName: "cloud.drizzle.fill",
                                    description: "小毛毛雨")
        case 53:
            base = WeatherCondition(symbolName: "cloud.drizzle.fill",
                                    nightSymbolName: "cloud.drizzle.fill",
                                    description: "毛毛雨")
        case 55:
            base = WeatherCondition(symbolName: "cloud.drizzle.fill",
                                    nightSymbolName: "cloud.drizzle.fill",
                                    description: "大毛毛雨")
        case 56, 57:
            base = WeatherCondition(symbolName: "cloud.sleet.fill",
                                    nightSymbolName: "cloud.sleet.fill",
                                    description: code == 56 ? "轻冻雨" : "冻毛毛雨")
        case 61:
            base = WeatherCondition(symbolName: "cloud.rain.fill",
                                    nightSymbolName: "cloud.rain.fill",
                                    description: "小雨")
        case 63:
            base = WeatherCondition(symbolName: "cloud.rain.fill",
                                    nightSymbolName: "cloud.rain.fill",
                                    description: "中雨")
        case 65:
            base = WeatherCondition(symbolName: "cloud.heavyrain.fill",
                                    nightSymbolName: "cloud.heavyrain.fill",
                                    description: "大雨")
        case 66, 67:
            base = WeatherCondition(symbolName: "cloud.sleet.fill",
                                    nightSymbolName: "cloud.sleet.fill",
                                    description: code == 66 ? "冻雨" : "强冻雨")
        case 71:
            base = WeatherCondition(symbolName: "cloud.snow.fill",
                                    nightSymbolName: "cloud.snow.fill",
                                    description: "小雪")
        case 73:
            base = WeatherCondition(symbolName: "cloud.snow.fill",
                                    nightSymbolName: "cloud.snow.fill",
                                    description: "中雪")
        case 75:
            base = WeatherCondition(symbolName: "cloud.snow.fill",
                                    nightSymbolName: "cloud.snow.fill",
                                    description: "大雪")
        case 77:
            base = WeatherCondition(symbolName: "cloud.snow.fill",
                                    nightSymbolName: "cloud.snow.fill",
                                    description: "米雪")
        case 80:
            base = WeatherCondition(symbolName: "cloud.sun.rain.fill",
                                    nightSymbolName: "cloud.moon.rain.fill",
                                    description: "小阵雨")
        case 81:
            base = WeatherCondition(symbolName: "cloud.sun.rain.fill",
                                    nightSymbolName: "cloud.moon.rain.fill",
                                    description: "阵雨")
        case 82:
            base = WeatherCondition(symbolName: "cloud.heavyrain.fill",
                                    nightSymbolName: "cloud.heavyrain.fill",
                                    description: "强阵雨")
        case 85:
            base = WeatherCondition(symbolName: "cloud.snow.fill",
                                    nightSymbolName: "cloud.snow.fill",
                                    description: "小阵雪")
        case 86:
            base = WeatherCondition(symbolName: "cloud.snow.fill",
                                    nightSymbolName: "cloud.snow.fill",
                                    description: "强阵雪")
        case 95:
            base = WeatherCondition(symbolName: "cloud.bolt.rain.fill",
                                    nightSymbolName: "cloud.bolt.rain.fill",
                                    description: "雷阵雨")
        case 96:
            base = WeatherCondition(symbolName: "cloud.bolt.rain.fill",
                                    nightSymbolName: "cloud.bolt.rain.fill",
                                    description: "雷阵雨伴冰雹")
        case 99:
            base = WeatherCondition(symbolName: "cloud.bolt.rain.fill",
                                    nightSymbolName: "cloud.bolt.rain.fill",
                                    description: "雷暴伴强冰雹")
        default:
            return unknown
        }
        return base
    }

    /// 依据天气码与昼夜，返回对应 SF Symbol 名。
    static func symbolName(for code: Int, isDay: Bool) -> String {
        let condition = condition(for: code, isDay: isDay)
        return isDay ? condition.symbolName : condition.nightSymbolName
    }

    /// 依据天气码，返回中文现象名。
    static func description(for code: Int) -> String {
        condition(for: code, isDay: true).description
    }
}

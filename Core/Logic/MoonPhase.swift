//
//  MoonPhase.swift
//  Core / Logic  [App + Widget 共用]
//
//  月相值对象：名称枚举、照亮比例、SF Symbol、月龄。
//

import Foundation

/// 某一时刻的月相。
struct MoonPhase: Codable, Equatable, Sendable {

    /// 八相月相名称。
    enum Name: String, Codable, Sendable {
        case newMoon        = "朔月"
        case waxingCrescent = "娥眉月"
        case firstQuarter   = "上弦月"
        case waxingGibbous  = "盈凸月"
        case fullMoon       = "满月"
        case waningGibbous  = "亏凸月"
        case lastQuarter    = "下弦月"
        case waningCrescent = "残月"

        /// 对应的 SF Symbol（`moonphase.*`）。
        var symbolName: String {
            switch self {
            case .newMoon:        return "moonphase.new.moon"
            case .waxingCrescent: return "moonphase.waxing.crescent"
            case .firstQuarter:   return "moonphase.first.quarter"
            case .waxingGibbous:  return "moonphase.waxing.gibbous"
            case .fullMoon:       return "moonphase.full.moon"
            case .waningGibbous:  return "moonphase.waning.gibbous"
            case .lastQuarter:    return "moonphase.last.quarter"
            case .waningCrescent: return "moonphase.waning.crescent"
            }
        }
    }

    /// 月相名称。
    let name: Name
    /// 照亮比例（0.0 – 1.0）。
    let illumination: Double
    /// SF Symbol 名（`moonphase.*`）。
    let symbolName: String
    /// 月龄（天，0 – 29.53）。
    let age: Double

    /// 照亮比例的百分比整数（0–100）。
    var illuminationPercent: Int {
        Int((illumination * 100).rounded())
    }
}

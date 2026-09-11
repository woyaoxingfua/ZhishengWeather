//
//  MoonCalculator.swift
//  Core / Logic  [App + Widget 共用]
//
//  纯函数月相算法（不依赖网络/UI/当前时间）。
//  采用平均朔望月 + 已知新月锚点的近似算法，与真实月相误差 ≤ 1 天（满足 AC）。
//
//  约束：禁止内部调用 `Date()`；所有输入时刻由参数传入。
//

import Foundation

/// 月相计算器（纯函数）。
enum MoonCalculator {

    /// 平均朔望月长度（天）。
    static let synodicMonth: Double = 29.530588853

    /// 已知新月锚点：2000-01-06 18:14 UTC 的 epoch 秒。
    static let referenceNewMoonEpoch: Double = 947_182_440

    /// 距离上一个新月的月龄（天，0 – synodicMonth）。
    static func age(for date: Date) -> Double {
        let days = (date.timeIntervalSince1970 - referenceNewMoonEpoch) / 86_400.0
        var value = days.truncatingRemainder(dividingBy: synodicMonth)
        if value < 0 { value += synodicMonth }
        return value
    }

    /// 照亮比例（0.0 – 1.0）。新月为 0，满月为 1。
    static func illumination(for date: Date) -> Double {
        let phaseAngle = 2.0 * Double.pi * age(for: date) / synodicMonth
        let value = (1.0 - cos(phaseAngle)) / 2.0
        // 收敛浮点误差，保证落在 [0, 1]。
        return min(max(value, 0.0), 1.0)
    }

    /// 依据时刻计算完整月相。
    static func phase(for date: Date) -> MoonPhase {
        let currentAge = age(for: date)
        let fraction = currentAge / synodicMonth
        let name = name(forFraction: fraction)
        let illum = illumination(for: date)
        return MoonPhase(name: name,
                         illumination: illum,
                         symbolName: name.symbolName,
                         age: currentAge)
    }

    // MARK: - Private

    /// 将一个朔望周期按 8 等分（每份 1/8，各相居中于四个象限点）判定月相名。
    private static func name(forFraction fraction: Double) -> MoonPhase.Name {
        switch fraction {
        case ..<0.0625:            return .newMoon          // 朔：±1/16 内
        case ..<0.1875:            return .waxingCrescent
        case ..<0.3125:            return .firstQuarter
        case ..<0.4375:            return .waxingGibbous
        case ..<0.5625:            return .fullMoon
        case ..<0.6875:            return .waningGibbous
        case ..<0.8125:            return .lastQuarter
        case ..<0.9375:            return .waningCrescent
        default:                   return .newMoon
        }
    }
}

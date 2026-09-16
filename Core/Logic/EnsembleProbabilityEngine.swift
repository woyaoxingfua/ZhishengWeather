//
//  EnsembleProbabilityEngine.swift
//  Core / Logic  [App + Widget 共用]
//
//  集合证据推导（纯函数，无 IO / 无内部 Date()）——本特性的「可测核心」。
//
//  设计目的（产品转向：从「显示数字」到「支持决策」）：不打印裸的「降水概率 60%」，
//  而是展示**集合证据**——「N 个成员中 M 个认为有雨」+ 成员分歧（离散度）。
//
//  两种推导（均纯函数）：
//   ① 逐小时：统计各成员在该小时的降水取值 → 有效成员数 N_i、超阈值成员数 M_i、
//      比例 M_i/N_i，以及 min / p25 / p75 / max（离散度）。
//   ② 窗口聚合：某成员在**窗口内任一小时**超阈值即记「该成员认为有雨」→ 窗口级
//      N（成员数）与 M（认为有雨的成员数）。用于「N 个成员中 M 个认为…」的标题句。
//
//  阈值：`rainThreshold = 0.1 mm/h`（> 0.1 mm/h 视为「有雨」；0 与微量不计）。
//
//  分位法（冻结口径）：线性插值法（等价 Excel PERCENTILE.INC / numpy 默认 linear）：
//      rank = p × (n − 1)；lower = ⌊rank⌋，upper = ⌈rank⌉；
//      若 lower == upper → 取 sorted[lower]；否则按小数权重在两者间线性插值。
//      n == 1 → 取该唯一值。Empty → 0。
//
//  一切「成员数」均从数据派生，**绝不硬编码 30**（成员数随模式 1/30/40/50…）。
//
//  Core 纪律：仅 import Foundation；纯函数；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 单小时集合证据。
struct EnsembleHourEvidence: Equatable, Sendable {
    /// 该小时时刻。
    var time: Date
    /// 超阈值（≥ rainThreshold）的成员数 M_i。
    var wetCount: Int
    /// 该小时有效成员数 N_i（取值非 nil 的成员）。
    var memberCount: Int
    /// 成员比例 M_i / N_i（N_i == 0 → 0）。
    var fraction: Double
    /// 成员降水最小值（mm）。
    var minValue: Double
    /// 成员降水 25 分位（mm）。
    var p25: Double
    /// 成员降水 75 分位（mm）。
    var p75: Double
    /// 成员降水最大值（mm）。
    var maxValue: Double
}

/// 集合证据（窗口级 + 逐小时）。
struct EnsembleEvidence: Equatable, Sendable {
    /// 成员数 N（来自数据，绝不硬编码）。
    var memberCount: Int
    /// 逐小时证据（与 `EnsembleForecast.times` 等长）。
    var hourly: [EnsembleHourEvidence]
    /// 窗口内「任一小时超阈值」的成员数 M（标题句「N 个成员中 M 个认为…」）。
    var wetMemberCount: Int
    /// 比例最高的时段（平局取更早者）；无数据时为 nil。
    var peakHour: EnsembleHourEvidence?
    /// 判定阈值（mm/h）。
    var threshold: Double
}

/// 集合概率推导引擎（纯函数 enum）。
enum EnsembleProbabilityEngine {

    /// 「有雨」阈值：> 0.1 mm/h。0 与微量不计。
    static let rainThreshold: Double = 0.1

    /// 由领域模型推导集合证据。
    /// - Parameter forecast: 集合预报领域模型。
    /// - Returns: 证据；`times` 为空或成员数为 0（无可用集合）→ nil（UI 整块隐藏）。
    static func evidence(for forecast: EnsembleForecast) -> EnsembleEvidence? {
        guard !forecast.times.isEmpty, forecast.memberCount >= 1 else { return nil }

        // ① 逐小时。
        var hourly: [EnsembleHourEvidence] = []
        hourly.reserveCapacity(forecast.times.count)
        for (index, time) in forecast.times.enumerated() {
            // 收集该小时全部有效成员值（越界 / nil 一律跳过）。
            let values: [Double] = forecast.memberSeries.compactMap { series -> Double? in
                guard index < series.count else { return nil }
                return series[index]
            }
            let stats = statistics(values)
            let fraction = stats.memberCount > 0
                ? Double(stats.wetCount) / Double(stats.memberCount)
                : 0
            hourly.append(EnsembleHourEvidence(time: time,
                                               wetCount: stats.wetCount,
                                               memberCount: stats.memberCount,
                                               fraction: fraction,
                                               minValue: stats.min,
                                               p25: stats.p25,
                                               p75: stats.p75,
                                               maxValue: stats.max))
        }

        // ② 窗口聚合：某成员任一小时超阈值即「认为有雨」。
        let wetMemberCount = forecast.memberSeries.reduce(0) { running, series in
            let isWet = series.contains { value in
                guard let value else { return false }
                return value >= rainThreshold
            }
            return running + (isWet ? 1 : 0)
        }

        // 峰值时段：比例最高；平局取更早时刻（确定性，不依赖 max(by:) 的并列语义）。
        var peakHour: EnsembleHourEvidence? = nil
        for hour in hourly {
            guard let current = peakHour else {
                peakHour = hour
                continue
            }
            if hour.fraction > current.fraction
                || (hour.fraction == current.fraction && hour.time < current.time) {
                peakHour = hour
            }
        }

        return EnsembleEvidence(memberCount: forecast.memberCount,
                                hourly: hourly,
                                wetMemberCount: wetMemberCount,
                                peakHour: peakHour,
                                threshold: rainThreshold)
    }

    // MARK: - Private

    /// 单元组统计（有效成员数 / 超阈成员数 / min / p25 / p75 / max）。
    /// - Parameter values: 该小时的有效成员值（已非 nil）。
    /// - Returns: 统计元组；空输入 → 全 0。
    private static func statistics(_ values: [Double])
        -> (memberCount: Int, wetCount: Int, min: Double, p25: Double, p75: Double, max: Double) {
        guard !values.isEmpty else {
            return (0, 0, 0, 0, 0, 0)
        }
        let sorted = values.sorted()
        let wetCount = sorted.filter { $0 >= rainThreshold }.count
        let minimum = sorted.first ?? 0
        let maximum = sorted.last ?? 0
        return (sorted.count,
                wetCount,
                minimum,
                percentile(sorted, 0.25),
                percentile(sorted, 0.75),
                maximum)
    }

    /// 线性插值分位（Excel PERCENTILE.INC / numpy linear；见文件头冻结口径）。
    /// - Parameters:
    ///   - sorted: 升序排列的数值。
    ///   - p: 分位（0…1）。
    /// - Returns: 分位值；空输入 → 0。
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        if lower == upper { return sorted[lower] }
        let weight = rank - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}

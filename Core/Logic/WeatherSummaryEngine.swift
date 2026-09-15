//
//  WeatherSummaryEngine.swift
//  Core / Logic  [App + Widget 共用]
//
//  一句话天气摘要引擎（A2-2，纯函数，ARCH-A2 §1.2）：
//   - 输入仅来自 `WeatherSnapshot`（A1 的 yesterday + A2 的 hourly 降水概率
//     与 daily uvIndexMax），无网络、无系统时钟依赖（"约 N 分钟"由 hourly
//     time 相对偏移推导）——保证单测确定性（run12 教训）。
//   - 优先级固定（AC-A2-7）：预警位 > 强降水 > 温差 > 风 > UV，命中首条即返回。
//   - 返回 nil = 无规则命中（AC-A2-8）→ ContentView 整行隐藏，不显示空槽。
//
//  Core 纪律：仅 import Foundation；纯函数；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 一句话天气摘要引擎（纯函数）。
enum WeatherSummaryEngine {

    // MARK: - 阈值（D-A2-2 备案：首版经验值，产品可调）

    /// 强降水概率阈值（%）。
    static let heavyRainProbabilityThreshold: Double = 50
    /// 强降水扫描窗口（秒）：未来 2 小时。
    static let rainLookaheadSeconds: TimeInterval = 2 * 3_600
    /// 温差阈值（℃，绝对值）。
    static let temperatureDeltaThreshold: Double = 2
    /// 大风阈值（m/s）。
    static let windSpeedThreshold: Double = 10
    /// UV 阈值（中等偏强起步）。
    static let uvIndexThreshold: Double = 6

    /// 计算一句话摘要；nil = 无规则命中（隐藏整行）。
    static func summary(for snapshot: WeatherSnapshot) -> String? {
        // ① 预警位（A3 预留）：无预警数据源，永久不命中。锚点注释供未来接入。
        if let alert = alertSummary(for: snapshot) { return alert }

        // ② 强降水（优先级最高，含亚小时表达）。
        if let rain = rainSummary(for: snapshot) { return rain }

        // ③ 温差（今日高温 vs 昨日高温）。
        if let delta = temperatureSummary(for: snapshot) { return delta }

        // ④ 大风。
        if let wind = windSummary(for: snapshot) { return wind }

        // ⑤ UV。
        if let uv = uvSummary(for: snapshot) { return uv }

        return nil
    }

    // MARK: - 规则实现（internal 便于单测逐条命中）

    /// ① 预警位：A3 接入国内源后实现；当前恒 nil（预留 no-op 锚点）。
    static func alertSummary(for snapshot: WeatherSnapshot) -> String? {
        nil
    }

    /// ② 强降水：自"当前小时"（snapshot.hourly[0]，截窗起点即当前小时）起
    /// 扫描未来 2 小时窗口；首个 ≥50% 点 → "约 N 分钟后可能下雨"；
    /// 窗口内全部 <50% → "两小时内无雨"。hourly 为空 / 概率全 nil → nil（不命中）。
    static func rainSummary(for snapshot: WeatherSnapshot) -> String? {
        let points = snapshot.hourly
        guard !points.isEmpty else { return nil }

        // 截窗起点 = snapshot.hourly[0]（mapper window 保证 time[0] ≈ 当前小时）。
        let anchor = points[0].time

        for (offset, point) in points.enumerated() {
            // 只扫 2 小时窗口（含当前小时共 3 个点：offset 0…2）。
            let elapsed = point.time.timeIntervalSince(anchor)
            guard elapsed <= rainLookaheadSeconds else { break }
            // 当前小时正在下雨概率也高 → "可能下雨"（N=0 表述为"当前时段"）。
            guard let probability = point.precipitationProbability,
                  probability >= heavyRainProbabilityThreshold else { continue }
            let minutes = Int(elapsed / 60.0)
            if minutes <= 0 {
                return "当前时段可能下雨，出门带伞"
            }
            return "约 \(minutes) 分钟后可能下雨"
        }
        // 窗口内无强降水点 → 若窗口内确有概率数据则报"无雨"，无数据则不命中。
        let hasData = points.prefix(3).contains { $0.precipitationProbability != nil }
        return hasData ? "两小时内无雨" : nil
    }

    /// ③ 温差：今日高温 vs 昨日高温差 ≥2℃ → "较昨天 ±N°"。
    /// yesterday 缺失（A1 边界）→ 不命中。
    static func temperatureSummary(for snapshot: WeatherSnapshot) -> String? {
        guard let yesterday = snapshot.yesterday else { return nil }
        let delta = snapshot.dailyHigh - yesterday.tempMax
        guard abs(delta) >= temperatureDeltaThreshold else { return nil }
        let sign = delta > 0 ? "+" : "−"
        return "较昨天\(sign)\(Int(abs(delta.rounded())))°"
    }

    /// ④ 大风：windSpeed ≥10 m/s → "大风注意"。
    static func windSummary(for snapshot: WeatherSnapshot) -> String? {
        guard snapshot.windSpeed >= windSpeedThreshold else { return nil }
        return "大风注意"
    }

    /// ⑤ UV：今日 uvIndexMax ≥6 → 防晒提示。
    /// 今日行取 snapshot.daily[0]（mapper 保证自今日起截）。
    static func uvSummary(for snapshot: WeatherSnapshot) -> String? {
        guard let uv = snapshot.daily?.first?.uvIndexMax,
              uv >= uvIndexThreshold else { return nil }
        return "紫外线较强，注意防晒"
    }
}

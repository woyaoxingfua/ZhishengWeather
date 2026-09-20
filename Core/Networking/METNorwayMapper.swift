//
//  METNorwayMapper.swift
//  Core / Networking  [App + Widget 共用]
//
//  第三源 DTO → 领域补丁（纯函数）。
//
//  **时间处理**：`properties.timeseries` 是**逐小时、UTC（`...Z`）**的序列，
//  而 `fetchFields` 只给一个 `now` → 取**离 `now` 最近的那一条**（|差值| 最小），
//  用它的 `instant.details` 作为"当前"读数。
//  诚实说明：这是 MET 序列里**离 now 最近的一格原值**，**不是插值、不是估算**；
//  序列为空 / 时刻不可解析 → 空补丁（下游显示 `--`，绝不用假值填）。
//
//  **时间解码走既有路径**（ARCH §4.1 AD-5：强制 `ISOTimeStringDecoder`，
//  不得新造第二套时间解码）：MET 契约恒为 UTC（`...Z`），故剥掉尾部 `Z`/`z`
//  后以 `utcOffsetSeconds: 0` 解释墙钟。
//  ⚠️ 若对端某天改成**显式非 UTC 偏移**（如 `+02:00`），本实现返回 **nil**
//  （该条被跳过、宁缺不猜），**绝不**把带偏移的墙钟当 UTC 硬解 ——
//  那会让时刻**静默偏移若干小时**（无报错、无崩溃，最坏的一类缺陷）。
//
//  **诚实纪律**：`0` 与"缺失"严格区分（`.number(0)` 是有效取值，不是缺失）；
//  绝不写估算值 / 默认值，绝不静默换城市。
//
//  Core 纪律：仅 import Foundation；纯函数；禁 UIKit / 内部 Date() / try! / fatalError。
//  （`now` 由调用方注入，本 mapper 不取时钟。）
//

import Foundation

/// 第三源 DTO → 领域补丁映射器（纯函数）。
enum METNorwayMapper {

    /// 映射。
    ///
    /// - Parameters:
    ///   - response: 解码后的 DTO。
    ///   - now: 采集时刻（调用方注入，写入 `FieldPatch.capturedAt`）。
    /// - Returns: 稀疏字段补丁；无效 / 空序列 → 全 nil 空补丁（不崩、不抛）。
    static func map(_ response: METNorwayResponse, now: Date) -> FieldPatch {
        var patch = FieldPatch(sourceID: .metNorwayForecast, capturedAt: now)

        guard let entry = nearestEntry(in: response.properties?.timeseries, to: now),
              let details = entry.data?.instant?.details else {
            return patch
        }

        // 逐字段写入 —— 未命中的字段保持「缺失」，与「值是 0」严格区分。
        if let value = details.air_temperature { patch.set(.temperature, .number(value)) }
        if let value = details.air_pressure_at_sea_level { patch.set(.pressure, .number(value)) }
        if let value = details.relative_humidity { patch.set(.humidity, .number(value)) }
        if let value = details.cloud_area_fraction { patch.set(.cloudCover, .number(value)) }
        if let value = details.wind_speed { patch.set(.windSpeed, .number(value)) }
        if let value = details.wind_from_direction { patch.set(.windDirection, .number(value)) }
        return patch
    }

    // MARK: - Private

    /// 取离 `now` **最近**的一条（|时间差| 最小）。
    ///
    /// - 时刻缺失 / 不可解析的条目**跳过**（绝不把它当作 0 或当前时刻）；
    /// - 并列最小（理论上不会发生：序列是整点步长）时取**序列中靠前**的那条
    ///   （遍历用严格小于，故第一个最小者胜出，结果确定）。
    ///
    /// - Parameters:
    ///   - timeseries: 序列（可为 nil / 空）。
    ///   - now: 注入的采集时刻。
    /// - Returns: 最近的一条；无可解析条目 → nil。
    private static func nearestEntry(in timeseries: [METNorwayResponse.Entry?]?,
                                    to now: Date) -> METNorwayResponse.Entry? {
        var best: METNorwayResponse.Entry?
        var bestDistance: TimeInterval?

        for entry in timeseries ?? [] {
            guard let entry,
                  let timeText = entry.time,
                  let time = absoluteDate(from: timeText) else { continue }

            let distance = abs(time.timeIntervalSince(now))
            if let current = bestDistance, distance >= current { continue }
            best = entry
            bestDistance = distance
        }
        return best
    }

    /// "2026-09-20T05:00:00Z" → 绝对时刻（走既有 `ISOTimeStringDecoder`）。
    ///
    /// - 尾部 `Z` / `z` → 剥掉后按 UTC 墙钟解释；
    /// - **显式非 UTC 偏移**（T 之后的 `+HH:MM` / `-HH:MM`）→ nil（宁缺不猜）；
    /// - 无偏移后缀 → 按本源契约（恒 UTC）解释。
    ///
    /// - Parameter string: ISO 时间串。
    /// - Returns: 绝对时刻；格式不符 / 偏移为非 UTC → nil。
    private static func absoluteDate(from string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasSuffix("Z") || trimmed.hasSuffix("z") {
            return ISOTimeStringDecoder.date(from: String(trimmed.dropLast()), utcOffsetSeconds: 0)
        }

        // 显式非 UTC 偏移一律拒绝：日期段的 '-' 在 T 之前，故只看 T 之后即可。
        if let tIndex = trimmed.firstIndex(of: "T") {
            let afterT = trimmed[trimmed.index(after: tIndex)...]
            if afterT.contains("+") || afterT.contains("-") { return nil }
        }

        // 无偏移后缀 → 本源文档口径为 UTC，按 UTC 解释（与既有第二源 mapper 同一处理）。
        return ISOTimeStringDecoder.date(from: trimmed, utcOffsetSeconds: 0)
    }
}

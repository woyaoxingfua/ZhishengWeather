//
//  SunriseSunsetMapper.swift
//  Core / Networking  [App + Widget 共用]
//
//  第二源 DTO → 领域补丁（纯函数，时间归一为绝对时刻）。
//
//  **时间归一纪律（ARCH §4.1 AD-5：强制走 ISOTimeStringDecoder，不得新写时间解码）**：
//  api.sunrise-sunset.org 恒返回 UTC（响应 `tzid="UTC"`，时间带 `+00:00` 偏移），
//  故剥离偏移后缀后以 `utcOffsetSeconds: 0` 解释墙钟，得到与偏移一致的绝对时刻
//  （与 ISOTimeStringDecoder「按该偏移下的墙钟」语义一致）。
//
//  **诚实纪律**：status != "OK" 或 results 缺失 → 返回全 nil 的空补丁（不崩、不抛）。
//
//  Core 纪律：仅 import Foundation；纯函数；禁 UIKit / 内部 Date() / try! / fatalError。
//  （`now` 由调用方注入，本 mapper 不取时钟。）
//

import Foundation

/// 第二源 DTO → 领域补丁映射器（纯函数）。
enum SunriseSunsetMapper {

    /// 映射。
    ///
    /// - Parameters:
    ///   - response: 解码后的 DTO。
    ///   - now: 采集时刻（调用方注入，写入 FieldPatch.capturedAt）。
    /// - Returns: 稀疏字段补丁；无效响应返回全 nil 空补丁。
    static func map(_ response: SunriseSunsetResponse, now: Date) -> FieldPatch {
        guard response.status == "OK", let results = response.results else {
            // 状态非 OK 或整块缺失 → 空补丁（不崩、不抛）。
            return FieldPatch(sourceID: .sunriseSunset, capturedAt: now)
        }

        let sunrise = results.sunrise.flatMap { absoluteDate(from: $0) }
        let sunset = results.sunset.flatMap { absoluteDate(from: $0) }
        let solarNoon = results.solar_noon.flatMap { absoluteDate(from: $0) }
        let daylightDuration: TimeInterval? = results.day_length.map { TimeInterval($0) }

        return FieldPatch(sourceID: .sunriseSunset,
                          capturedAt: now,
                          sunrise: sunrise,
                          sunset: sunset,
                          solarNoon: solarNoon,
                          daylightDuration: daylightDuration)
    }

    // MARK: - Private

    /// 把 "2026-09-19T21:58:29+00:00" 这类带偏移的 ISO 串解析为**绝对时刻**。
    ///
    /// ⚠️ **P2 复盘修复（潜在的"静默差 5 小时"）**：原实现把**任意**偏移后缀剥掉后
    /// 一律以 `utcOffsetSeconds: 0` 解释墙钟。这在 `+00:00`（本源实测形态）下正确，
    /// 但若服务端改为返回 `-05:00`，得到的绝对时刻会**静默偏移 5 小时**——
    /// 不报错、不崩、现有单测也不会红（因为期望值若也按同一错法推导就自证了）。
    /// 现改为：**按串里真实的偏移解释**；偏移存在但解析不出来 → 返回 nil（**宁缺不猜**）。
    ///
    /// - Parameter string: ISO 时间串（末尾可能带 +HH:MM / -HH:MM / +HHMM / Z 偏移）。
    /// - Returns: 解析出的绝对时刻；格式不符或偏移不可解析 → nil。
    private static func absoluteDate(from string: String) -> Date? {
        guard let tRange = string.range(of: "T") else { return nil }
        let afterT = string[tRange.upperBound...]

        // 偏移段在 T 之后（如 +00:00 / -05:00 / Z）；日期段的 '-' 在 T 之前，不受影响。
        guard let offsetIndex = afterT.firstIndex(where: {
            $0 == "+" || $0 == "-" || $0 == "Z" || $0 == "z"
        }) else {
            // 无偏移（纯 "2026-09-19T21:58:29"）→ 本源文档口径为 UTC，按 UTC 解释。
            return ISOTimeStringDecoder.date(from: string, utcOffsetSeconds: 0)
        }

        let timePart = String(afterT[..<offsetIndex])          // "21:58:29"
        let datePart = String(string[..<tRange.lowerBound])     // "2026-09-19"
        let wallClock = datePart + "T" + timePart               // "2026-09-19T21:58:29"
        let offsetText = String(afterT[offsetIndex...])         // "+00:00" / "Z" / "-05:00"

        guard let offsetSeconds = parseOffsetSeconds(offsetText) else { return nil }
        return ISOTimeStringDecoder.date(from: wallClock, utcOffsetSeconds: offsetSeconds)
    }

    /// 解析偏移串 → 秒。
    ///
    /// 接受 `Z` / `z`（= 0）、`+HH:MM`、`-HH:MM`、`+HHMM`、`+HH`。
    /// **不可解析 → nil**（由调用方收敛为"该字段缺失"），绝不假定为 UTC。
    private static func parseOffsetSeconds(_ text: String) -> Int? {
        if text == "Z" || text == "z" { return 0 }
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let body = text.dropFirst()
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)

        var hours: Int?
        var minutes: Int?
        switch parts.count {
        case 1:
            let digits = String(parts[0])
            if digits.count == 4 {
                hours = Int(digits.prefix(2))
                minutes = Int(digits.suffix(2))
            } else if digits.count == 2 {
                hours = Int(digits)
                minutes = 0
            } else {
                return nil
            }
        case 2:
            hours = Int(parts[0])
            minutes = Int(parts[1])
        default:
            return nil
        }

        guard let h = hours, let m = minutes, h >= 0, h <= 14, m >= 0, m < 60 else { return nil }
        let total = h * 3600 + m * 60
        return sign == "-" ? -total : total
    }
}

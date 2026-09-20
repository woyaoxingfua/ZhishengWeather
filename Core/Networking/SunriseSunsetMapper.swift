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

    /// 把 "2026-09-19T21:58:29+00:00" 这类带偏移的 ISO 串，剥离偏移后以 UTC
    /// 解释墙钟，得到绝对时刻（复用 ISOTimeStringDecoder，符合 AD-5 时间归一纪律）。
    ///
    /// - Parameter string: ISO 时间串（末尾可能带 +HH:MM / -HH:MM / Z 偏移）。
    /// - Returns: 解析出的绝对时刻；格式不符 → nil。
    private static func absoluteDate(from string: String) -> Date? {
        guard let tRange = string.range(of: "T") else { return nil }
        let afterT = string[tRange.upperBound...]

        // 偏移段在 T 之后（如 +00:00 / -05:00 / Z）；日期段的 '-' 在 T 之前，不受影响。
        if let offsetIndex = afterT.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" || $0 == "z" }) {
            let timePart = String(afterT[..<offsetIndex])          // "21:58:29"
            let datePart = String(string[..<tRange.lowerBound])     // "2026-09-19"
            let wallClock = datePart + "T" + timePart               // "2026-09-19T21:58:29"
            // sunrise-sunset.org 恒返回 UTC（tzid="UTC"）→ 以 utcOffsetSeconds:0 解释墙钟。
            return ISOTimeStringDecoder.date(from: wallClock, utcOffsetSeconds: 0)
        }

        // 无偏移（纯 "2026-09-19T21:58:29"）→ 同样按 UTC 解释。
        return ISOTimeStringDecoder.date(from: string, utcOffsetSeconds: 0)
    }
}

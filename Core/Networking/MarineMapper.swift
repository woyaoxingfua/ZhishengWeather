//
//  MarineMapper.swift
//  Core / Networking  [App + Widget 共用]
//
//  第四源 DTO → 领域模型映射（纯函数）。
//
//  ── 非空判定：复用的是**既有机制**，不新造 ────────────────────────────
//  「解码成功但实质无数据」这件事，本仓库已有现成判定：
//  `SnapshotCompleteness.isEffectivelyEmpty(_ snapshot: WeatherSnapshot)`
//  （已在 `WeatherService.swift:67` 接线，把无数据的城市收敛为
//  `WeatherError.dataMissing` 而非冒充成功）。
//  本 mapper **复用同一套思路与同一处权威**：映射完成后一律交给
//  `MarineConditions.isEffectivelyEmpty`（该判据与 `SnapshotCompleteness`
//  同名、同结构、同职责，只是作用在不同域的模型上）。
//
//  为什么 marine 也**必须**做这一步（实测两种失败形态都得防）：
//   ① **整块被静默省略**：变量名在全局词表存在、但该端点不支持 →
//      HTTP 200 且**无该 key**（`response.current == nil`）。
//   ② **元素全为 null**：HTTP 200、键在、值为 null
//      （实测北京 39.9,116.4 → `wave_height/direction/period` 三项全 null）。
//  只防 ① 会把 ② 的 null 当成…其实 ① 已覆盖；但若只判"块在不在"而把
//  null 透传成 0，就会把"没数据"画成"海面平静"。故 mapper **逐字段判非空**，
//  六项全 nil 才认定实质无数据。
//
//  ── 净化纪律（沿用 `AirQualityMapper` 的既有做法）────────────────────
//  · 负值 / 非有限值 → nil（浪高、周期不可能为负；绝不冒充合法读数）；
//  · **`0` 原样保留为 `0`**（无浪是合法读数，绝不当成缺失）。
//
//  ── 时间 ─────────────────────────────────────────────────────────────
//  `current.time` 走既有 `FlexibleTime.epochSeconds` → `Date`，
//  **不新造第二套时间解析**；ISO 形态则交给既有 `ISOTimeStringDecoder`
//  （`utc_offset_seconds` 已在响应里，但 marine 的 `current.time` 在
//  `timeformat=unixtime` 下实测恒为 epoch，故 ISO 分支按 UTC 解释，
//  宁缺不猜 —— 拿不到就留 nil）。
//
//  Core 纪律：仅 import Foundation；纯函数；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 第四源 DTO → 海浪领域模型映射器（纯函数）。
enum MarineMapper {

    /// 映射。
    ///
    /// - Parameter response: 解码后的 DTO（`current` 可能为 nil）。
    /// - Returns: 海浪领域模型；`current` 缺失 → `MarineConditions.empty`
    ///   （六项皆 nil，`isEffectivelyEmpty == true`，UI 整卡隐藏）。
    static func map(_ response: MarineConditionsResponse) -> MarineConditions {
        guard let current = response.current else { return .empty }

        return MarineConditions(
            waveHeight: nonNegative(current.wave_height),
            waveDirection: validDirection(current.wave_direction),
            wavePeriod: nonNegative(current.wave_period),
            swellWaveHeight: nonNegative(current.swell_wave_height),
            swellWaveDirection: validDirection(current.swell_wave_direction),
            swellWavePeriod: nonNegative(current.swell_wave_period),
            capturedAt: absoluteDate(from: current.time,
                                     utcOffsetSeconds: response.utc_offset_seconds)
        )
    }

    // MARK: - Private

    /// 非负净化：nil 透传；负值 / 非有限值 → nil。
    ///
    /// **`0` 是合法读数**（无浪 / 静水），原样返回 0 —— 这是本函数与
    /// `isEffectivelyEmpty` 配合的关键：0 不会被误当成"无数据"。
    private static func nonNegative(_ raw: Double?) -> Double? {
        guard let value = raw, value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// 来向净化：nil 透传；非有限 / 落在 `[0, 360)` 外 → nil。
    ///
    /// 保留 `0`（正北来浪是合法取值）。
    ///
    /// 为什么额外校验上界 `360`：实测合法值域为 `0…359`（青岛 197、
    /// 香港 121 等）。服务端若某天返回 360+ 或负值，那**不是合法的来向**，
    /// 应当作缺失（宁缺不猜），而不是照单全收后被 UI 当成一个诡异的角度。
    private static func validDirection(_ raw: Double?) -> Double? {
        guard let value = raw, value.isFinite, value >= 0, value < 360 else {
            return nil
        }
        return value
    }

    /// `FlexibleTime` → 绝对时刻（复用既有解码路径）。
    ///
    /// - epoch 形态：直接 `Date(timeIntervalSince1970:)`（**不加偏移** ——
    ///   epoch 本身就是绝对时刻，加偏移是错的）；
    /// - ISO 形态：走既有 `ISOTimeStringDecoder`，用**该响应自带的**
    ///   `utc_offset_seconds` 解释墙钟。
    ///   ⚠️ marine 端点已钉死 `timeformat=unixtime`，ISO 只是**兜底**。
    ///   ⚠️ 若偏移**缺失**（`utcOffsetSeconds == nil`）→ 返回 **nil**，
    ///     **绝不**拿 `0` 硬解：那是"把 UTC 当成本地时"，
    ///     会让时刻静默偏移若干小时且无任何报错（最坏的一类缺陷）。
    ///     宁可 `capturedAt` 留 nil —— 少一个时间戳远好过**错**一个。
    private static func absoluteDate(from time: FlexibleTime?,
                                     utcOffsetSeconds: Int?) -> Date? {
        guard let time else { return nil }
        if let epoch = time.epochSeconds {
            return Date(timeIntervalSince1970: epoch)
        }
        guard let iso = time.isoString, let offset = utcOffsetSeconds else {
            return nil
        }
        return ISOTimeStringDecoder.date(from: iso, utcOffsetSeconds: offset)
    }
}
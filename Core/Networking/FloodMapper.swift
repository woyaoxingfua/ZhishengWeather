//
//  FloodMapper.swift
//  Core / Networking  [App + Widget 共用]
//
//  第五源 DTO → 领域模型映射（纯函数）。
//
//  ── 非空判定：复用既有机制，不新造 ────────────────────────────────────
//  与 marine 同一套纪律：
//   · **整块被静默省略**（`daily` 键不存在，HTTP 200）→ `RiverDischarge.empty`；
//   · **元素全为 null** → 逐元素判非空，一个有效值都没有才算实质无数据；
//   · **部分 null** → 保留（缺口是如实的，要展示出来）。
//  权威判据落在 `RiverDischarge.isEffectivelyEmpty`（与
//  `SnapshotCompleteness.isEffectivelyEmpty` / `MarineConditions.isEffectivelyEmpty`
//  同名同结构，各自域内独立判定）。
//
//  ── ⚠️ 量纲纪律（本 mapper 最容易错的地方）────────────────────────────
//  `river_discharge` 单位是 **m³/s**。映射时**原样透传、不做任何换算**
//  （服务端给的就是 m³/s，换算只会引入错误）。字段名
//  `cubicMetresPerSecond` 把量纲写进名字，让"当成流量 kg/s 或水量 m³"
//  这类错误一眼可见。
//
//  ── ⚠️ `0.00` 是合法读数，绝不当成缺测 ───────────────────────────────
//  实测乌鲁木齐 (43.8,87.6) 断流时返回的是 `[0.00, 0.00, 0.00]` ——
//  有键、有值、值为零。那是**真实的断流读数**，不是"没查到"。
//  若把它判成"无数据"，等于把一条真实读数说成缺测 —— 与"把 null 画成 0"
//  是同一种错误的镜像版本，两者都要防。
//
//  ── 时间对齐 ─────────────────────────────────────────────────────────
//  以 `time` 数组为基准逐下标取值（值数组缺失 / 越界 → 该日 nil），
//  故两个数组长度不齐时既不崩也不串位。时刻元素为 null → **跳过该日**
//  （无时刻无法定位，绝不编造日期）。
//
//  Core 纪律：仅 import Foundation；纯函数；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 第五源 DTO → 河道流量领域模型映射器（纯函数）。
enum FloodMapper {

    /// 映射。
    ///
    /// - Parameter response: 解码后的 DTO（`daily` 可能为 nil）。
    /// - Returns: 河道流量领域模型；`daily` 缺失 / 无有效值 → `.empty`
    ///   （`isEffectivelyEmpty == true`，UI 整卡隐藏）。
    static func map(_ response: FloodResponse) -> RiverDischarge {
        guard let daily = response.daily else { return .empty }

        let times = daily.time ?? []
        let values = daily.river_discharge ?? []
        guard !times.isEmpty else { return .empty }

        var points: [RiverDischargePoint] = []
        // 以**较短**的一侧为界：多出来的元素没有对应时刻（或反之），
        // 一律不取 —— 绝不下标越界，也绝不拿第 N 天去配第 N+1 天的流量。
        let upperBound = min(times.count, values.count)
        points.reserveCapacity(upperBound)

        for index in 0..<upperBound {
            // 时刻不可用 → 跳过该日（宁缺不猜：不编造日期）。
            // epoch 形态直接用；ISO 形态必须有 `utc_offset_seconds` 才能正确
            // 解释墙钟 —— 偏移缺失就**放弃该日**（`absoluteDate` 返回 nil），
            // 绝不拿 0 硬解，那会让时刻静默偏移若干小时且无任何报错。
            guard let date = absoluteDate(from: times[index],
                                          utcOffsetSeconds: response.utc_offset_seconds)
            else { continue }
            // 值数组下标越界 → nil（防御；upperBound 已保证不越界，
            // 保留是为把"缺测"与"0"区分开的语义写显式）。
            let rawValue: Double? = index < values.count ? values[index] : nil
            points.append(RiverDischargePoint(
                date: date,
                cubicMetresPerSecond: nonNegative(rawValue)
            ))
        }

        return RiverDischarge(daily: points)
    }

    // MARK: - Private

    /// `FlexibleTime?` → 绝对时刻（复用既有解码路径，**不新造**）。
    ///
    /// - epoch 形态：直接 `Date(timeIntervalSince1970:)`（**不加偏移**）。
    /// - ISO 形态：走既有 `ISOTimeStringDecoder`，用响应自带的偏移解释墙钟；
    ///   偏移缺失 → nil（宁缺不猜）。
    /// - 时间元素本身为 null → nil（调用方跳过该日）。
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

    /// 非负净化：nil 透传；负值 / 非有限值 → nil（流量不可能为负）。
    ///
    /// **`0` 原样保留**（断流是合法读数）—— 见文件头说明。
    private static func nonNegative(_ raw: Double?) -> Double? {
        guard let value = raw, value.isFinite, value >= 0 else { return nil }
        return value
    }
}
//
//  EnsembleMapper.swift
//  Core / Networking  [App + Widget 共用]
//
//  Ensemble DTO → 领域模型映射（纯函数）：
//   - 成员键**动态匹配** `_member\d{2}$`（两位零填充），随模式变化（1/30/40/50…），
//     **绝不硬编码 30**（PRD §11-8）。控制成员 `precipitation`（无后缀）**不计入**成员。
//   - `time` 字符串经 `ISOTimeStringDecoder` + 根级 `utc_offset_seconds` 解释为
//     `Date`（默认 iso8601 本地墙钟，不声明 timeformat）。
//   - 成员取值**净化**：nil 透传；非有限值 / 负值 → nil（降水量不可能为负，
//     负值视为服务端异常数据，绝不冒充合法读数；沿用 `AirQualityMapper` 纪律）。
//   - `hourly` 缺失 / 无成员 / 无有效时刻 → 返回 `EnsembleForecast.empty`
//     （UI 侧据 `evidence == nil` 整块隐藏，不崩）。
//
//  Core 纪律：仅 import Foundation；纯函数；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// Ensemble DTO → 领域模型映射器（纯函数）。
enum EnsembleMapper {

    /// 映射。任何缺失都收敛为合法（可能为空）的领域模型，绝不抛错。
    /// - Parameter response: Ensemble 原始响应。
    /// - Returns: 领域模型；无可用数据时为 `EnsembleForecast.empty`。
    static func map(_ response: EnsembleResponse) -> EnsembleForecast {
        let offset = response.utc_offset_seconds ?? 0
        guard let hourly = response.hourly else {
            return EnsembleForecast(times: [], memberSeries: [], utcOffsetSeconds: offset)
        }

        // 时刻：逐条墙钟字符串 → 绝对时刻；无法解析的丢弃（下标与成员序列同步收敛
        // 在「同一下标语义」上——成员值按原下标取，越界由引擎侧下标守卫处理）。
        let times: [Date] = (hourly.time ?? []).compactMap { raw in
            ISOTimeStringDecoder.date(from: raw, utcOffsetSeconds: offset)
        }

        // 成员键：仅匹配 `_member` + 两位数字结尾者（控制成员与 time 自动排除）。
        // 排序保证成员顺序稳定（两位零填充 → 字典序即数值序）。
        let memberKeys = hourly.series.keys
            .filter { $0.range(of: "_member\\d{2}$", options: .regularExpression) != nil }
            .sorted()

        // 成员序列：每个键 → 净化后的可选值数组（nil = 缺失/异常）。
        let memberSeries: [[Double?]] = memberKeys.map { key in
            (hourly.series[key] ?? []).map(sanitizedPrecipitation)
        }

        return EnsembleForecast(times: times,
                                memberSeries: memberSeries,
                                utcOffsetSeconds: offset)
    }

    // MARK: - Private

    /// 降水净化：nil 透传；非有限值 / 负值 → nil（0 为合法值，原样保留）。
    /// - Parameter raw: 原始成员降水值（mm）。
    /// - Returns: 合法值或 nil。
    private static func sanitizedPrecipitation(_ raw: Double?) -> Double? {
        guard let value = raw, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

//
//  AirQualityMapper.swift
//  Core / Networking  [App + Widget 共用]
//
//  DTO → 领域模型映射（A2-1，纯函数）：
//   - 键缺失 / null → 对应字段 nil（解码侧已保证不炸，此处透传）；
//   - **负值异常 → 该字段 nil**（AC-A2-5：浓度不可能为负，负值视为服务端
//     异常数据，绝不冒充合法读数；DTO 保留原值仅供诊断）；
//   - **`0` 原样保留为 `0`**（0 是合法读数，绝不当成缺失 —— 与 nil 严格区分）；
//   - `current` 整块缺失 → 各字段全 nil（AirQuality 全可选，卡片整卡不渲染）。
//
//  P2 修订（D-C4 / D-B11）：新增 `mapHourly` —— `hourly` 块 → 逐时趋势点数组。
//   逐时块缺失 / time 为空 → nil（趋势区整块隐藏，AC-B24）。
//
//  Core 纪律：仅 import Foundation；纯函数；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 空气质量 DTO → 领域模型映射器（纯函数）。
enum AirQualityMapper {

    /// 逐时趋势点条数上限（与端点 `AirQualityEndpoint.hourlyWindowHours` 一致）。
    ///
    /// 端已显式声明 `forecast_hours=24`；mapper 侧仍再截一次，对"服务端忽略
    /// `forecast_hours` 而套用 120 小时默认窗口"这一行为免疫（沿用
    /// `OpenMeteoMapper` 逐时 / 短时窗口"仍显式截窗"的既有纪律）。
    static let maxHourlyAQICount = 24

    /// 映射。`response.current == nil` → 返回全 nil 字段的 `AirQuality`
    /// （由 UI 侧 `airQuality == nil` 判据决定整卡是否渲染——实际上
    /// VM 侧在 `current` 缺失时直接置 `airQuality = nil` 更干净，此处
    /// 仍返回值以保持 mapper 纯函数语义的完备性）。
    ///
    /// 逐时块**独立**映射：`current` 缺失不影响逐时趋势的透传（反之亦然）。
    static func map(_ response: AirQualityResponse) -> AirQuality {
        let hourly = mapHourly(response.hourly)
        guard let current = response.current else {
            return AirQuality(usAqi: nil, europeanAqi: nil, pm25: nil, pm10: nil,
                              carbonMonoxide: nil, nitrogenDioxide: nil,
                              sulphurDioxide: nil, ozone: nil,
                              hourly: hourly)
        }
        return AirQuality(
            usAqi: sanitizedAqi(current.us_aqi),
            europeanAqi: sanitizedAqi(current.european_aqi),
            pm25: sanitizedConcentration(current.pm2_5),
            pm10: sanitizedConcentration(current.pm10),
            carbonMonoxide: sanitizedConcentration(current.carbon_monoxide),
            nitrogenDioxide: sanitizedConcentration(current.nitrogen_dioxide),
            sulphurDioxide: sanitizedConcentration(current.sulphur_dioxide),
            ozone: sanitizedConcentration(current.ozone),
            hourly: hourly
        )
    }

    // MARK: - Private

    /// 逐时块 → 趋势点数组。
    ///
    /// 对齐规则：以 `time` 数组为基准逐下标取值（值数组缺失 / 越界 → 该点该字段
    /// nil），故值数组长度与 time 不齐时不会崩、也不会串位。
    /// 时刻元素为 null → 跳过该点（无时刻无法定位，绝不编造时刻）。
    /// 三个值全为 nil 的点**仍保留**：它承载一个如实的"缺口"位置，
    /// 正是 AC-C10 要求曲线断开的地方。
    ///
    /// - Returns: 非空趋势点数组；`hourly` 缺失 / `time` 缺失或为空 → nil（趋势区隐藏）。
    private static func mapHourly(_ block: AirQualityResponse.Hourly?) -> [AqiHourlyPoint]? {
        guard let block, let times = block.time, !times.isEmpty else { return nil }

        var result: [AqiHourlyPoint] = []
        result.reserveCapacity(min(times.count, maxHourlyAQICount))
        for (index, epoch) in times.prefix(maxHourlyAQICount).enumerated() {
            guard let epoch else { continue }
            let aqi: Int? = element(block.us_aqi, at: index)
            let pm25: Double? = element(block.pm2_5, at: index)
            let pm10: Double? = element(block.pm10, at: index)
            result.append(AqiHourlyPoint(
                time: Date(timeIntervalSince1970: TimeInterval(epoch)),
                usAqi: sanitizedAqi(aqi),
                pm25: sanitizedConcentration(pm25),
                pm10: sanitizedConcentration(pm10)
            ))
        }
        return result.isEmpty ? nil : result
    }

    /// 可选数组的安全取值：数组缺失 / 下标越界 / 元素为 null → nil。
    private static func element<T>(_ array: [T?]?, at index: Int) -> T? {
        guard let array, index >= 0, index < array.count else { return nil }
        return array[index]
    }

    /// 浓度净化：nil 透传；负值/非有限值 → nil（AC-A2-5 异常用例）。
    /// **`0` 是合法读数，原样返回 0**（绝不当成缺失）。
    private static func sanitizedConcentration(_ raw: Double?) -> Double? {
        guard let value = raw, value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// AQI 净化：nil 透传；负值 → nil（AQI 理论下限 0）。
    /// **`0` 是合法读数，原样返回 0**（绝不当成缺失）。
    private static func sanitizedAqi(_ raw: Int?) -> Int? {
        guard let value = raw, value >= 0 else { return nil }
        return value
    }
}

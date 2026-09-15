//
//  AirQualityMapper.swift
//  Core / Networking  [App + Widget 共用]
//
//  DTO → 领域模型映射（A2-1，纯函数）：
//   - 键缺失 / null → 对应字段 nil（解码侧已保证不炸，此处透传）；
//   - **负值异常 → 该字段 nil**（AC-A2-5：浓度不可能为负，负值视为服务端
//     异常数据，绝不冒充合法读数；DTO 保留原值仅供诊断）；
//   - `current` 整块缺失 → 各字段全 nil（AirQuality 全可选，卡片整卡不渲染）。
//
//  Core 纪律：仅 import Foundation；纯函数；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 空气质量 DTO → 领域模型映射器（纯函数）。
enum AirQualityMapper {

    /// 映射。`response.current == nil` → 返回全 nil 字段的 `AirQuality`
    /// （由 UI 侧 `airQuality == nil` 判据决定整卡是否渲染——实际上
    /// VM 侧在 `current` 缺失时直接置 `airQuality = nil` 更干净，此处
    /// 仍返回值以保持 mapper 纯函数语义的完备性）。
    static func map(_ response: AirQualityResponse) -> AirQuality {
        guard let current = response.current else {
            return AirQuality(usAqi: nil, europeanAqi: nil, pm25: nil, pm10: nil,
                              carbonMonoxide: nil, nitrogenDioxide: nil,
                              sulphurDioxide: nil, ozone: nil)
        }
        return AirQuality(
            usAqi: sanitizedAqi(current.us_aqi),
            europeanAqi: sanitizedAqi(current.european_aqi),
            pm25: sanitizedConcentration(current.pm2_5),
            pm10: sanitizedConcentration(current.pm10),
            carbonMonoxide: sanitizedConcentration(current.carbon_monoxide),
            nitrogenDioxide: sanitizedConcentration(current.nitrogen_dioxide),
            sulphurDioxide: sanitizedConcentration(current.sulphur_dioxide),
            ozone: sanitizedConcentration(current.ozone)
        )
    }

    // MARK: - Private

    /// 浓度净化：nil 透传；负值/非有限值 → nil（AC-A2-5 异常用例）。
    private static func sanitizedConcentration(_ raw: Double?) -> Double? {
        guard let value = raw, value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// AQI 净化：nil 透传；负值 → nil（AQI 理论下限 0）。
    private static func sanitizedAqi(_ raw: Int?) -> Int? {
        guard let value = raw, value >= 0 else { return nil }
        return value
    }
}

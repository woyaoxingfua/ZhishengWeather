//
//  WeatherActivityContentBuilder.swift
//  ZhishengWeather（主 App target）
//
//  「取数成功 → ContentState 构造」的纯函数层。
//
//  为什么独立出来（对齐 Core 的「纯函数 + 单测」先例）：
//  - 取数出口（WeatherViewModel）只管「调 update」，把「原始数值 → 展示文案」的
//    全部格式化逻辑（单位换算、WMO 码映射、按城市时区格式化时刻）收敛到这里；
//  - 本函数**无副作用、确定性的入参 → 出参**，可直接单测（温度换算、现象名、
//    时区格式各分支都能断言），不依赖 ActivityKit、不依赖活动是否在跑。
//
//  纪律：
//  - **只取真实数据**：temperatureCelsius / weatherCode 来自已成功的快照；
//    无数据字段即 nil（对应 ContentState 可空字段），绝不填「26°」「晴」之类的伪数据。
//  - 仅引用已存在的 Core 类型（WeatherActivityAttributes / WMOCodeMapper /
//    WeatherTimeFormatter / UnitPreference）+ Foundation；不引 UIKit。
//  - @MainActor：WeatherTimeFormatter 的格式化带缓存且类型级 @MainActor，
//    本层调用它必须同处主 actor（与所有既有调用方一致）；纯函数语义不受影响
//    （同样入参恒得同样出参，缓存只是已解析格式器的记忆）。
//

import Foundation

/// 实时活动内容构造器（纯函数层）。
@MainActor
struct WeatherActivityContentBuilder {

    /// 由原始取数结果构造实时活动动态内容。
    ///
    /// - Parameters:
    ///   - cityName: 城市展示名（来自 `snapshot.location.name`；无 → nil）。
    ///   - temperatureCelsius: 当前气温（℃，快照原值；nil = 无数据）。
    ///   - weatherCode: WMO 天气码（nil = 无数据）。
    ///   - isDay: 昼夜（决定晴/晴间多云等描述，WMO 映射用）。
    ///   - updatedAt: 取数时刻（nil = 不显示更新时间）。
    ///   - timeZone: 更新时间渲染时区（按选中城市时区，D-4 口径）。
    ///   - unit: 单位偏好（温度换算 + 符号，与主 App 展示同 `UnitPreference` 源）。
    /// - Returns: 实时活动动态内容；缺失字段即 nil。
    static func buildContentState(cityName: String?,
                                  temperatureCelsius: Double?,
                                  weatherCode: Int?,
                                  isDay: Bool,
                                  updatedAt: Date?,
                                  timeZone: TimeZone,
                                  unit: UnitPreference) -> WeatherActivityAttributes.ContentState {
        // 温度：先按单位偏好换算（快照原值恒为 ℃ → 若是 ℉ 偏好走换算），
        // 再拼符号，如 "26℃" / "79℉"。换算纯逻辑在 UnitPreference 内。
        let temperatureText: String? = temperatureCelsius.map { celsius in
            let display = unit.displayTemperature(celsius: celsius)
            return String(format: "%.0f%@", display, unit.temperatureSymbol())
        }
        // 天气描述：WMO 码 → 中文现象名（夜间同用日描述，与卡片一致）。
        let conditionText: String? = weatherCode.map { WMOCodeMapper.description(for: $0) }
        // 更新时间：按城市时区格式化（复用 WeatherTimeFormatter，不另起格式器）。
        let updatedAtText: String? = updatedAt.map {
            WeatherTimeFormatter.string(from: $0, format: "MM-dd HH:mm", timeZone: timeZone)
        }
        return WeatherActivityAttributes.ContentState(cityName: cityName,
                                                     temperatureText: temperatureText,
                                                     conditionText: conditionText,
                                                     updatedAtText: updatedAtText)
    }
}

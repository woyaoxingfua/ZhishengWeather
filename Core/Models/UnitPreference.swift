//
//  UnitPreference.swift
//  Core / Models  [App + Widget 共用]
//
//  单位偏好（A3-4，AC-A3-8）：**走共享容器**——主 App 设置页写入，
//  Widget 渲染读同 key，两端单位同步切换。
//  换算纯函数（显示层消费；快照仍存 SI 原值）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 单位偏好（持久化键集中管理）。
enum UnitPreference {

    static let temperatureKey = "zs.weather.unit.temperature"  // "celsius" | "fahrenheit"
    static let windSpeedKey = "zs.weather.unit.wind"           // "ms" | "kmh"

    /// 共享容器（主 App 写 / Widget 读同源；AC-A3-8）。
    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: AppGroup.identifier)
    }

    static func temperatureUnit() -> String {
        sharedDefaults?.string(forKey: temperatureKey) ?? "celsius"
    }

    static func windSpeedUnit() -> String {
        sharedDefaults?.string(forKey: windSpeedKey) ?? "ms"
    }

    static func setTemperatureUnit(_ unit: String) {
        sharedDefaults?.set(unit, forKey: temperatureKey)
    }

    static func setWindSpeedUnit(_ unit: String) {
        sharedDefaults?.set(unit, forKey: windSpeedKey)
    }

    // MARK: - 换算（显示层消费；快照仍存 SI 原值）

    /// ℃ → ℉（偏好为 fahrenheit 时）。
    static func displayTemperature(celsius: Double) -> Double {
        temperatureUnit() == "fahrenheit" ? celsius * 9 / 5 + 32 : celsius
    }

    /// 温度单位符号。
    static func temperatureSymbol() -> String {
        temperatureUnit() == "fahrenheit" ? "℉" : "℃"
    }

    /// m/s → km/h（偏好为 kmh 时）。
    static func displayWindSpeed(ms: Double) -> Double {
        windSpeedUnit() == "kmh" ? ms * 3.6 : ms
    }

    /// 风速单位符号。
    static func windSpeedSymbol() -> String {
        windSpeedUnit() == "kmh" ? "km/h" : "m/s"
    }
}

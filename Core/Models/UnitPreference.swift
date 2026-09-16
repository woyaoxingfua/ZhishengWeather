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
    static let pressureKey = "zs.weather.unit.pressure"        // "hpa" | "mmhg" | "inhg"

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

    /// 归一化气压单位字符串（**纯函数**，便于单测）：仅接受 "mmhg"/"inhg"；
    /// 缺失（nil）、未知（如 "bar"）、大小写异常一律回退 "hpa"，避免渲染无意义数值（D-2）。
    static func normalizedPressureUnit(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "mmhg": return "mmhg"
        case "inhg": return "inhg"
        default: return "hpa"
        }
    }

    /// 当前气压单位（走共享容器；缺失或非法值回退 "hpa"）。
    static func pressureUnit() -> String {
        normalizedPressureUnit(sharedDefaults?.string(forKey: pressureKey))
    }

    static func setTemperatureUnit(_ unit: String) {
        sharedDefaults?.set(unit, forKey: temperatureKey)
    }

    static func setWindSpeedUnit(_ unit: String) {
        sharedDefaults?.set(unit, forKey: windSpeedKey)
    }

    static func setPressureUnit(_ unit: String) {
        sharedDefaults?.set(unit, forKey: pressureKey)
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

    // MARK: - 气压换算（D-2：快照存 hPa，本层仅做显示换算）

    /// 气压换算系数：1 mmHg = 1.33322387415 hPa → ×0.7500616827；
    /// 1 inHg = 33.86389 hPa → ×0.0295299831。
    private static let hPaToMmHg: Double = 0.7500616827
    private static let hPaToInHg: Double = 0.0295299831

    /// hPa → 目标单位（偏好）。输入恒为 hPa（快照存 SI，本函数不改存储值）。
    static func displayPressure(hPa: Double) -> Double {
        switch pressureUnit() {
        case "mmhg": return hPa * hPaToMmHg
        case "inhg": return hPa * hPaToInHg
        default: return hPa
        }
    }

    /// 气压单位符号（主屏指标格消费，非死代码）。
    static func pressureSymbol() -> String {
        switch pressureUnit() {
        case "mmhg": return "mmHg"
        case "inhg": return "inHg"
        default: return "hPa"
        }
    }

    /// 气压显示小数位（**纯函数**：hPa 1 位 / mmHg 0 位 / inHg 2 位）。
    static func pressureFractionDigits(for unit: String) -> Int {
        switch normalizedPressureUnit(unit) {
        case "mmhg": return 0
        case "inhg": return 2
        default: return 1
        }
    }
}

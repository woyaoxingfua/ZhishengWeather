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
//  store 纪律（对齐 IconChoicePreference / AppGroupStore）：**store 是实例依赖，
//  读与写必须绑同一个实例**。
//   - 生产默认实例 = App Group 共享容器（主 App 写 / Widget 读同源，AC-A3-8）；
//   - 单测注入独立 suite（`zs.test.unit.<UUID>`）隔离。**不得**让测试碰真实
//     App Group 共享容器：测试进程无该 entitlement 时会静默回落私有容器，
//     断言可能因错误的原因通过，同时污染 App 与 Widget 共用的真数据。
//  Widget / 设置页保留的 static API 只是**默认实例的薄壳转发** —— 全类型只有
//  一份 store，绝不另起第二份硬编码 store（那正是 IconChoicePreference 修掉的
//  「读注入 suite、写硬编码 standard」缺陷形态，见 CI run 35206149080）。
//

import Foundation

/// 单位偏好（持久化键集中管理；读写绑注入的 store）。
struct UnitPreference {

    /// 持久化键（App Group 共享容器；主 App 写 / Widget 读同源）。
    static let temperatureKey = "zs.weather.unit.temperature"  // "celsius" | "fahrenheit"
    static let windSpeedKey = "zs.weather.unit.wind"           // "ms" | "kmh"
    static let pressureKey = "zs.weather.unit.pressure"        // "hpa" | "mmhg" | "inhg"

    /// 读写共用的存储实例（构造时一次性选定，任何分支都不得绕开）。
    private let defaults: UserDefaults

    /// - Parameter defaults: 读写共用的存储。生产 = App Group 共享容器
    ///   （AC-A3-8）；`nil`（如缺 entitlement）回落 `.standard`，与
    ///   `AppGroupStore` 同款兜底，保证不崩溃。
    ///   单测注入 `UserDefaults(suiteName: "zs.test.unit.<UUID>")` 以隔离。
    init(defaults: UserDefaults? = UserDefaults(suiteName: AppGroup.identifier)) {
        self.defaults = defaults ?? .standard
    }

    // MARK: - 读写（本实例绑定的 store）

    func temperatureUnit() -> String {
        defaults.string(forKey: Self.temperatureKey) ?? "celsius"
    }

    func windSpeedUnit() -> String {
        defaults.string(forKey: Self.windSpeedKey) ?? "ms"
    }

    /// 当前气压单位（走本实例绑定的 store；缺失或非法值回退 "hpa"）。
    func pressureUnit() -> String {
        Self.normalizedPressureUnit(defaults.string(forKey: Self.pressureKey))
    }

    func setTemperatureUnit(_ unit: String) {
        defaults.set(unit, forKey: Self.temperatureKey)
    }

    func setWindSpeedUnit(_ unit: String) {
        defaults.set(unit, forKey: Self.windSpeedKey)
    }

    func setPressureUnit(_ unit: String) {
        defaults.set(unit, forKey: Self.pressureKey)
    }

    // MARK: - 归一化（**纯函数**，与 store 无关）

    /// 归一化气压单位字符串（**纯函数**，便于单测）：仅接受 "mmhg"/"inhg"；
    /// 缺失（nil）、未知（如 "bar"）、大小写异常一律回退 "hpa"，避免渲染无意义数值（D-2）。
    static func normalizedPressureUnit(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "mmhg": return "mmhg"
        case "inhg": return "inhg"
        default: return "hpa"
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

    // MARK: - 换算（显示层消费；快照仍存 SI 原值）

    /// ℃ → ℉（本实例绑定的偏好为 fahrenheit 时）。
    func displayTemperature(celsius: Double) -> Double {
        self.temperatureUnit() == "fahrenheit" ? celsius * 9 / 5 + 32 : celsius
    }

    /// 温度单位符号。
    func temperatureSymbol() -> String {
        self.temperatureUnit() == "fahrenheit" ? "℉" : "℃"
    }

    /// m/s → km/h（本实例绑定的偏好为 kmh 时）。
    func displayWindSpeed(ms: Double) -> Double {
        self.windSpeedUnit() == "kmh" ? ms * 3.6 : ms
    }

    /// 风速单位符号。
    func windSpeedSymbol() -> String {
        self.windSpeedUnit() == "kmh" ? "km/h" : "m/s"
    }

    // MARK: - 气压换算（D-2：快照存 hPa，本层仅做显示换算）

    /// 气压换算系数：1 mmHg = 1.33322387415 hPa → ×0.7500616827；
    /// 1 inHg = 33.86389 hPa → ×0.0295299831。
    private static let hPaToMmHg: Double = 0.7500616827
    private static let hPaToInHg: Double = 0.0295299831

    /// hPa → 目标单位（本实例绑定的偏好）。输入恒为 hPa（快照存 SI，本函数不改存储值）。
    func displayPressure(hPa: Double) -> Double {
        switch self.pressureUnit() {
        case "mmhg": return hPa * Self.hPaToMmHg
        case "inhg": return hPa * Self.hPaToInHg
        default: return hPa
        }
    }

    /// 气压单位符号（主屏指标格消费，非死代码）。
    func pressureSymbol() -> String {
        switch self.pressureUnit() {
        case "mmhg": return "mmHg"
        case "inhg": return "inHg"
        default: return "hPa"
        }
    }

    // MARK: - 生产默认实例（static 便捷 API 的薄壳）
    //
    // Widget / 设置页 / ContentView 的调用点保持 `UnitPreference.xxx()` 形态不变，
    // 但它们全部转发到**同一个默认实例**（App Group 共享容器）。这里不另存任何
    // store —— 默认实例本身就由 init 的注入点构造，缝是一整条。

    /// 生产默认实例（App Group 共享容器）。
    private static let shared = UnitPreference()

    static func temperatureUnit() -> String { shared.temperatureUnit() }
    static func windSpeedUnit() -> String { shared.windSpeedUnit() }
    static func pressureUnit() -> String { shared.pressureUnit() }

    static func setTemperatureUnit(_ unit: String) { shared.setTemperatureUnit(unit) }
    static func setWindSpeedUnit(_ unit: String) { shared.setWindSpeedUnit(unit) }
    static func setPressureUnit(_ unit: String) { shared.setPressureUnit(unit) }

    static func displayTemperature(celsius: Double) -> Double {
        shared.displayTemperature(celsius: celsius)
    }
    static func temperatureSymbol() -> String { shared.temperatureSymbol() }
    static func displayWindSpeed(ms: Double) -> Double { shared.displayWindSpeed(ms: ms) }
    static func windSpeedSymbol() -> String { shared.windSpeedSymbol() }
    static func displayPressure(hPa: Double) -> Double { shared.displayPressure(hPa: hPa) }
    static func pressureSymbol() -> String { shared.pressureSymbol() }
}

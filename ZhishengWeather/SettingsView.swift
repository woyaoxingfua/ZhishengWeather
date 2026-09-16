//
//  SettingsView.swift
//  ZhishengWeather（主 App target）
//
//  设置页完整版（A3-4，AC-A3-8/9/10）：
//   - 单位切换：温度 ℃/℉、风速 m/s↔km/h（UserDefaults 持久化，即时生效）；
//   - 数据源标注：Open-Meteo + 最近请求时间（AC-A3-9）；
//   - 关于：版本号 + 开源仓库链接（AC-A3-10）。
//  单位偏好存主 App 本地 UserDefaults（显示层关注点，不进共享容器）；
//  组件侧单位转换在渲染时按偏好换算（共享 payload 仍存 SI 原值）。
//

import SwiftUI

/// 单位偏好（持久化键集中管理）。
enum UnitPreference {
    static let temperatureKey = "zs.weather.unit.temperature"  // "celsius" | "fahrenheit"
    static let windSpeedKey = "zs.weather.unit.wind"           // "ms" | "kmh"

    static func temperatureUnit() -> String {
        UserDefaults.standard.string(forKey: temperatureKey) ?? "celsius"
    }

    static func windSpeedUnit() -> String {
        UserDefaults.standard.string(forKey: windSpeedKey) ?? "ms"
    }

    static func setTemperatureUnit(_ unit: String) {
        UserDefaults.standard.set(unit, forKey: temperatureKey)
    }

    static func setWindSpeedUnit(_ unit: String) {
        UserDefaults.standard.set(unit, forKey: windSpeedKey)
    }
}

/// 设置页。
@MainActor
struct SettingsView: View {

    /// 最近一次取数时刻（主屏透传，AC-A3-9）。
    let lastUpdated: Date?
    /// 数据源名称（当前恒为 Open-Meteo；多源为未来扩展位）。
    let dataSourceName: String = "Open-Meteo"

    @State private var temperatureUnit = UnitPreference.temperatureUnit()
    @State private var windSpeedUnit = UnitPreference.windSpeedUnit()

    var body: some View {
        Form {
            Section("单位") {
                Picker("温度", selection: $temperatureUnit) {
                    Text("℃").tag("celsius")
                    Text("℉").tag("fahrenheit")
                }
                .onChange(of: temperatureUnit) { _, newValue in
                    UnitPreference.setTemperatureUnit(newValue)
                }

                Picker("风速", selection: $windSpeedUnit) {
                    Text("m/s").tag("ms")
                    Text("km/h").tag("kmh")
                }
                .onChange(of: windSpeedUnit) { _, newValue in
                    UnitPreference.setWindSpeedUnit(newValue)
                }
            }

            Section("数据源") {
                HStack {
                    Text("天气数据")
                    Spacer(minLength: 8)
                    Text(dataSourceName)
                        .foregroundStyle(Theme.secondaryText)
                }
                if let lastUpdated {
                    HStack {
                        Text("最近更新")
                        Spacer(minLength: 8)
                        Text(Self.timeFormatter.string(from: lastUpdated))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }

            Section("关于") {
                HStack {
                    Text("版本")
                    Spacer(minLength: 8)
                    Text(Self.appVersion)
                        .foregroundStyle(Theme.secondaryText)
                }
                Link(destination: URL(string: "https://github.com/woyaoxingfua/ZhishengWeather")!) {
                    HStack {
                        Text("开源仓库")
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 静态

    /// App 版本号（Info.plist MARKETING_VERSION，AC-A3-10）。
    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return "\(version ?? "--") (\(build ?? "--"))"
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

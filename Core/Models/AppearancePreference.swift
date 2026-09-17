//
//  AppearancePreference.swift
//  Core / Models  [App + Widget 共用]
//
//  外观（深浅色）偏好：三档「深色 / 浅色 / 跟随系统」，默认「跟随系统」。
//
//  ⚠️ 与单位偏好不同，本偏好只写 **App 本地标准 UserDefaults**，
//  不进 App Group 共享容器 —— 小组件只跟随系统深浅，**绝不**读本设置
//  （对齐原版 0.0.5.1「小组件主题改为只跟随系统深浅」）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / Date() / try! / fatalError。
//
//  store 纪律（对齐 IconChoicePreference）：**store 是实例依赖，读与写必须绑
//  同一个实例**（默认 `.standard`，单测注入独立 suite）。
//  本类型**不提供** static 读写便捷 API：此前 `static appearance()` 读
//  `.standard`、而调用方 `AppearanceStore` 打算注入 store，就是「读硬编码、
//  写注入」的镜像缝（SettingsView 初值读静态、写路径走注入）。删掉静态读写后
//  唯一入口是绑定 store 的实例方法，注入缝无法再被绕过；纯函数 `normalized`
//  与键名 `key` 与 store 无关，保持 static。
//

import Foundation

/// 外观档位（持久化取值即 `rawValue`）。
enum AppearanceSetting: String, CaseIterable {

    /// 强制深色。
    case dark
    /// 强制浅色。
    case light
    /// 跟随系统（默认）。
    case system
}

/// 外观偏好持久化（**App 本地标准 UserDefaults**，不入共享容器）。
struct AppearancePreference {

    /// 持久化键（App 本地；不放 App Group 共享容器）。
    static let key = "zs.weather.appearance"

    /// 读写共用的存储实例（构造时一次性选定，任何分支都不得绕开）。
    private let defaults: UserDefaults

    /// - Parameter defaults: 读写共用的存储（App 用 `.standard`；
    ///   单测注入 `UserDefaults(suiteName: "zs.test.theme.<UUID>")` 以隔离）。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 归一化：缺失（nil）/ 未知（如 "neon"）一律回退 `.system`。
    ///
    /// **纯函数**，便于单测；大小写不敏感（存储值统一小写）。
    ///
    /// - Parameter raw: 原始存储字符串（可能为 nil）。
    /// - Returns: 归一化后的外观档位。
    static func normalized(_ raw: String?) -> AppearanceSetting {
        guard let raw, let setting = AppearanceSetting(rawValue: raw.lowercased()) else {
            return .system
        }
        return setting
    }

    /// 当前外观档位（读**本实例绑定的** store；缺失或非法 → 跟随系统）。
    ///
    /// - Returns: 当前档位。
    func appearance() -> AppearanceSetting {
        Self.normalized(defaults.string(forKey: Self.key))
    }

    /// 写入外观档位（写**本实例绑定的** store）。
    ///
    /// - Parameter setting: 目标档位。
    func setAppearance(_ setting: AppearanceSetting) {
        defaults.set(setting.rawValue, forKey: Self.key)
    }
}

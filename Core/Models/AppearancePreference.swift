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
enum AppearancePreference {

    /// 持久化键（App 本地；不放 App Group 共享容器）。
    static let key = "zs.weather.appearance"

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

    /// 当前外观档位（读 App 本地标准 UserDefaults；缺失或非法 → 跟随系统）。
    ///
    /// - Returns: 当前档位。
    static func appearance() -> AppearanceSetting {
        normalized(UserDefaults.standard.string(forKey: key))
    }

    /// 写入外观档位（App 本地标准 UserDefaults）。
    ///
    /// - Parameter setting: 目标档位。
    static func setAppearance(_ setting: AppearanceSetting) {
        UserDefaults.standard.set(setting.rawValue, forKey: key)
    }
}

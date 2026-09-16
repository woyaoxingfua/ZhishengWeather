//
//  AppearanceStore.swift
//  ZhishengWeather（主 App target）
//
//  外观档位的可观察存储：设置页写入 → 根视图观察 → 触发整树重建。
//
//  持久化委托 Core 的 `AppearancePreference`（**App 本地标准 UserDefaults**，
//  不进 App Group 共享容器）。本类型属 App target，小组件**不引用**它 ——
//  小组件只跟随系统深浅。
//

import Observation

/// 外观档位的可观察存储（写入的单一真源）。
@MainActor
@Observable
final class AppearanceStore {

    /// 当前外观档位。
    private(set) var setting: AppearanceSetting

    /// 从本地持久化恢复初始档位（缺失 / 非法 → 跟随系统）。
    init() {
        setting = AppearancePreference.appearance()
    }

    /// 更新档位并落盘。
    ///
    /// 值未变时不通知、不落盘（幂等），避免无谓的整树重建。
    ///
    /// - Parameter newValue: 目标档位。
    func set(_ newValue: AppearanceSetting) {
        guard newValue != setting else { return }
        setting = newValue
        AppearancePreference.setAppearance(newValue)
    }
}

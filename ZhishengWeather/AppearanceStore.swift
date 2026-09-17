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
//  store 纪律（对齐 AppIconSwitcher）：注入的 `defaults` 同时构造出读写共用的
//  `AppearancePreference`，`setting` 初值与 `set(_:)` 落盘走**同一实例**。
//  设置页的 @State 初值必须经本类型（`appearance.setting`）读取，不得绕过它
//  直接调 `AppearancePreference` 的静态方法——那会退化成「读硬编码、写注入」。
//

import Observation

/// 外观档位的可观察存储（写入的单一真源）。
@MainActor
@Observable
final class AppearanceStore {

    /// 当前外观档位。
    private(set) var setting: AppearanceSetting

    /// 外观偏好持久化（**绑定注入的 store**，读与写同一实例）。
    private let preference: AppearancePreference

    /// 从本地持久化恢复初始档位（缺失 / 非法 → 跟随系统）。
    ///
    /// - Parameter defaults: 偏好存储（App 用 `.standard`；单测注入独立 suite
    ///   以隔离）。
    init(defaults: UserDefaults = .standard) {
        let preference = AppearancePreference(defaults: defaults)
        self.preference = preference
        self.setting = preference.appearance()
    }

    /// 更新档位并落盘。
    ///
    /// 值未变时不通知、不落盘（幂等），避免无谓的整树重建。
    ///
    /// - Parameter newValue: 目标档位。
    func set(_ newValue: AppearanceSetting) {
        guard newValue != setting else { return }
        setting = newValue
        preference.setAppearance(newValue)
    }
}

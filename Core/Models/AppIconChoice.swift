//
//  AppIconChoice.swift
//  Core / Models  [App + Widget 共用]
//
//  应用图标档位（iOS 10.3+ 备用图标）的**纯映射模型**：
//
//      设置页 UI 档位（IconChoice）  ◀──纯函数──▶  存储串 / 备用图标资源名
//
//  设计纪律（对齐 AppearancePreference / UmbrellaReminderScheduler）：
//  - **纯逻辑**：仅 import Foundation；无 UIKit / UIApplication——
//    Core 同时挂到 Widget target，UIApplication 在扩展里不可用；
//    真正调用 `UIApplication.setAlternateIconName` 的副作用被隔离在
//    App target 的 AppIconSwitcher（协议注入，单测用 Spy）。
//  - **默认档 nil**：备用图标资源的名字传 `nil` 才能切回默认图标，
//    故本模型的「默认档」持久化为空串，映射为 `alternateIconName = nil`；
//    绝不把默认档的 appiconset 名（"AppIcon"）传给系统——那不是备用图标名。
//  - **归一化**：存储值缺失 / 未知（如手改 UserDefaults）一律回退默认档，
//    纯函数便于单测锁定。
//
//  文案与资源名对照（SettingsView 的单一真源）：
//      默认   磷光     → 资源 AppIcon        （alternateIconName = nil）
//      清冷翡翠 翡翠雨云 → 资源 AppIcon-Jade
//      终端雨字 汉字「雨」→ 资源 AppIcon-Rain
//

import Foundation

/// 应用图标档位（设置页 UI 取值；`rawValue` 即持久化存储串）。
enum IconChoice: String, CaseIterable, Equatable, Sendable {

    /// 默认档：磷光雷达温度计（AppIcon.appiconset，**不**作为备用名传系统）。
    case phosphor
    /// 备用档：清冷翡翠（AppIcon-Jade.appiconset）。
    case jade
    /// 备用档：终端雨字（AppIcon-Rain.appiconset）。
    case rain

    /// 设置页显示名（单一真源：SettingsView 直接引用，禁止再写一份）。
    var displayName: String {
        switch self {
        case .phosphor:
            return "磷光"
        case .jade:
            return "清冷翡翠"
        case .rain:
            return "终端雨字"
        }
    }

    /// 是否默认档（UI 标注「默认」用）。
    var isDefault: Bool {
        self == .phosphor
    }
}

// MARK: - 纯映射（单测锁定面）

extension IconChoice {

    /// 备用图标资源名（系统 API 参数语义）：
    /// 默认档 → `nil`（切回默认）；备用档 → 对应 appiconset 名。
    ///
    /// **纯函数**；返回值直接喂给
    /// `UIApplication.setAlternateIconName(_:)` / Spy。
    var alternateIconName: String? {
        switch self {
        case .phosphor:
            return nil
        case .jade:
            return "AppIcon-Jade"
        case .rain:
            return "AppIcon-Rain"
        }
    }

    /// 存储/备用图标名 → 档位（**反向归一化，纯函数**）。
    ///
    /// 入参语义与 `UIApplication.alternateIconName` 一致：
    /// `nil` = 当前是默认图标。未知存储串（如后续资源改名后的残留值）→
    /// 回退默认档——与 AppearancePreference.normalized 同款纪律。
    ///
    /// - Parameter alternateName: 备用图标资源名（nil = 默认）。
    /// - Returns: 归一化后的档位。
    static func resolve(alternateName: String?) -> IconChoice {
        switch alternateName {
        case nil:
            return .phosphor
        case "AppIcon-Jade":
            return .jade
        case "AppIcon-Rain":
            return .rain
        default:
            return .phosphor
        }
    }
}

// MARK: - 持久化（App 本地标准 UserDefaults，不入 App Group）

/// 图标档位持久化（**App 本地 UserDefaults**；小组件与图标无关，不读它）。
///
/// 存储的是档位 `rawValue`（"phosphor" / "jade" / "rain"），**不是**
/// 资源名——档位是语义，资源名是映射结果，两层分离避免改名污染存储。
///
/// **store 是实例依赖，读与写必须绑同一个实例**（默认 `.standard`，
/// 单测传独立 suite）。此前的 static `choice()` / `setChoice(_:)` 硬编码
/// `.standard`，而调用方 `AppIconSwitcher` 的注入 `defaults` 只覆盖读路径，
/// 于是「读注入 suite、写 standard」——注入缝只用了半条，单测的隔离是假的
/// （CI run 35206149080 三例四断言红）。改成实例方法后，注入什么 store
/// 就读写什么 store，缝才是真的。
struct IconChoicePreference {

    /// 持久化键（App 本地；不放 App Group 共享容器）。
    static let key = "zs.weather.iconChoice"

    /// 读写共用的存储实例（构造时一次性选定，任何分支都不得绕开）。
    private let defaults: UserDefaults

    /// - Parameter defaults: 读写共用的存储（App 用 `.standard`；
    ///   单测注入 `UserDefaults(suiteName:)` 以隔离）。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 归一化：缺失 / 未知存储串 → 默认档（纯函数，单测锁定）。
    ///
    /// - Parameter raw: 原始存储字符串（可能为 nil）。
    /// - Returns: 归一化后的档位。
    static func normalized(_ raw: String?) -> IconChoice {
        guard let raw, let choice = IconChoice(rawValue: raw) else {
            return .phosphor
        }
        return choice
    }

    /// 当前档位（读**本实例绑定的** store；缺失或非法 → 默认档）。
    ///
    /// - Returns: 当前档位。
    func choice() -> IconChoice {
        Self.normalized(defaults.string(forKey: Self.key))
    }

    /// 写入档位（写**本实例绑定的** store）。
    ///
    /// - Parameter choice: 目标档位。
    func setChoice(_ choice: IconChoice) {
        defaults.set(choice.rawValue, forKey: Self.key)
    }
}

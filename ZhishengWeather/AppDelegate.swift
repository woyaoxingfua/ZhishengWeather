//
//  AppDelegate.swift
//  ZhishengWeather（主 App target）
//
//  最小 AppDelegate（A1-8 / 修复批 P0-2）：
//  SwiftUI 纯 `@main` App 收不到 Home Screen 快捷方式回调，且原实现把
//  `windowScene(_:performActionFor:)`（这是 `UIWindowSceneDelegate` 方法）写在了
//  只遵循 `UIApplicationDelegate` 的类上 —— 故该方法**永不被调用**（P0-2）。
//
//  修正：
//  - `application(_:configurationForConnecting:options:)` 返回
//    `UISceneConfiguration` 并显式 `delegateClass = SceneDelegate.self`，
//    让系统把窗口场景委托交给本文件的 `SceneDelegate`；**同时**从
//    `options.shortcutItems` 读取冷启动快捷方式（App 未运行时触发，唯一可靠入口）。
//  - 新增嵌套 `SceneDelegate: UIResponder, UIWindowSceneDelegate`，实现
//    `windowScene(_:performActionFor:)` → 转发 `AppRouter.handleShortcut`（热启动/已运行路径）。
//  - `application(_:performActionFor:)` 作为兜底保留（旧 iOS / 非场景路径）。
//
//  纪律（R-A8）：只做转发，不持任何业务状态；不实现其他生命周期方法，
//  避免与 SwiftUI 场景管理产生摩擦。SwiftUI 内容仍由 UIKit 为 `UIWindowScene`
//  提供的 window 承载，`SceneDelegate` 仅补充快捷方式回调、不接管 window 创建。
//

import UIKit

/// 最小 AppDelegate：冷启动配置 + 快捷方式兜底转发。
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// 冷启动：为每个连接场景返回配置，并指定本文件的 `SceneDelegate` 为窗口场景委托。
    /// ⚠️ CI run14 勘误：`UIScene.ConnectionOptions` **没有** `shortcutItems` 成员
    /// （该成员只存在于 SwiftUI Scene 的 `WindowGroup` 专属 options，UIKit 场景
    /// 模型里不存在）。冷启动快捷方式的唯一可靠机制：App 运行后系统对
    /// SceneDelegate 回调 `windowScene(_:performActionFor:)`（连接完成后派发），
    /// 兜底由 ContentView 的 `.task` 消费 AppRouter 残留状态——两条路径均已就位，
    /// 此处无需读 options。
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "ZhishengWeather Configuration",
                                          sessionRole: connectingSceneSession.role)
        // 关键修正（P0-2）：必须指定 delegateClass，否则快捷方式回调不会被本 App 收到。
        config.delegateClass = SceneDelegate.self
        return config
    }

    /// 兜底：非场景（旧行为 / 某些入口）下的快捷方式回调，照常转发。
    func application(_ application: UIApplication,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            AppRouter.shared.handleShortcut(type: shortcutItem.type)
            completionHandler(true)
        }
    }
}

/// 窗口场景委托（嵌套类）：承接 Home Screen 快捷方式的 `windowScene(_:performActionFor:)`。
/// 仅做转发，不创建/接管 window —— 窗口由 UIKit 为 `UIWindowScene` 自动提供，
/// SwiftUI 内容照常承载其上。
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    /// 快捷方式触发（长按图标选择某项时回调；App 已运行 / 回前台路径）。
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            AppRouter.shared.handleShortcut(type: shortcutItem.type)
            completionHandler(true)
        }
    }
}

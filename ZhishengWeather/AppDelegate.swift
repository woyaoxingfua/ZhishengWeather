//
//  AppDelegate.swift
//  ZhishengWeather（主 App target）
//
//  最小 AppDelegate（A1-8，ARCH-A1 §1.8）：
//  SwiftUI 纯 `@main` App 收不到 Home Screen 快捷方式回调，故经
//  `@UIApplicationDelegateAdaptor` 挂一个**只做转发**的最小 delegate ——
//  仅实现 `windowScene(_:performActionFor:)`，把快捷方式 type 转给
//  `AppRouter`（与深链共用同一路由出口）。
//
//  纪律（R-A8）：只做转发，不持任何业务状态；不实现其他生命周期方法，
//  避免与 SwiftUI 场景管理产生摩擦。
//

import UIKit

/// 最小 AppDelegate：快捷方式回调 → AppRouter 转发。
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// 快捷方式触发（长按图标选择某项时回调）。
    /// `shortcutItem` 的 type 为 Info.plist UIApplicationShortcutItemType，
    /// 逐字对应 AppRouter 的常量。
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            AppRouter.shared.handleShortcut(type: shortcutItem.type)
            completionHandler(true)
        }
    }
}

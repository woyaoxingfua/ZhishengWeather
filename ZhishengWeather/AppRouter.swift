//
//  AppRouter.swift
//  ZhishengWeather（主 App target）
//
//  统一路由出口（A1-7 深链 + A1-8 快捷方式共用一套，ARCH-A1 §1.8）：
//    - 深链：zhisheng://refresh（Widget 刷新按钮派发）→ 强刷；
//    - 快捷方式：AppDelegate / SceneDelegate 的快捷方式回调转发 →
//      刷新 / 搜索城市 / 设置（暂路由城市列表页根，偏差备案 D-A3）。
//
//  机制：
//  - `@Observable @MainActor` 单例：快捷方式入口把目的地连同一枚单调
//    UUID 令牌写入 `pendingRoute`（可追踪存储属性）。ContentView 经
//    `.onChange(of: pendingRoute)` 观察变更、调 `consume` 消费；冷启动
//    （AppDelegate 在配置 Scene 前已读到 shortcutItems）时首值不会触发
//    onChange，故 ContentView 另以 `.task` 兜底消费一次首值。
//  - 单调令牌解决「同目的地连续两次快捷方式」被 @Observable 同值抑制、
//    onChange 不触发的丢事件问题（每次 handleShortcut 都换 UUID）。
//  - 深链入口（onOpenURL）直接调 `handle` 同步强刷，不复用 pendingRoute。
//  - 快捷方式经 UIApplicationShortcutItem.type 字符串映射目的地，
//    深链经 URL host 字符串映射 —— 两入口共用一套 Route 枚举。
//

import Foundation
import Observation
import SwiftUI

/// 主 App 路由器（A1-7 / A1-8 共用出口）。
@MainActor
@Observable
final class AppRouter {

    // MARK: - 路由目的地

    /// 支持的路由目的地。
    enum Route: Equatable {
        /// 强刷当前城市（绕过 15 分钟节流）。
        case refresh
        /// 打开城市列表（快捷方式"搜索城市"；D-A3：暂只 push 城市列表页根，
        /// 不预聚焦搜索框，聚焦增强留待 A2 接）。
        case searchCity
    /// 打开设置（A1 暂路由城市列表页根，D-A3；A3 设置页就绪后改一行）。
    case settings
    }

    // MARK: - 待消费令牌

    /// 待消费路由 + 单调令牌。
    /// 每次 `handleShortcut` 都生成新 UUID，使 `@Observable` 即便收到
    /// 同目的地也能触发 ContentView 的 `.onChange`（P1-B 同值抑制修复）。
    struct PendingRoute: Equatable {
        let id = UUID()
        let route: Route
    }

    // MARK: - 常量

    /// 深链 scheme + 刷新路径（Info.plist CFBundleURLTypes 同步注册 scheme）。
    static let refreshURLString = "zhisheng://refresh"

    /// 快捷方式 type 前缀（Info.plist UIApplicationShortcutItems 的
    /// UIApplicationShortcutItemType 逐字对应）。
    static let shortcutTypeRefresh = "com.zhisheng.weather.shortcut.refresh"
    static let shortcutTypeSearch = "com.zhisheng.weather.shortcut.search"
    static let shortcutTypeSettings = "com.zhisheng.weather.shortcut.settings"

    /// 单例（AppDelegate / SwiftUI 两处入口共享同一状态）。
    static let shared = AppRouter()

    // MARK: - 发布状态

    /// 待消费路由 + 单调令牌（@Observable 追踪；消费后置 nil 防重复触发）。
    /// ContentView 经 `.onChange(of: pendingRoute)` 观察变更、冷启动以
    /// `.task` 兜底消费首值。
    private(set) var pendingRoute: PendingRoute?

    private init() {}

    // MARK: - 入口①：深链（Widget 刷新按钮）

    /// 处理深链 URL（ContentView `.onOpenURL` 汇入）。
    /// - Parameters:
    ///   - url: 打开的 URL。
    ///   - viewModel: 执行动作的视图模型。
    func handle(url: URL, viewModel: WeatherViewModel) {
        guard url.scheme?.lowercased() == "zhisheng" else { return }
        guard url.host?.lowercased() == "refresh" else { return }
        Task { await viewModel.refresh() }
    }

    // MARK: - 入口②：快捷方式（AppDelegate 转发）

    /// 处理快捷方式 type（AppDelegate / SceneDelegate → 本方法）。
    /// 每次调用都生成新 UUID 令牌，确保连续同目的地也能触发观察（P1-B）。
    /// - Parameter type: `UIApplicationShortcutItem.type`。
    func handleShortcut(type: String) {
        let route: Route?
        switch type {
        case Self.shortcutTypeRefresh:
            route = .refresh
        case Self.shortcutTypeSearch:
            route = .searchCity
        case Self.shortcutTypeSettings:
            route = .settings
        default:
            route = nil
        }
        guard let route else { return }
        pendingRoute = PendingRoute(route: route)
    }

    // MARK: - 消费（ContentView 观察执行）

    /// 消费待处理路由：执行刷新类动作，并把"跳转类"路由返回给调用方
    /// （由 ContentView 做 NavigationPath push —— 避免 inout 穿透视图闭包）。
    ///
    /// - Parameters:
    ///   - pending: 待消费令牌（nil = 无待处理，返回 nil）。
    ///   - viewModel: 视图模型（强刷用 refresh()，绕过 refreshIfNeeded 节流）。
    /// - Returns: 需要调用方执行 push 的路由；nil = 无需跳转。
    @discardableResult
    func consume(_ pending: PendingRoute?, viewModel: WeatherViewModel) -> Route? {
        guard let pending else { return nil }
        pendingRoute = nil

        switch pending.route {
        case .refresh:
            // 强刷：必须绕过 15 分钟节流（ARCH-A1 §1.7，refreshIfNeeded 会吞点击）。
            Task { await viewModel.refresh() }
            return nil
        case .searchCity, .settings:
            // 搜索 / 设置（D-A3 暂路由城市列表页根）：push 城市管理页。
            return pending.route
        }
    }
}

/// NavigationPath 的值类型（ContentView navigationDestination 注册）。
/// A3：settings 已指向真实设置页（D-A3 备案解除）。
enum CityRoute: Hashable {
    case cities
    case settings
}

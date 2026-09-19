//
//  ZhishengWeatherApp.swift
//  ZhishengWeather
//
//  主 App 入口。持有并注入 WeatherViewModel 与 AppearanceStore；
//  监听 scenePhase，回到前台时：优先消费 Widget 强刷标志位（有则强刷），
//  否则触发节流刷新（refreshIfNeeded）。
//  A1-8：经 @UIApplicationDelegateAdaptor 挂最小 AppDelegate（快捷方式回调转发）。
//
//  外观：窗口内容交由 RootView 决定深浅（深色 / 浅色 / 跟随系统），
//  本文件**不再**强制 `.preferredColorScheme(.dark)`。
//
//  注意：本文件属于主 App target，允许使用主 App 专有 API；
//  共享的 Core/ 目录内严禁出现同类代码。
//

import SwiftUI

@main
/// @MainActor：App 结构体的存储属性初始化器默认在非隔离上下文求值，
/// 而 WeatherViewModel / AppearanceStore 是 @MainActor 隔离类型（CI 实测挂编译）。
/// 给 App 标 @MainActor 后整个初始化过程都在主 actor 上，与 SwiftUI
/// 官方推荐模式一致。
@MainActor
struct ZhishengWeatherApp: App {

    /// A1-8：最小 AppDelegate（仅快捷方式回调转发，见 AppDelegate.swift）。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// 实时活动管理器（App 级单例）：**同一实例**注入 VM 与设置页，
    /// 保证「设置页启动的活动」与「VM 取数后更新的活动」指向同一个
    /// `currentActivity` 引用 —— 否则两侧各持一份独立实例，取数成功也永远
    /// 更新不到设置页启动的那个活动（灵动岛长期空态的根因之一）。
    @State private var activityManager: WeatherActivityManager

    /// 视图模型是 App 级单例，用 @State 持有，注入到 RootView。
    @State private var viewModel: WeatherViewModel

    /// 外观存储是 App 级单例，用 @State 持有，注入到 RootView / 设置页。
    @State private var appearance: AppearanceStore = AppearanceStore()

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 同一份管理器实例同时喂给 VM 与设置页（见 activityManager 注释）。
        let manager = WeatherActivityManager()
        _activityManager = State(initialValue: manager)
        _viewModel = State(initialValue: WeatherViewModel(activityManager: manager))
    }

    var body: some Scene {
        WindowGroup {
            // RootView 负责：解析配色并重建视图树（切换外观即重绘）+ 声明深浅偏好。
            RootView(viewModel: viewModel, appearance: appearance, activityManager: activityManager)
                .task {
                    // 冷启动：首帧后立即取数（内部会先用缓存预填，保证 0 网络也能出内容）。
                    await viewModel.refresh()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                // 优先消费 Widget 刷新按钮写入的强刷标志位（A1-7）：有则绕过新鲜度
                // 节流强制刷新；无标志位再按 15 分钟新鲜度窗口节流刷新（原有逻辑不变）。
                if await viewModel.consumePendingForceRefreshAndRefresh() {
                    return
                }
                await viewModel.refreshIfNeeded()
            }
        }
    }
}

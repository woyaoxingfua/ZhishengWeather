//
//  ZhishengWeatherApp.swift
//  ZhishengWeather
//
//  主 App 入口。持有并注入 WeatherViewModel；监听 scenePhase，
//  回到前台时触发一次节流刷新（refreshIfNeeded）。
//
//  注意：本文件属于主 App target，允许使用主 App 专有 API；
//  共享的 Core/ 目录内严禁出现同类代码。
//

import SwiftUI

@main
struct ZhishengWeatherApp: App {

    /// 视图模型是 App 级单例，用 @State 持有，注入到 ContentView。
    @State private var viewModel: WeatherViewModel = WeatherViewModel()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .preferredColorScheme(.dark)
                .task {
                    // 冷启动：首帧后立即取数（内部会先用缓存预填，保证 0 网络也能出内容）。
                    await viewModel.refresh()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await viewModel.refreshIfNeeded() }
        }
    }
}

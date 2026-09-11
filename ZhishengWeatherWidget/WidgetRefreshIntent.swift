//
//  WidgetRefreshIntent.swift
//  ZhishengWeatherWidget（Widget target）
//
//  A1-7 可交互刷新（ARCH-A1 §1.7，裁定备选 C；偏差备案 D-A2）：
//
//    Button(intent: WidgetRefreshIntent())  [Medium/Large 右上角]
//      → openAppWhenRun = true：系统在主 App 进程执行 perform()
//      → perform() 返回 .result()，系统拉起主 App
//      → 主 App 侧经 ZhishengWeatherApp 的 LaunchIntent 处理 /
//        ContentView 的 onOpenURL 路由（zhisheng://refresh）
//      → viewModel.refresh()（**绕过** refreshIfNeeded 的 15 分钟节流，强刷）
//      → 取数 → 写共享容器 → reloadAllTimelines()（既有全链路复用）
//
//  纪律：
//  - **widget 零网络零写入**（F-C-8 结构性防线）：本 Intent 不含任何
//    网络类型引用、不写共享容器 —— 只负责"把主 App 拉到前台并告知意图"。
//    路由出口经 `AppRouter`（主 App target，与 A1-8 快捷方式共用一套）。
//  - AC-A1-21 已降级（PRD v1.1 勘误 / D-A2）：跨进程链路下系统按钮 loading
//    只覆盖毫秒级，无法展示主 App 取数进度；落地面 = 主 App 到前台展示
//    刷新过程，失败时 widget 保持旧数据 + 更新时间戳不变脏。
//
//  注意：AppIntent 需同时编译进主 App target 与 Widget target
//  （openAppWhenRun 时系统在主 App 进程执行）。本文件位于 Widget 目录，
//  由 project.yml 同时挂入两 target（与 WidgetCityIntent.swift 同模式）。
//

import AppIntents
import Foundation
import SwiftUI

/// 小组件刷新按钮的意图：拉起主 App 并路由到强刷。
struct WidgetRefreshIntent: AppIntent {

    static var title: LocalizedStringResource = "刷新天气"

    static var description = IntentDescription(
        "打开枳生天气并立即刷新当前城市的天气数据。",
        categoryName: "天气")

    /// 关键裁定（ARCH-A1 §1.7 备选 C）：置 true 后系统在主 App 进程执行
    /// perform()，返回时自动把主 App 拉到前台 —— widget 进程自身零网络零写入。
    static var openAppWhenRun: Bool = true

    /// 纪律：同 WidgetCityIntent 的编译期字面量要求（CI 实测）。
    static var isDiscoverable: Bool = false

    /// 空构造：Button(intent: WidgetRefreshIntent()) 直用。
    init() {}

    /// 执行体：把"刷新"意图经环境 openURL 派发成深链，由主 App 侧
    /// `ContentView.onOpenURL → AppRouter` 消费（强刷绕过 15 分钟节流）。
    ///
    /// 实现说明：`EnvironmentValues().openURL` 是 AppIntents 提供的
    /// 进程内打开 URL 通道（iOS 17+）；深链 scheme `zhisheng` 已在
    /// 主 App Info.plist 的 CFBundleURLTypes 注册。
    @MainActor
    func perform() async throws -> some IntentResult {
        guard let url = URL(string: AppRouter.refreshURLString) else {
            // URL 构造失败（理论上不可能，常量字面量）—— 仅放弃派发，
            // 主 App 仍会被 openAppWhenRun 拉起，用户手动刷新即可。绝不 fatalError。
            return .result()
        }
        await EnvironmentValues().openURL(url)
        return .result()
    }
}

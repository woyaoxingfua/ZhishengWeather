//
//  WidgetRefreshIntent.swift
//  Core / Logic  [App + Widget 共用]
//
//  A1-7 可交互刷新（ARCH-A1 §1.7，裁定备选 C；偏差备案 D-A2）：
//
//    Button(intent: WidgetRefreshIntent())  [Medium/Large 右上角]
//      → openAppWhenRun = true：系统在主 App 进程执行 perform()
//      → perform() 先经 AppGroupStore 写「pending force refresh」标志位，
//        再 best-effort 经 openURL 派发深链，返回 .result() 拉起主 App
//      → 主 App 侧：
//          · scenePhase .active 时先消费标志位 → consumePendingForceRefreshAndRefresh（强刷）；
//          · 若深链 onOpenURL 也到达 → AppRouter.handle → viewModel.refresh()（强刷，冗余无害）；
//      → 取数 → 写共享容器 → reloadAllTimelines()（既有全链路复用）
//
//  纪律：
//  - **widget 零网络零写入**（F-C-8 结构性防线）：本 Intent 不含任何
//    网络类型引用、不写共享容器载荷 —— 只写一枚布尔标志位 + 派发深链意图，
//    「真正取数 / 写共享容器」交由主 App 完成。
//  - 标志位路径是跨进程拉起后「确定性强刷」的主通道（openURL 在某些
//    系统版本 / 已前台场景可能不触发 onOpenURL，标志位兜底）；两通道并存、
//    强刷幂等，重复刷新无副作用。
//  - AC-A1-21 已降级（PRD v1.1 勘误 / D-A2）：跨进程链路下系统按钮 loading
//    只覆盖毫秒级，无法展示主 App 取数进度；落地面 = 主 App 到前台展示
//    刷新过程，失败时 widget 保持旧数据 + 更新时间戳不变脏。
//
//  注意：AppIntent 需同时编译进主 App target 与 Widget target
//  （openAppWhenRun 时系统在主 App 进程执行）。本文件位于 Core/Logic，
//  由 project.yml 自动挂入两 target（与 Core 其余 Logic 同路径）；
//  `AppGroupStore` 同样位于 Core，故引用无障碍。
//

import AppIntents
import Foundation
import SwiftUI

/// 小组件刷新按钮的意图：写标志位 + 拉起主 App 并路由到强刷。
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

    /// 深链常量（CI run9 实测勘误）：**必须与主 App 侧 `AppRouter.refreshURLString`
    /// 逐字一致**（"zhisheng://refresh"，Info.plist CFBundleURLTypes 已注册 scheme）。
    /// 不直接引用 AppRouter：它属于主 App target（ZhishengWeather/ 目录），
    /// 本文件虽位于 Core，但被两 target 同时编译，为避免隐式耦合仍用独立字面量；
    /// 同步纪律：改动任一侧字面量必须同步另一侧（两端有 grep 可查的注释锚点）。
    private static let refreshURLString = "zhisheng://refresh"

    /// 空构造：Button(intent: WidgetRefreshIntent()) 直用。
    init() {}

    /// 执行体：
    /// 1. 写「pending force refresh」标志位（主 App 在 scenePhase .active 消费，确定性强刷）；
    /// 2. best-effort 经 openURL 派发深链，由主 App `ContentView.onOpenURL → AppRouter` 消费；
    /// 3. 返回 .result() 拉起主 App。
    ///
    /// 实现说明：`EnvironmentValues().openURL` 是 AppIntents 提供的
    /// 进程内打开 URL 通道（iOS 17+）；深链 scheme `zhisheng` 已在
    /// 主 App Info.plist 的 CFBundleURLTypes 注册。
    @MainActor
    func perform() async throws -> some IntentResult {
        // 1. 写强刷标志位（独立 key，不污染 payload/cities）。AppGroupStore 默认挂 App Group
        //    suite；若该 suite 因 entitlement 缺失回落私有容器，openAppWhenRun 已确保 perform
        //    在主 App 进程执行，故标志位仍在主 App 私有容器内，消费方可读回。
        AppGroupStore().markPendingForceRefresh()

        // 2. best-effort 派发深链（冗余通道，失败不阻断标志位路径）。
        guard let url = URL(string: Self.refreshURLString) else {
            // URL 构造失败（理论上不可能，常量字面量）—— 仅放弃派发，
            // 主 App 仍会被 openAppWhenRun 拉起并消费标志位强刷。绝不 fatalError。
            return .result()
        }
        await EnvironmentValues().openURL(url)
        return .result()
    }
}

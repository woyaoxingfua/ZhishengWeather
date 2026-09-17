//
//  AppShortcuts.swift
//  ZhishengWeather（主 App target）
//
//  AppIntents 快捷指令（决策优先转向 · 第二条）：让 App 出现在**快捷指令 App /
//  Spotlight / 操作按钮（Action Button）**里，替代静态 Info.plist 快捷方式的
//  覆盖面（静态 UIApplicationShortcutItems 只覆盖主屏长按，不入前述系统面）。
//
//  ⚠️ iOS 17 AppIntents 无需任何 Info.plist 改动：系统经编译期元数据
//  （AppIntentsSSU / metadata extraction）自动发现 AppShortcutsProvider——
//  这正是 AppIntents 优于静态 plist 声明之处（后者必须手维护
//  UIApplicationShortcutItems 数组）。故本文件不触碰 Config/ 任何文件。
//
//  路由纪律： intents **不发明平行导航**——统一映射到既有 `AppRouter.Route`
//  （refresh / searchCity），再经 `AppRouter.handleShortcut` 通道消费；与静态
//  快捷方式 / 深链共用同一出口与同一目的地。settings 未暴露（ frozen scope：
//  只做打开天气 / 刷新 / 城市搜索三项）。
//
//  可测性（P-18 同源盲区防线）：intent 体内只做一行转发；所有「映射决策」
//  收敛在 `ShortcutRouteMapping` 纯函数里，可 @testable 单测。AppIntents 声明
//  本身（phrases / titles）为声明式代码，仅 CI 编译验证——诚实声明，不做假单测。
//

import AppIntents
import Foundation

// MARK: - 可单测的路由映射（纯函数，AppIntents 类型无关）

/// 快捷指令目的地 → 既有路由枚举的**唯一映射点**（纯函数）。
enum ShortcutRouteMapping {

    /// 快捷指令动作标识。
    enum Action: Equatable, Sendable {
        /// 打开天气（主屏）。
        case openWeather
        /// 刷新天气。
        case refreshWeather
        /// 城市搜索。
        case searchCity
    }

    /// 动作 → AppRouter 既有路由（openWeather 无强刷语义 → 不映射 refresh，
    /// 静态快捷方式时代它同样不经 AppRouter；此处返回 nil 表示仅打开 App）。
    /// - Parameter action: 快捷指令动作。
    /// - Returns: 既有路由；nil = 无需路由（仅 `openAppWhenRun` 打开 App）。
    static func route(for action: Action) -> AppRouterRoute? {
        switch action {
        case .openWeather:
            return nil
        case .refreshWeather:
            return .refresh
        case .searchCity:
            return .searchCity
        }
    }
}

/// AppRouter.Route 的**测试替身枚举**（结构等价镜像）。
///
/// 为什么不直接用 `AppRouter.Route`：`AppRouter` 是 @MainActor 隔离类型，
/// 其嵌套 Route 在非隔离上下文引用需跨 actor；而本映射函数要保持纯函数
/// （无隔离约束）以便 Widget 侧未来复用。镜像枚举 + 单测锁定逐 case 对齐
/// （见 AppShortcutRouteMappingTests），漂移会被 CI 抓住。
enum AppRouterRoute: Equatable, Sendable {
    /// 强刷当前城市（对应 AppRouter.Route.refresh）。
    case refresh
    /// 城市列表（对应 AppRouter.Route.searchCity）。
    case searchCity
}

// MARK: - AppIntents（声明式；体内仅一行转发，无平行导航）

/// 打开天气：仅唤起 App 到主屏（不强制刷新，尊重 15 分钟节流）。
struct OpenWeatherIntent: AppIntent {

    /// 运行时唤起 App（AppIntents 要求显式声明）。
    static let openAppWhenRun = true

    static var title: LocalizedStringResource = "打开天气"

    static var description: IntentDescription {
        IntentDescription(
            "打开枳生天气查看当前天气",
            categoryName: "天气"
        )
    }

    /// 执行：仅打开 App（openAppWhenRun 已完成唤起），无路由副作用。
    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// 刷新天气：唤起 App 并强刷（绕过节流，与静态快捷方式 / 深链同一通道）。
struct RefreshWeatherIntent: AppIntent {

    static let openAppWhenRun = true

    static var title: LocalizedStringResource = "刷新天气"

    static var description: IntentDescription {
        IntentDescription(
            "打开枳生天气并立即刷新当前城市数据",
            categoryName: "天气"
        )
    }

    func perform() async throws -> some IntentResult {
        // 经既有路由出口发布待消费令牌（ContentView onChange 消费 → 强刷）。
        // 快捷指令执行时 App 必在前台/启动中，主 App target 可合法触碰
        // UIApplication 系类型所在的 AppRouter（同 AppDelegate 入口）。
        await MainActor.run {
            AppRouter.shared.handleShortcut(type: AppRouter.shortcutTypeRefresh)
        }
        return .result()
    }
}

/// 城市搜索：唤起 App 并跳到城市列表（与静态快捷方式同一目的地，D-A3 口径不变）。
struct SearchCityIntent: AppIntent {

    static let openAppWhenRun = true

    static var title: LocalizedStringResource = "城市搜索"

    static var description: IntentDescription {
        IntentDescription(
            "打开枳生天气并进入城市列表搜索添加城市",
            categoryName: "天气"
        )
    }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            AppRouter.shared.handleShortcut(type: AppRouter.shortcutTypeSearch)
        }
        return .result()
    }
}

// MARK: - AppShortcutsProvider（系统发现入口）

/// 快捷指令提供者：声明后系统自动把 entries 注册进 快捷指令 App / Spotlight /
/// 操作按钮。**无需 Info.plist 改动**（iOS 17 AppIntents 编译期元数据自动发现）。
struct ZhishengWeatherShortcuts: AppShortcutsProvider {

    /// 中文短语（\(.applicationName) 由系统替换为 App 名「枳生天气」）。
    /// 与静态 Info.plist 快捷方式并存不冲突（两套入口、同一目的地）。
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenWeatherIntent(),
            phrases: [
                "用\(.applicationName)打开天气",
                "\(.applicationName)天气"
            ],
            shortTitle: "打开天气",
            systemImageName: "cloud.sun.fill"
        )
        AppShortcut(
            intent: RefreshWeatherIntent(),
            phrases: [
                "用\(.applicationName)刷新天气",
                "\(.applicationName)刷新"
            ],
            shortTitle: "刷新天气",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: SearchCityIntent(),
            phrases: [
                "用\(.applicationName)搜索城市",
                "\(.applicationName)城市"
            ],
            shortTitle: "城市搜索",
            systemImageName: "magnifyingglass"
        )
    }
}

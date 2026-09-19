//
//  RootView.swift
//  ZhishengWeather（主 App target）
//
//  根视图：把「外观档位 + 系统深浅」经纯函数解析为配色标识，写入全局
//  `Theme.activePalette`，并以 `.id(配色标识)` 强制重建整棵视图树。
//
//  == 重绘机制与取舍（写入提交信息） ==
//  为什么必须「重建」：Theme 的配色 token 是**静态计算属性**（读全局
//  activePalette）。改动全局变量不会让 SwiftUI 感知到「body 依赖变了」，
//  因此单纯改 activePalette 不会触发重绘。只有改变视图**身份**（`.id`）
//  才会让 SwiftUI 丢弃并重建子树，从而让所有视图重新读取 token。
//  机制：`AppearanceStore`（@Observable）→ 根视图观察 → `.id(配色标识)`。
//  代价（取舍）：重建会重置子树内的瞬态状态（NavigationStack 路径、滚动位置、
//  `@State`），故切换外观后会回到主屏。外观切换是**低频且用户主动**的行为，
//  该代价可接受；换来的是「零重启、全量可靠重绘」。
//

import SwiftUI

/// App 根视图。
@MainActor
struct RootView: View {

    /// 视图模型（App 级单例）。
    let viewModel: WeatherViewModel

    /// 外观存储（App 级单例）。
    let appearance: AppearanceStore

    /// 实时活动管理器（与 VM 同一实例，透传给 ContentView → 设置页）。
    let activityManager: WeatherActivityManager

    /// 系统深浅（仅在「跟随系统」档位下参与解析）。
    @Environment(\.colorScheme) private var systemScheme

    /// 当前应生效的配色标识（纯函数解析，分支不在 body 内散落）。
    private var paletteID: ThemePaletteID {
        ThemePalette.resolve(appearance: appearance.setting, systemScheme: systemScheme)
    }

    /// 需要向系统声明的深浅偏好（「跟随系统」时为 nil = 不覆盖）。
    private var preferredScheme: ColorScheme? {
        switch appearance.setting {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    var body: some View {
        // 渲染前把解析结果写入全局配色真源（幂等）；随后 `.id` 变化会重建子树，
        // 保证所有视图读取到新 token。
        let id = paletteID
        let _ = Theme.activePalette = ThemePalette.palette(for: id)
        ContentView(viewModel: viewModel, appearance: appearance, activityManager: activityManager)
            .preferredColorScheme(preferredScheme)
            .id(id)
    }
}

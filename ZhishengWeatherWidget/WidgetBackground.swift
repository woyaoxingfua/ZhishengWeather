//
//  WidgetBackground.swift
//  ZhishengWeatherWidget（Widget target）
//
//  小组件背景的 **iOS 16 / iOS 17 双写兼容层**。
//
//  背景：iOS 17 起 WidgetKit 要求「可移动的小组件」使用
//  `.containerBackground(for: .widget) { ... }` 描述背景（系统需要把它裁到
//  圆角容器里）。在 iOS 16.x 上该 API **不存在**，且 iOS 16 上
//  `.containerBackground` 修饰符本身不可用 —— 必须退回
//  `.padding(...)` + `.background(...)` 的旧写法（旧写法由 SwiftUI 自己
//  在时间线视图最外层铺满，视觉上等价）。
//
//  注意：本文件位于 Widget target（不在 Core/），因此可以自由使用
//  `#available` 与 WidgetKit API；`Core/` 内仍禁止 UIKit/UIApplication。
//

import SwiftUI
import WidgetKit

/// 把一个「内容视图」包成小组件可用的背景容器。
///
/// 泛型化的原因：若直接用 `let background: () -> AnyView`，Swift 会因
/// `ViewModifier.body(content:)` 的返回类型推断牵扯到该存储属性的类型而报
/// 「无法推断 `some View`」；用 `@ViewBuilder` 闭包作为泛型属性即可规避。
///
/// - iOS 17+：调用 `.containerBackground(for: .widget) { 背景 }`，内边距由内容自管。
/// - iOS 16 ：调用 `.padding(默认内边距)` + `.background(背景)`。
///
/// 之所以要把旧写法的 `padding` 收进本修饰符，是为了让各尺寸的布局视图
/// **只表达内容语义**，不再各自重复 `if #available` 分支。
struct WidgetBackgroundModifier<Background: View>: ViewModifier {

    /// 背景视图构建器（`@ViewBuilder` 支持多行 / 条件内容）。
    let background: () -> Background

    /// iOS 16 旧写法的外内边距。iOS 17 走 `containerBackground` 时不再额外加，
    /// 由调用方（各尺寸 View）自行设置内容 padding，避免双重内边距。
    private let legacyPadding: CGFloat = 16

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .containerBackground(for: .widget) {
                    background()
                }
        } else {
            content
                .padding(legacyPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(background())
        }
    }
}

extension View {

    /// 为小组件内容套上兼容 iOS 16 / 17 的背景。
    ///
    /// - Parameter background: 背景视图（通常传 `Theme.background`）。
    /// - Returns: 已套好背景的视图。
    func widgetBackground<Background: View>(
        @ViewBuilder _ background: @escaping () -> Background
    ) -> some View {
        modifier(WidgetBackgroundModifier(background: background))
    }
}

// MARK: - TimelineProvider 侧的可用性判据

/// 当前运行环境是否为 iOS 17 及以上。
///
/// 为什么要放在 provider 侧单独判断（任务 B 明确要求）：
/// Timeline / Entry 一旦被系统缓存并跨「App 升级 + 系统升级」复用，View 层
/// 的 `#available` 只解决「怎么画」，而 provider 还需要知道「要不要在
/// `getTimeline` 里为 iOS 16 追加一次 `.atEnd` 兜底刷新」——两者判据必须同源，
/// 故在此集中定义，避免 View 与 Provider 各写一份而漂移。
enum WidgetRuntime {

    /// 运行时是否支持 `containerBackground(for: .widget)`。
    static var supportsContainerBackground: Bool {
        if #available(iOS 17.0, *) {
            return true
        } else {
            return false
        }
    }

    /// 兼容 `supportsContainerBackground` 的历史名称，语义一致。
    static var isIOS17OrLater: Bool {
        supportsContainerBackground
    }
}

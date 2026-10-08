//
//  CardCollapseButton.swift
//  ZhishengWeather（主 App target）
//
//  **卡内折叠按钮**（2026-10-08）：主屏 8 张附加卡右上角的折叠/展开开关。
//  与设置页的「主屏卡片」开关是**同一份状态的两个入口**（不是两套状态）：
//  两者都读写 `CardVisibilityStore`，在任一处改动，另一处下次读到即一致。
//
//  ── 为什么放在 App target 而不是 `Core/UI/Components/` ──────────────────
//  `project.yml` 把 `Core/` **同时**挂到主 App 与 Widget 两个 target
//  （"一份逻辑、两处复用"）。而 `MainCard` / `CardVisibilityStore` 定义在
//  `ZhishengWeather/`，**只属于主 App** —— 小组件不感知这些卡片
//  （与 `HomeSection` 的 AC-A2-23 决策一致）。
//  故本控件若放进 `Core/`，Widget target 会因找不到 `MainCard` 而**编译失败**。
//  这是"按目录分层"与"按 target 分层"两条轴的必然交叉点，此处从 target 维度裁决。
//
//  ── 折叠语义（与 `CardVisibilityStore` 文件头一致）──────────────────────
//  · **折叠** = 卡还在、只占一行标题，主体内容不渲染。
//  · **隐藏** = 卡整个不出现（设置页开关）。隐藏的卡不显示，故谈不上折叠。
//  · 落库一律走 `CardVisibilityStore.toggleCollapsed(_:)`，**不在本文件拼键**。
//
//  本仓纪律：类型级 `@MainActor`（P-06）；禁 `try!` / `fatalError` / `as!`（SC-10）；
//  图标只用本仓已实际用过的 SF Symbol（P-24：`chevron.down` / `chevron.right`
//  均见 `ContentView` / `OfficialWarningCard` / `TyphoonCard`）。
//

import SwiftUI

/// 卡片右上角的折叠/展开按钮（两态图标 + 无障碍标签）。
///
/// ⚠️ **类型级 `@MainActor`** —— 本仓每个 `struct ... : View` 都带（P-06）。
/// 本类型额外需要它来调 `@MainActor` 的 `CardVisibilityStore`。
@MainActor
struct CardCollapseButton: View {

    /// 这张卡（用于落库与无障碍文案，如「展开降水雷达」）。
    let card: MainCard

    /// 当前是否处于**折叠**态（由各卡自己的 `@State` 持有）。
    let isCollapsed: Bool

    /// 点击回调（各卡实现：落库 + 改 `@State` + 动画）。
    let onToggle: () -> Void

    var body: some View {
        Button {
            onToggle()
        } label: {
            Image(systemName: Self.symbolName(isCollapsed: isCollapsed))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.accessibilityText(card: card, isCollapsed: isCollapsed))
    }

    // MARK: - 图标 / 文案（提成 static，避免在 body 里内联三元）

    /// 两态图标：**展开中显示 `chevron.down`**（点它向下折起）、
    /// **折叠中显示 `chevron.right`**（点它向右展开）。
    ///
    /// ⚠️ 与本仓既有约定一致：`chevron.down` 用于「当前展开着、可下折」
    /// （`ContentView` 城市下拉），`chevron.right` 用于「当前收起、可展开」
    /// （`ContentView` 两处 `NavigationLink` / `TyphoonCard`）。
    nonisolated static func symbolName(isCollapsed: Bool) -> String {
        isCollapsed ? "chevron.right" : "chevron.down"
    }

    /// 无障碍标签（VoiceOver 读出当前**将执行**的动作，而非当前状态）。
    ///
    /// ⚠️ `.accessibilityLabel` 在本仓已用于 `ContentView` / `CityListView` /
    /// `DailyForecastRow`，此处沿用同款写法；**不用** `.labelsHidden()`
    /// （该修饰符本仓无既有用例，`SatelliteCard` 内已明确标注过这条纪律）。
    nonisolated static func accessibilityText(card: MainCard, isCollapsed: Bool) -> String {
        isCollapsed ? "展开\(card.displayName)" : "折叠\(card.displayName)"
    }

    // MARK: - 折叠切换（各卡统一走这里，保证口径一致）

    /// 切换折叠态并返回**变更后**的折叠态。
    ///
    /// ⚠️ **返回 store 的真值**而不是 `!isCollapsed`：
    /// `toggleCollapsed` 在「折叠一张已隐藏的卡」时会顺带取消隐藏
    /// （见 `CardVisibilityStore.toggleCollapsed` 的注释），此时
    /// 「本地取反」与「store 真值」可能不一致 —— 一律以 store 为准。
    static func toggleCollapsed(_ card: MainCard) -> Bool {
        CardVisibilityStore.toggleCollapsed(card)
        return CardVisibilityStore.isCollapsed(card)
    }
}
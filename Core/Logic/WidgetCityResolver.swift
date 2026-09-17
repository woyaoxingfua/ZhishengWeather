//
//  WidgetCityResolver.swift
//  Core / Logic  [App + Widget 共用]
//
//  F-C 桌面小组件城市选择：实例配置 + **原始容器** + 内置目录 → 目标城市的
//  **纯函数**解析（城市阶梯 C0/C1/C2 的判定入口）。
//  widget 配置解析与 timeline 构造共用；Core 随主 App target 编译，
//  `@testable import` 可直接单测（AC-C9 被测主体）。
//
//  关键裁定：
//  - R-C1（哨兵）："跟随 App" = 非可选参数 + 哨兵实体（id = followAppID），
//    不用"可选参数 + nil 默认"；哨兵 id 与 `City.makeID` 产物（"%.2f,%.2f"）
//    格式互斥（R-5），判定集中在 `mode(forEntityID:)`，禁止散落字符串比较。
//  - 解析优先级**写死**（ARCH §7.1，P-13 纪律）：见 `resolveOutcome`。
//  - **幽灵北京修复（ARCH §7.2 / §10-3）**：输入语义从 `CityDirectory`
//    改为 `WidgetContainerSnapshot`（**原始**容器）。旧实现接收
//    `CityDirectory.loadReadOnly` 的产物，而它在 `.missing` / `.corrupt` 时返回
//    `CityDirectory.initial()` = `[北京] + 选中北京` → `.followApp` 分支解析出
//    **北京** → 未签名产物上小组件顶着「北京」标题显示「暂无数据」，
//    把**防御性默认城市**冒充成用户的**城市归属**（决策 #4 明令禁止）。
//    现在容器真空即 `.needsConfiguration`（诚实空态），**绝不**注入 `initial()`。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 小组件实例的城市解析器（无状态纯函数）。
enum WidgetCityResolver {

    /// "跟随 App"哨兵 id（R-C1 唯一真源）。
    ///
    /// `WidgetCityEntity.followAppID` 引用此处常量；全仓禁止再写
    /// "follow-app" 字面量。与 `City.makeID` 产物格式（数字+逗号+小数点）
    /// 不可能冲突（含字母与连字符）。
    static let followAppID = "follow-app"

    /// 实例的配置模式（由 Intent 的 entity.id 映射而来）。
    enum Mode: Equatable, Sendable {
        /// 哨兵 id → 跟随主 App 选中（AC-C2）。
        case followApp
        /// 固定某城市（AC-C3）。
        case fixed(cityID: String)
    }

    /// 配置 entity id → 模式（哨兵判定**集中于此**）。
    /// - Parameter id: Intent 参数携带的 entity id。
    /// - Returns: `.followApp`（哨兵）或 `.fixed`（城市 id）。
    static func mode(forEntityID id: String) -> Mode {
        id == followAppID ? .followApp : .fixed(cityID: id)
    }

    /// 配置 + **原始容器** + 内置目录 → 本实例应渲染的目标城市。
    ///
    /// 优先级（**写死**，实现与测试不得各自解读 —— P-13）：
    ///   0. 哨兵 id → `.followApp` 分支：
    ///      a. `container.selectedID` 在 `container.cities` 中命中 → `.resolved(该城市)`；
    ///      b. 否则（容器空 / 选中失效）→ `.needsConfiguration`
    ///         ⚠️ **绝不**注入 `CityDirectory.initial()` 的北京（幽灵北京修复点）。
    ///   1. id 命中**容器**目录 → `.resolved(容器城市，全量元数据)`；
    ///   2. 否则命中**内置**目录（C1）→ `.resolved(内置城市，全量元数据)`；
    ///   3. 否则 id 可解析为**规范坐标** → `.resolved(坐标回填 City(name: 配置携带名))`；
    ///   4. 否则 → `.needsConfiguration`（不冒充、不默认）。
    ///
    /// 与旧规则的差别（有意变更）：`.fixed` 未命中**不再**回退成 `.followApp` 语义 ——
    /// 旧的双层回退在「用户已选城市但容器被清空」时会**静默换成 App 当前城市**，
    /// 正是决策 #4 禁止的行为；新规则改为坐标 id 优先回填真实坐标，
    /// 真正无法解析（既非目录项、又非合法坐标）才 `.needsConfiguration`。
    ///
    /// - Parameters:
    ///   - selection: 本实例的配置值（id / name / subtitle 的 Core 侧投影）。
    ///   - container: **原始**容器城市快照（missing / corrupt → 空数组）。
    ///   - builtIn: 内置城市目录（C1，保证选择器非空）。
    /// - Returns: 城市解析结果；无城市 → `.needsConfiguration`（UI 走「请配置城市」空态）。
    static func resolveOutcome(selection: WidgetCitySelection,
                               container: WidgetContainerSnapshot,
                               builtIn: [City]) -> WidgetCityOutcome {
        switch mode(forEntityID: selection.id) {
        case .followApp:
            // 容器里有「用户在主 App 主动选中」的城市才跟随；容器真空 → 无城市。
            guard let selectedID = container.selectedID,
                  let selected = container.cities.first(where: { $0.id == selectedID }) else {
                return .needsConfiguration
            }
            return .resolved(selected)

        case .fixed(let cityID):
            // C0 → C1：容器优先（全量元数据），其次内置目录（C1 新增能力）。
            if let city = WidgetCityCatalog.city(forID: cityID,
                                                container: container.cities,
                                                builtIn: builtIn) {
                return .resolved(city)
            }
            // C2 回填：非目录项但合法规范坐标 id → 用坐标 + 配置携带名重建城市。
            if let city = WidgetCityCatalog.city(fromCanonicalID: cityID, name: selection.name) {
                return .resolved(city)
            }
            // 怪值（既非目录项、又非合法坐标）→ 如实空态，**不**静默改城市。
            return .needsConfiguration
        }
    }
}

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
//  - **AC-C5 分层回退（B 组回归修复）**：`.fixed` 未命中两条目录时，是否可用
//    **坐标回填**取决于**容器是否可用**（= 信息是否可得），而不是无条件回填。
//    详见 `resolveOutcome` 第 3 步。
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
    ///   0. 哨兵 id → `.followApp` 分支（`followAppOutcome`）：
    ///      a. `container.selectedID` 在 `container.cities` 中命中 → `.resolved(该城市)`；
    ///      b. 否则（容器空 / 选中失效）→ `.needsConfiguration`
    ///         ⚠️ **绝不**注入 `CityDirectory.initial()` 的北京（幽灵北京修复点）。
    ///   1. id 命中**城市目录** → `.resolved(该城市，全量元数据)`。
    ///      目录口径 = `WidgetCityCatalog.city(forID:container:builtIn:)`，**容器项优先**
    ///      （用户自己加的项带容器侧元数据；仅在容器未命中时才落到内置目录 C1）。
    ///      内置目录的存在意义见第 3 步：它保证「从未联网的内置列表里选的城市」
    ///      **永远不算「被删除」**。
    ///   2. 两条目录**都不命中** → 按**信息是否可得**分层（AC-C5，B 组回归修复）：
    ///      a. 容器**可用**（能读到容器）→ 说明这条记录**确已不存在**
    ///         （用户在主 App 删了它）→ **回退 `.followApp` 语义**
    ///         （跟随 App；App 侧也无有效选中 → `.needsConfiguration`）。
    ///         **不做坐标回填** —— 回填会让小组件继续显示、并继续为
    ///         一个「已被用户删除的城市」取数，与 AC-C5 直接冲突（真机可复现）。
    ///      b. 容器**不可用**（未签名侧载 / entitlements 失效）→ **无法得知**
    ///         是否被删除 → 才允许**坐标回填**（C2）：
    ///         id 可解析为规范坐标 → `.resolved(回填的 City，名取配置携带值)`。
    ///   3. 其余（非法坐标的怪值）→ `.needsConfiguration`（不冒充、不默认）。
    ///
    /// 与初版规则的差别（有意变更）：初版在第 2 步**无条件**坐标回填 ——
    /// 等于让「已被用户删除的城市」继续存活并继续取数（AC-C5 违规）。
    /// 现改为**先判容器是否可用**，只在「无法得知是否被删除」时才回填；
    /// 并在容器可用时按 AC-C5 回退到「跟随 App」，而非静默保留一个已删除的城市。
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
            return followAppOutcome(container: container)

        case .fixed(let cityID):
            // 第 1 步：命中城市目录（容器项优先，其次内置目录 C1）→ 直接用目录项。
            if let city = WidgetCityCatalog.city(forID: cityID,
                                                container: container.cities,
                                                builtIn: builtIn) {
                return .resolved(city)
            }

            // 第 2 步：两条目录都不命中 → 按「信息是否可得」分层（AC-C5）。
            if container.containerAvailable {
                // 2a. 容器可用 = 信息可得 → 该城市确已被删除 → 回退「跟随 App」语义。
                //     绝不坐标回填（否则会顶着一个已删除城市继续显示 + 继续取数）。
                return followAppOutcome(container: container)
            }

            // 2b. 容器不可用 = 信息不可得 → 允许坐标回填，保住实例可用
            //     （未签名侧载下容器恒不可用，这是 `.fixed` 实例唯一的存活路径）。
            if let city = WidgetCityCatalog.city(fromCanonicalID: cityID, name: selection.name) {
                return .resolved(city)
            }

            // 第 3 步：怪值（既非目录项、又非合法坐标）→ 如实空态，**不**静默改城市。
            return .needsConfiguration
        }
    }

    /// `.followApp` 语义：容器里有「用户在主 App 主动选中」的城市才跟随，否则诚实空态。
    ///
    /// 哨兵分支与 AC-C5 回退（`resolveOutcome` 第 2a 步）**共用**此实现，
    /// 保证「跟随 App」只有一处定义（避免两处各自解读，P-13）。
    ///
    /// ⚠️ 绝不注入 `CityDirectory.initial()` 的北京：容器真空 = 用户从未在主 App
    /// 选过城市 → 如实空态（幽灵北京修复点）。
    /// - Parameter container: **原始**容器城市快照。
    /// - Returns: `.resolved(选中城市)`；选中缺失或失效 → `.needsConfiguration`。
    private static func followAppOutcome(container: WidgetContainerSnapshot) -> WidgetCityOutcome {
        guard let selectedID = container.selectedID,
              let selected = container.cities.first(where: { $0.id == selectedID }) else {
            return .needsConfiguration
        }
        return .resolved(selected)
    }
}

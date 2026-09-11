//
//  WidgetCityResolver.swift
//  Core / Logic  [App + Widget 共用]
//
//  F-C 桌面小组件城市选择：实例配置模式 → 目标城市的**纯函数**解析。
//  widget 配置解析与 timeline 构造共用；Core 随主 App target 编译，
//  `@testable import` 可直接单测（AC-C9 被测主体）。
//
//  关键裁定：
//  - R-C1（哨兵）："跟随 App" = 非可选参数 + 哨兵实体（id = followAppID），
//    不用"可选参数 + nil 默认"；哨兵 id 与 `City.makeID` 产物（"%.2f,%.2f"）
//    格式互斥（R-5），判定集中在 `mode(forEntityID:)`，禁止散落字符串比较。
//  - 解析规则写死（ARCH-FC §2.1），避免实现歧义。
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

    /// 配置 + 目录 → 本实例应渲染的目标城市。
    ///
    /// 规则（写死，避免实现歧义）：
    ///   1. `.followApp` → `directory.selectedCity`（AC-C2；目录空 → nil）；
    ///   2. `.fixed(cityID)` → `cities` 中查找：
    ///      - 命中 → 该城市（AC-C3）；
    ///      - 未命中（城市已被删除 / 坏值）→ **回退按 `.followApp` 解析**
    ///        （AC-C5，双层回退的解析层；UI 层回显由 `WidgetCityQuery.entities(for:)` 承担）；
    ///   3. 目录为空（理论不可达：`CityDirectory` 不变式 ≥1，仅 corrupt/missing 防御）→ nil。
    ///
    /// - Parameters:
    ///   - mode: 实例的配置模式。
    ///   - directory: 只读载入的城市目录。
    /// - Returns: nil = 无任何可显示城市 → UI 走"暂无数据"空态。
    static func resolve(_ mode: Mode, directory: CityDirectory) -> City? {
        switch mode {
        case .followApp:
            return directory.selectedCity
        case .fixed(let cityID):
            if let fixed = directory.cities.first(where: { $0.id == cityID }) {
                return fixed
            }
            // 未命中 → 回退 followApp 语义（与 .followApp 分支同一条路径）。
            return directory.selectedCity
        }
    }
}

//
//  WidgetCityIntent.swift
//  ZhishengWeatherWidget（Widget target）
//
//  F-C 桌面小组件城市选择：Intent 三件套
//  （WidgetCityEntity + WidgetCityQuery + WidgetCitySelectionIntent）。
//
//  ⚠️ 「禁联网」硬规则（**绝对规则，不设例外**）：本文件所有方法
//  （`suggestedEntities()` / `entities(for:)` / `defaultResult()`）
//  **只允许纯本地读**（经 `AppGroupStore` 读共享容器；容器不可用 → 只剩哨兵 +
//  内置目录），**禁止任何网络类型引用**；`qa-static-check.sh` SC-40 保持零命中。
//
//  ⚠️ 同源的「禁定位」硬规则（P1-C7 / AC-C15② / AC-C17）：本文件**禁止**引用
//  `CoreLocation` 或 `WidgetLocationProviding`。「当前位置」在本文件里**只是一个
//  静态哨兵项**（`WidgetCityEntity.currentLocation`）：
//    · **恒出现**（不查权限、不看设备状态 —— 候选列表的内容不得依赖运行时状态，
//      否则配置界面的行为不确定，且 CI 与真机必然分歧）；
//    · **不定位**（真正的取点在 `WeatherProvider.timeline`，那才是允许的 IO 路径）。
//  故本文件即便把「当前位置」加进候选，也**零新增 IO**。
//
//  依据：AC-C8（docs/handover/PRD-zhisheng-ios-P1.md §4.4(a)）——
//  「配置解析是纯本地读 + 纯函数映射，不允许任何网络请求」；对应真机判据 F-C-8
//  （飞行模式 + 断 App Group 下，编辑小组件界面仍能打开、不卡死）。
//
//  【C2 撤回声明（team lead 裁定，2026-09-17）】本文件曾一度被
//  docs/handover/ARCH-zhisheng-ios-widget-selfsufficiency.md 的 `废弃-3`
//  **单方面收窄**为「仅 C2（配置界面的城市名搜索，即字符串查询）允许联网」。
//  该收窄**已被否决并撤回**（注意：是**否决**，不是「收窄」）。撤回理由三条：
//    ① 越权：收窄一条已批准、且挂真机判据的 AC，属 AC 拥有者（PM）的权限，
//       架构师 / 实现者无权自行废止；
//    ② 不可验：F-C-8 只能在真机验（本仓唯一编译门禁是 CI，验不了真机），
//       带着不可验证的卡死风险去违一条明文禁令，不成立；
//    ③ 非必要：C2 不是「选择器不为空」的必要条件 —— `suggestedEntities()`
//       已是「哨兵 + 容器城市 + 内置目录（34 城）」，去掉 C2 照样选得到真实城市。
//  另：URLSession 默认超时 60s，在小组件配置界面的执行预算下是**真实卡死风险**。
//  替代方案（内置目录扩容至地级市 / 「当前位置」配置项）见上述 ARCH 文档
//  「裁定记录」一节；本文件不再包含任何联网方法。
//
//  关键裁定：
//  - R-C1：Intent 参数为**非可选** `WidgetCityEntity` + 哨兵实体默认值，
//    不用"可选参数 + nil 默认"（iOS 17 各小版本对 optional parameter 的
//    "清除"交互不一致，属不可控面；哨兵让"跟随 App"成为候选列表第一项）。
//  - 零自管持久化（AC-C4 / F-C-11）：参数值由系统 per-instance 存取，
//    本文件既不写共享 key 也不按 family 分桶。
//  - `WidgetCityEntity` 的**存储形状不变**（id / name / subtitle 三个字段，
//    不加不减）：旧实例由系统按 per-instance 持久化，形状不变即天然兼容；
//    解析所需的坐标就在 `id` 字符串里（规范坐标回填，ARCH §10）。
//

import AppIntents
import Foundation
import WidgetKit

/// 配置界面里的一个城市选项。
struct WidgetCityEntity: AppEntity, Identifiable, Codable, Sendable {

    /// "跟随 App"哨兵 id；唯一真源在 Core 的 `WidgetCityResolver.followAppID`
    /// （R-C5：与 `City.makeID` 产物 "%.2f,%.2f" 格式互斥），此处仅转发，
    /// 全仓禁止再写 "follow-app" 字面量。
    static let followAppID = WidgetCityResolver.followAppID

    /// "当前位置"哨兵 id；唯一真源在 Core 的 `WidgetCityResolver.currentLocationID`
    /// （R-C6：与 `City.makeID` 产物、与 `followAppID` 三者互斥），此处仅转发，
    /// 全仓禁止再写 "current-location" 字面量。
    static let currentLocationID = WidgetCityResolver.currentLocationID

    /// 哨兵实体（候选列表第一项；AC-C1 / AC-C2）。
    static let followApp = WidgetCityEntity(id: followAppID, name: "跟随 App", subtitle: nil)

    /// 「当前位置」哨兵实体（候选列表第二项；AC-C14 / AC-C15②）。
    ///
    /// ⚠️ **恒出现**：不查权限、不定位、不联网（见文件头「禁定位」规则）。
    /// 展示名取自 Core 的 `WidgetLocationResolver.currentLocationName`（AC-C14 明文的
    /// 「当前位置」），避免两处各写一套名字。
    static let currentLocation = WidgetCityEntity(
        id: currentLocationID,
        name: WidgetLocationResolver.currentLocationName,
        subtitle: nil)

    /// Apple 规范形式：AppIntents 编译期抽取器要求 name 为字面量；
    /// 直接 `= "城市"` 会触发 "Expect a compile-time constant literal"（CI 实测）。
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "城市")

    static var defaultQuery = WidgetCityQuery()

    /// City.id 或哨兵 id。
    var id: String
    /// 展示名（"杭州" / "跟随 App"）。
    var name: String
    /// 去歧义副标题（"中国 · 浙江"），nil 安全（AC-B20：缺省绝不渲染 "null"）。
    var subtitle: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)",
                              subtitle: subtitle.map { "\($0)" })
    }

    /// City → Entity（同序同源映射的唯一入口，AC-C1"按 App 内排序"）。
    /// - Parameter city: 目录中的城市。
    /// - Returns: 配置界面选项。
    static func make(_ city: City) -> WidgetCityEntity {
        // 副标题消歧：country / admin1 有则拼"中国 · 浙江"，缺省不渲染占位。
        let subtitle: String?
        switch (city.country, city.admin1) {
        case let (country?, admin1?):
            subtitle = "\(country) · \(admin1)"
        case let (country?, nil):
            subtitle = country
        case let (nil, admin1?):
            subtitle = admin1
        case (nil, nil):
            subtitle = nil
        }
        return WidgetCityEntity(id: city.id, name: city.name, subtitle: subtitle)
    }
}

/// 候选查询。
///
/// 三条方法（`suggestedEntities` / `entities(for:)` / `defaultResult`）**全部纯本地读**，
/// 不含任何网络类型引用（AC-C8：配置解析禁止发起网络请求）；判定逻辑全部在 Core
/// 纯函数（`WidgetCityCatalog` / `WidgetBuiltInCities`），本类型只做 1 行 `map`。
///
/// ⚠️ 本类型**不**符合「配置界面的字符串搜索协议」（C2）—— 那会引入
/// 配置路径联网，违反 AC-C8（详见文件头 C2 撤回声明）。
struct WidgetCityQuery: EntityQuery {

    /// 配置 picker 候选 = **[跟随 App, 当前位置] + 可见城市**（口径见下）。
    ///
    /// 两个哨兵**恒为前两项**且顺序固定：① 「跟随 App」是默认值（AC-C2），
    /// ② 「当前位置」**恒出现**（AC-C15②：不按权限动态隐藏 —— 隐藏会让人以为
    /// 功能不存在；且候选列表内容不得依赖运行时设备状态）。
    ///
    /// 可见城市 = 容器城市（保持共享容器数组顺序 = App 内顺序，AC-C1）
    ///          + 内置城市中**未在容器出现**的（C1 顺序）。
    /// 为什么要拼 C1：App Group 容器在未签名侧载产物上永久为空 → 只列容器城市时
    /// 候选只剩哨兵（一个真实城市都没有），用户**无法主动选择**任何城市。
    /// 注意 C1 **不是**替用户默认城市：只有用户**主动选中**才生效
    /// （决策 #4：绝不静默替换成别的城市）。
    func suggestedEntities() async throws -> [WidgetCityEntity] {
        let container = WidgetCityCatalog.rawCities(from: AppGroupStore().loadCities())
        let visible = WidgetCityCatalog.visibleCities(container: container,
                                                     builtIn: WidgetBuiltInCities.cities)
        return [WidgetCityEntity.followApp, WidgetCityEntity.currentLocation]
            + visible.map(WidgetCityEntity.make)
    }

    /// 系统恢复既有配置值时调用（配置界面的**唯一**回显路径）。
    ///
    /// 必须与解析层同源接 C0/C1（含规范坐标回填），否则「用内置城市 / 坐标配置的实例」在编辑界面
    /// 会被**错误回显成哨兵**（系统只按 id 查回实体）。
    /// 回显优先级：哨兵 → 容器城市 → 内置城市 → 规范坐标回填（名称为 id 串）
    /// → 哨兵（怪值兜底，与 `WidgetCityResolver.resolveOutcome` 的 `.needsConfiguration`
    /// 语义对齐：都表示"这个值没法解析成城市"）。
    ///
    /// ⚠️ 已知限制（ARCH §10-3 / A10）：坐标回填路径拿不到展示名（系统只给 id，
    /// 旧实体不携带 city 记录），故用**坐标串本身**作确定性名称；该路径只出现在
    /// 「用户搜到过、但既不在容器也不在内置目录」的城市上。时区同样缺失 →
    /// 时刻渲染回退设备时区（既有安全行为，绝不硬编码偏移）。
    func entities(for identifiers: [String]) async throws -> [WidgetCityEntity] {
        let container = WidgetCityCatalog.rawCities(from: AppGroupStore().loadCities())
        return identifiers.map { id in
            guard id != WidgetCityEntity.followAppID else { return .followApp }
            guard id != WidgetCityEntity.currentLocationID else { return .currentLocation }
            if let city = WidgetCityCatalog.city(forID: id,
                                                container: container,
                                                builtIn: WidgetBuiltInCities.cities) {
                return WidgetCityEntity.make(city)
            }
            if let city = WidgetCityCatalog.city(fromCanonicalID: id, name: id) {
                return WidgetCityEntity.make(city)
            }
            return .followApp
        }
    }

    /// 默认值 = 哨兵（AC-C2：不是硬编码北京）。
    func defaultResult() async -> WidgetCityEntity? {
        WidgetCityEntity.followApp
    }
}

/// 小组件配置 Intent（三 family 共用同一类型，F-C-9 防线）。
struct WidgetCitySelectionIntent: WidgetConfigurationIntent {

    // 纪律：title / description 用 Apple 示例的 static var + 字面量形式，
    // 编译期抽取器不接受非字面量表达式（CI 实测）。
    static var title: LocalizedStringResource = "城市"
    static var description = IntentDescription(
        "选择此小组件显示的城市；默认跟随主 App 当前选中城市。")

    /// 非可选（R-C1）。**禁止加 `default:`**——AppIntents 要求 default 为
    /// 编译期字面量，静态属性会挂编译（CI 实测）；默认值由
    /// `WidgetCityQuery.defaultResult()` 提供哨兵（AC-C2：不是硬编码北京）。
    @Parameter(title: "城市")
    var city: WidgetCityEntity

    /// 底色三档（A3-5，AC-A3-11）：透明 / 玻璃 / 不透明。
    /// 系统按 per-instance 持久化；默认"玻璃"（与 A1 前视觉一致）。
    @Parameter(title: "底色", default: WidgetBackgroundStyle.glass)
    var backgroundStyle: WidgetBackgroundStyle
}

/// 小组件底色三档（AppIntents 参数枚举）。
enum WidgetBackgroundStyle: String, AppEnum, CaseIterable, Sendable {
    case transparent
    case glass
    case opaque

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "底色")

    static var caseDisplayRepresentations: [WidgetBackgroundStyle: DisplayRepresentation] {
        [.transparent: "透明", .glass: "玻璃", .opaque: "不透明"]
    }
}

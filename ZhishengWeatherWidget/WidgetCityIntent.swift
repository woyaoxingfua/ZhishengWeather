//
//  WidgetCityIntent.swift
//  ZhishengWeatherWidget（Widget target）
//
//  F-C 桌面小组件城市选择：Intent 三件套
//  （WidgetCityEntity + WidgetCityQuery + WidgetCitySelectionIntent）。
//
//  ⚠️ 「禁联网」纪律**收窄**（原陈述「本文件所有方法只允许经 AppGroupStore 读本地
//  共享容器；不含任何网络类型引用」**作废**，被
//  docs/handover/ARCH-zhisheng-ios-widget-selfsufficiency.md §0 / §7.4 取代）：
//    - `suggestedEntities()` / `entities(for:)` / `defaultResult()` → **纯本地**读
//      （经 `AppGroupStore` 读共享容器；容器不可用 → 只剩哨兵 + 内置目录），
//      且仍**不出现任何网络符号**（`qa-static-check.sh` SC-40 保持零命中）；
//    - **仅** `entities(matching:)`（C2：用户在小部件配置界面输入城市名）
//      允许联网，且复用**已存在**的 Core `GeocodingService`（免密钥、中文安全），
//      **不新增端点、不新增凭据、不新增第二套映射**。
//  旧纪律之所以作废：App Group 在未签名侧载产物上永久不可用 → 容器里可能一个
//  真实城市都没有 → 用户**无法主动选择**任何城市 → C2 是唯一能看到任意城市的通道。
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

    /// 哨兵实体（候选列表第一项；AC-C1 / AC-C2）。
    static let followApp = WidgetCityEntity(id: followAppID, name: "跟随 App", subtitle: nil)

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
/// 本地三条（`suggestedEntities` / `entities(for:)` / `defaultResult`）**纯本地读**；
/// 仅字符串搜索 `entities(matching:)`（C2）联网。判定逻辑全部在 Core 纯函数
/// （`WidgetCityCatalog` / `WidgetBuiltInCities`），本类型只做 1 行 `map`。
struct WidgetCityQuery: EntityQuery, EntityStringQuery {

    /// 配置 picker 候选 = **[哨兵] + 可见城市**（口径见下）；哨兵**恒为第一项**。
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
        return [WidgetCityEntity.followApp] + visible.map(WidgetCityEntity.make)
    }

    /// 系统恢复既有配置值时调用（配置界面的**唯一**回显路径）。
    ///
    /// 必须与解析层同源接 C0/C1/C2，否则「用内置城市 / 坐标配置的实例」在编辑界面
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

    /// C2：按城市名搜索候选（配置界面输入时触发；**不进 timeline 路径**）。
    ///
    /// 复用 Core 既有 `GeocodingService`（Open-Meteo geocoding，免密钥、
    /// `language=zh`）—— 零新增端点、零新增凭据、零新增映射。
    /// 空白串直接短路为 `[]`：`GeocodingEndpoint.url` 对空白返回 nil → `badURL`，
    /// 先判空可省一次无意义失败（且让搜索结果为空 ≠ 失败，AC-B19）。
    /// - Parameter string: 用户输入的城市名片段。
    /// - Returns: 候选城市实体；无命中 → 空数组。
    /// - Throws: `WeatherError`（badStatus / network / timeout / decodingDetail）。
    func entities(matching string: String) async throws -> [WidgetCityEntity] {
        let keyword = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        let cities = try await GeocodingService().search(name: keyword)
        return cities.map(WidgetCityEntity.make)
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

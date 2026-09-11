//
//  WidgetCityIntent.swift
//  ZhishengWeatherWidget（Widget target）
//
//  F-C 桌面小组件城市选择：Intent 三件套
//  （WidgetCityEntity + WidgetCityQuery + WidgetCitySelectionIntent）。
//
//  ⚠️ 禁联网（F-C-8 / AC-C8）：本文件所有方法只允许经 AppGroupStore 读本地
//  共享容器（UserDefaults 读为可接受本地 IO）；不含任何网络类型引用 ——
//  T06 静态自查项（grep 网络符号零命中）。
//
//  关键裁定：
//  - R-C1：Intent 参数为**非可选** `WidgetCityEntity` + 哨兵实体默认值，
//    不用"可选参数 + nil 默认"（iOS 17 各小版本对 optional parameter 的
//    "清除"交互不一致，属不可控面；哨兵让"跟随 App"成为候选列表第一项）。
//  - 零自管持久化（AC-C4 / F-C-11）：参数值由系统 per-instance 存取，
//    本文件既不写共享 key 也不按 family 分桶。
//

import AppIntents
import WidgetKit

/// 配置界面里的一个城市选项。
struct WidgetCityEntity: AppEntity, Identifiable, Codable, Sendable {

    /// "跟随 App"哨兵 id；唯一真源在 Core 的 `WidgetCityResolver.followAppID`
    /// （R-C5：与 `City.makeID` 产物 "%.2f,%.2f" 格式互斥），此处仅转发，
    /// 全仓禁止再写 "follow-app" 字面量。
    static let followAppID = WidgetCityResolver.followAppID

    /// 哨兵实体（候选列表第一项；AC-C1 / AC-C2）。
    static let followApp = WidgetCityEntity(id: followAppID, name: "跟随 App", subtitle: nil)

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "城市"

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

/// 候选查询：全部本地读（经 `AppGroupStore`，只读双 key）。
struct WidgetCityQuery: EntityQuery {

    /// 配置 picker 候选 = [哨兵] + 已保存城市（保持共享容器数组顺序 = App 内顺序，AC-C1）。
    ///
    /// 三态语义（与 E-1 同源）：`.missing` / `.corrupt` → 仅 [哨兵]
    /// （空表兜底，AC-C9）。此处**不走** `loadReadOnly` 的 `initial()` 兜底，
    /// 避免把"防御性北京"冒充为用户已保存的城市进入候选列表。
    func suggestedEntities() async throws -> [WidgetCityEntity] {
        let store = AppGroupStore()
        guard case .loaded(let cities) = store.loadCities() else {
            return [WidgetCityEntity.followApp]
        }
        return [WidgetCityEntity.followApp] + cities.map { WidgetCityEntity.make($0) }
    }

    /// 系统恢复既有配置值时调用；对不在列表中的 id（已删除 / 坏值）→ 返回哨兵
    /// （编辑界面回显"跟随 App"，与解析层回退语义一致，AC-C5 的 UI 层）。
    func entities(for identifiers: [String]) async throws -> [WidgetCityEntity] {
        let directory = CityDirectory.loadReadOnly(from: AppGroupStore())
        return identifiers.map { id in
            guard id != WidgetCityEntity.followAppID,
                  let city = directory.cities.first(where: { $0.id == id }) else {
                return .followApp
            }
            return WidgetCityEntity.make(city)
        }
    }

    /// 默认值 = 哨兵（AC-C2：不是硬编码北京）。
    func defaultResult() async -> WidgetCityEntity? {
        WidgetCityEntity.followApp
    }
}

/// 小组件配置 Intent（三 family 共用同一类型，F-C-9 防线）。
struct WidgetCitySelectionIntent: WidgetConfigurationIntent {

    static let title: LocalizedStringResource = "城市"
    static let description = IntentDescription(
        "选择此小组件显示的城市；默认跟随主 App 当前选中城市。")

    /// 非可选 + 默认哨兵（R-C1）。
    @Parameter(title: "城市", default: WidgetCityEntity.followApp)
    var city: WidgetCityEntity
}

//
//  WidgetEntryResolution.swift
//  Core / Logic  [App + Widget 共用]
//
//  小组件自力取数（ARCH-zhisheng-ios-widget-selfsufficiency.md）：
//  两条正交阶梯（城市阶梯 C0/C1/C2、数据阶梯 L0/L1/L2）的**收敛值类型**。
//
//  背景（P-19 的结构性对治）：CI 以 `CODE_SIGNING_ALLOWED=NO` 出**完全未签名**的
//  IPA → entitlements 从不生效 → App Group 容器在侧载产物上**永远不可用** →
//  「小组件只读共享容器」的架构在本产品的分发渠道上**结构性死亡**。
//  故小组件必须能自己取数（L1），同时保留容器快路径（L0）与如实空态（L2）。
//
//  裁定（ARCH §8.2，**不推翻**）：**不**给 `WidgetPayloadStatus` 新增 case。
//  理由（**已按当前事实订正**）：全仓对它的消费是**零穷尽 switch**，实际读取点
//  只有两处 —— `Core/Logic/WidgetCopy.swift` 的 `resolution.status == .stale`，
//  与 `WeatherEntry.swift` 的同名转发属性 `payloadStatus`（纯转发、无判断）。
//  故新增 case **没有任何渲染路径消费它**，只会变成一个**静默无效果**的状态
//  （编译通过、CI 全绿、真机上该状态永不显示）。
//  原文「视图以 `==` 消费、加 case 会静默落到 else 渲染错文案」**已不成立**：
//  视图文案现全部走 `WidgetCopy`，不再直接比较本枚举。
//  来源与空因改用两个**正交**字段表达：空态语义由 `WidgetEmptyReason` 承担，
//  可在 CI 单测里逐条断言，不依赖 Widget 渲染。
//
//  正交性：`WidgetPayloadStatus` 是「有无 + 新旧」单轴；`WidgetDataSource` 是
//  「从哪来」另一轴；`WidgetEmptyReason` 是「为何空」的可操作原因。三者不可合并。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 载荷来源（与「有无 / 新旧」正交的第二条轴）。
///
/// 存在价值是**可测性 + 可诊断性**（单测断言阶梯走到了哪一级），
/// 而**非**面向用户的额外标注：自力取数的数据是真实且刚取回的
/// （`updatedAt = now`），「更新于 HH:mm」已如实反映取数时刻，无折扣需打星号。
enum WidgetDataSource: Equatable, Sendable {

    /// L0：共享容器命中（本地、零配额、命中即用）。
    case sharedContainer
    /// L1：小组件自力取数（复用 `WeatherService`，一轮至多一次请求）。
    case selfFetched
    /// 未取到任何载荷（无城市 / 快照路径未联网 / 取数失败）。
    case none
}

/// 空态原因（驱动 `WidgetCopy` 的**可操作**文案；有载荷时恒为 nil）。
enum WidgetEmptyReason: Equatable, Sendable {

    /// 无城市（容器空 + 哨兵实例 / 配置值无法解析）→ 引导用户配置城市。
    /// **绝不含**「注入 `CityDirectory.initial()` 的北京」这条路径（幽灵北京修复点）。
    case noCity
    /// 快照路径（不联网）且容器无归属缓存 → 待主 App 取数后自动显示。
    case noCachedData
    /// 共享容器不可用（快照路径）→ 提示去主 App 打开一次天气。
    case sharedContainerDown
    /// L1 取数失败（传输层：超时 / 无网络 / 非 2xx / 解码）→ 提示检查网络后重试。
    case fetchFailed
    /// L1 取数成功但该城市**结构性无数据**（`WeatherError.dataMissing`）→ 换城市。
    case cityHasNoData
}

/// 城市阶梯（C0 容器目录 → C1 内置目录 → C2 坐标回填）的产出。
enum WidgetCityOutcome: Equatable, Sendable {

    /// 解析出**用户（直接或经哨兵跟随）指定**的城市，元数据完整。
    case resolved(City)
    /// 无城市可用 → 如实空态、**不取数**。
    ///
    /// ⚠️ 这是「幽灵北京」的修复落点：旧实现在容器为空时经
    /// `CityDirectory.loadReadOnly` → `CityDirectory.initial()` 静默注入北京，
    /// 小组件顶着「北京」标题显示「暂无数据」，把一个**防御性默认城市**冒充成
    /// 用户的城市归属。新实现容器真空即回本分支（诚实空态）。
    case needsConfiguration

    /// 目标城市；`.needsConfiguration` → nil。
    var city: City? {
        switch self {
        case .resolved(let city):
            return city
        case .needsConfiguration:
            return nil
        }
    }
}

/// 供应商 → 视图的**唯一**收敛值（`WeatherProvider.makeResolution` 的返回）。
///
/// 不变式（由 `WidgetDataResolver` 保证，测试逐条断言）：
/// `payload != nil` ⟺ `emptyReason == nil`（有数据就无空因；有空因必无数据）。
struct WidgetEntryResolution: Equatable, Sendable {

    /// 本实例目标城市；nil = 无城市（此时 `emptyReason == .noCity`）。
    var city: City?
    /// 下发给视图的载荷；nil = 空态（此时 `emptyReason` 必非 nil）。
    var payload: SharedWeatherPayload?
    /// 有无 / 新旧（既有枚举，case 集合**不变**）。
    var status: WidgetPayloadStatus
    /// 载荷来源（正交轴之一）。
    var dataSource: WidgetDataSource
    /// 空态可操作原因（正交轴之二）；有载荷时恒为 nil。
    var emptyReason: WidgetEmptyReason?
}

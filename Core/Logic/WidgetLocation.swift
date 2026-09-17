//
//  WidgetLocation.swift
//  Core / Logic  [App + Widget 共用]
//
//  P1-C7「当前位置」：小组件定位取点的**值类型** + **纯判定**。
//
//  分工（P-18 同源盲区纪律）：
//    · 本文件（Core）：定位结果的**分类**（`WidgetLocationOutcome`）、取点器**协议**
//      （`WidgetLocationProviding`）、以及「结果 → 城市阶梯产出」的**纯函数**
//      （`WidgetLocationResolver.outcome(fix:)`）。全部可被 CI 单测。
//    · Widget 侧（`ZhishengWeatherWidget/WidgetLocationService.swift`）：`CLLocationManager`
//      外壳，只做「取一次点」，不含任何判定。Widget target 不进测试包，故判定
//      一律不许写在那边。
//
//  为什么定位走 timeline 路径而不是配置路径（PRD §4.7.2 裁定二）：
//    配置解析路径（`AppEntity` / `EntityQuery` / `WidgetConfigurationIntent` 及其传递依赖）
//    执行预算极低且**绝对禁联网**（AC-C8 / AC-C17 / F-C-8）；定位是 IO，放进去
//    即违令。故配置界面**只放一个静态哨兵项**「当前位置」（不查权限、不定位），
//    真正的取点发生在 `WeatherProvider.timeline`（该路径允许 IO）。
//
//  ⚠️ 三态必须分开（Apple「Accessing location information in widgets」明文）：
//      ① 未获资格（`isAuthorizedForWidgetUpdates == false`）
//      ② 已获资格但**本轮没拿到**坐标（系统只在小组件可见后的一小段时间内提供
//         定位更新 → 「拿不到」是**常态之一**，不是异常）
//      ③ 拿到坐标
//    ① 与 ② 是**两种不同状态**，提示必须不同（见 `WidgetCopy`）。任何把二者合并成
//    一句话的写法都会让用户按错的处方行动。
//
//  ⚠️ 绝不回落（PRD §4.7.2 实施注意 · 决策 #4）：本文件**没有**、也**不得有**任何
//    「定位失败 → 用北京兜底」的分支。主 App 的 `LocationProvider` 在拒绝 / 失败时
//    回落 `.beijing`，那是**主 App 的策略**；小组件照搬即等于把「防御性默认城市」
//    冒充成用户的**城市归属** —— 正是「幽灵北京」缺陷。
//
//  Core 纪律：仅 import Foundation（**不** import CoreLocation：取点器由 Widget 侧实现，
//  故 Core 不需要、也不该依赖 CoreLocation）；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 一轮定位取点的结果（**值**：由调用方注入，Core 自己不发起定位）。
///
/// 与 `LocationOutcome`（主 App 的「最近一次定位请求」分类）的关系：
///   · 语义同源，故 case 名沿用其口径；
///   · 但**不能复用该类型** —— ① 它不携带坐标（`.authorized` 只是「成功了」）；
///     ② 它的 `.undetermined`（授权弹窗未作答）在小组件侧**不存在**：小组件扩展
///     不能弹授权窗，系统的授权问句由 iOS 在「添加组件」时给出，故对小组件而言
///     「未决定」与「已拒绝」是**同一个可操作事实**（都没有资格）→ 合并为
///     `.notAuthorized`，文案也只给一套（见 `WidgetCopy` 的硬规则）。
enum WidgetLocationOutcome: Equatable, Sendable {

    /// 取到坐标（WGS84）。
    case located(latitude: Double, longitude: Double)
    /// **未获资格**：`CLLocationManager.isAuthorizedForWidgetUpdates == false`
    /// （宿主 App 从未请求过授权，或用户拒绝了「允许小组件使用位置」）。
    case notAuthorized
    /// **已获资格但本轮未取到**：超时 / 定位服务不可用 / 系统在小组件不可见后
    /// 停止提供定位更新（Apple 明文：这是常态）。
    case unavailable
}

/// 定位取点器抽象（**只允许 timeline 路径使用**）。
///
/// 为什么把协议放 Core 而不是 Widget 侧：`WeatherProvider` 要能被注入 Fake，
/// 且「什么时候真的去取点」这条判定在 Core（见 `WidgetCityResolver.resolveOutcome`）；
/// 协议在这里，实现（CoreLocation 外壳）在 Widget 侧 —— Core 不依赖 CoreLocation。
///
/// ⚠️ 实现禁用面：
///   · **配置解析路径**（`WidgetCityIntent.swift` 的任何方法及其传递依赖）**禁止**
///     引用本协议 —— 那等于配置界面定位，违反 AC-C8 / AC-C17。
///   · 实现方**禁止**请求授权（`requestWhenInUseAuthorization`）：小组件扩展不能
///     弹授权窗，调用它只会浪费预算；授权由宿主 App + 系统的「添加组件」问句完成。
///
/// 未标 `Sendable` 是**有意**的：实现要持有 `CLLocationManager` 与悬挂的 continuation
/// （可变状态），强行标 `Sendable` 只能靠 `@unchecked` —— 那是把「未经检查」写成
/// 类型保证，正是本仓最反对的做法。生命周期约定：由 `WeatherProvider` 持有，
/// 只在 timeline 的单个 async 上下文里串行使用。
protocol WidgetLocationProviding {

    /// 取一次当前位置；**必须有界**（超时即返回 `.unavailable`，绝不悬挂）。
    /// - Parameter budget: 本次取点的硬上限（秒）。
    /// - Returns: 三态结果之一（本方法**不抛错**：失败即 `.unavailable`）。
    func currentLocationFix(budget: TimeInterval) async -> WidgetLocationOutcome
}

/// 定位结果 → 城市阶梯产出的**纯**映射（无 IO、无时钟、无状态）。
enum WidgetLocationResolver {

    /// 「当前位置」实例的取点硬上限（秒）。
    ///
    /// 取值理由：与主 App `LocationProvider.locationTimeout` 同为 5s —— 正常取点
    /// 远快于此（千米级精度、缓存命中常在亚秒级），5s 只兜「等不到回调」的极端情况。
    /// 与取数预算的关系：两者**串联**且各自独立有界（最坏 5s + 10s = 15s，仍远低于
    /// WidgetKit 给时间线的预算），且定位**不产生任何天气请求** → 不触碰配额纪律
    /// （见 ARCH §14：全路径 `weather.fetch` 恒 ≤ 1 次）。
    static let fixBudget: TimeInterval = 5

    /// 「当前位置」的展示名（AC-C14 明文规定：城市名「当前位置」）。
    ///
    /// 为什么不反地理编码取真实城市名：① PRD 已把展示名定死为「当前位置」；
    /// ② `CLGeocoder` 是**第二次联网**，会挤进同一条 timeline 预算，且引入一个
    /// 新的失败面（拿到坐标却丢了名字 → 又得设计一套降级文案）。
    /// 故此处**不做**反查：坐标照用，名字恒为「当前位置」，时区缺省（见下方
    /// `outcome(fix:)` 的说明）。
    static let currentLocationName = "当前位置"

    /// 定位结果 → 城市阶梯产出（纯函数，**唯一**的映射入口）。
    ///
    /// 三条映射（与 `WidgetLocationOutcome` 一一对应，不留 `default`）：
    ///   · `.located`        → `.resolved(City)`：坐标入 `City.makeID`，名字「当前位置」，
    ///                          `isCurrentLocation = true`（语义：随定位更新坐标）。
    ///                          ⚠️ 时区缺省 nil —— 已知限制（A10 同款）：不反查就没有 IANA 时区，
    ///                          时刻渲染回退**设备时区**；「当前位置」的语义是「用户就在这里」，
    ///                          故设备时区与当地时区通常一致，这是可接受且**不臆造**的兜底
    ///                          （绝不硬编码 +08:00）。
    ///   · `.notAuthorized`  → `.locationNotAuthorized`（引导用户去授权）
    ///   · `.unavailable`    → `.locationUnavailable`（如实说明 + 提供改选城市这条真实出路）
    ///
    /// 本函数**没有**第四条分支：不存在任何「失败 → 换个城市」的路径（决策 #4）。
    /// - Parameter fix: 本轮取点结果（`WeatherProvider` 注入）。
    /// - Returns: 可供 `WidgetDataResolver` 直接消费的城市阶梯产出。
    static func outcome(fix: WidgetLocationOutcome) -> WidgetCityOutcome {
        switch fix {
        case .located(let latitude, let longitude):
            return .resolved(City(name: currentLocationName,
                                  latitude: latitude,
                                  longitude: longitude,
                                  isCurrentLocation: true))
        case .notAuthorized:
            return .locationNotAuthorized
        case .unavailable:
            return .locationUnavailable
        }
    }
}

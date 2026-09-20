//
//  SourceDescriptor.swift
//  Core / Logic  [App + Widget 共用]
//
//  源描述符（T10 §3.5）：一个数据源的**静态元信息**单一真源。
//
//  为什么需要它：接入一个新源原本要记得同时改「id 登记 + 能力枚举 + 设置页目录
//  （SourceCatalog.all）+ 自动摘除开关 + 设置页停用入口」五处，**任一处漏改都静默**
//  （漏目录项 → 自动摘除哑火 + 设置页隐身；漏停用入口 → 用户无法停用它）。
//  现在把它们收敛为**一处声明**（`SourceDirectory.all`），其余全部**派生**。
//
//  边界（勿过度设计）：描述符是**静态声明**，**不承载**运行期状态
//  （健康 / 冷却 / 归属仍在 `SourceHealthTracker` / `SourceHealthLedger` /
//  `SourceAttributionStore`）。"源是真源"这件事，`SourceCatalog` 与
//  `FieldSourceRegistry` 的既有分工不变 —— 描述符只做静态元信息的单一真源，
//  **不引入运行期第二真相源**。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 一个数据源的静态元信息（"声明"）。
struct SourceDescriptor: Sendable {

    /// 稳定标识（`SourceID` 的 case，由编译器保证 `allCases` 完备）。
    let id: SourceID
    /// 展示名（设置页「多源管理」用）。
    let displayName: String
    /// 展示角色（主源 / 辅助源）。**仅供展示**，不再兼任行为开关。
    let role: SourceRole
    /// 该源能提供哪些能力。
    let capabilities: Set<SourceCapability>
    /// 必填字段集（EV-1 判「缺字段」的输入）。
    ///
    /// ⚠️ 只要某字段**列进这里**，它就**自动**参与 EV-1（判据是
    /// `requiredFields` 与补丁实际装载字段的差集，与字段名无关）。
    let requiredFields: Set<WeatherFieldKey>
    /// 该源是否**必须**有凭据才能工作（无凭据 → `.notConfigured`，绝不静默换源）。
    let needsCredential: Bool
    /// 该源是否参与**自动摘除**（EV-1 缺字段 / EV-3 状态码）。
    ///
    /// 这是一个**显式行为开关** —— 此前 `SourceHealthTracker.isAuxiliary` 把
    /// `SourceCatalog.Item.role`（一个**展示标记**）当行为开关用，语义错位本身就是
    /// 风险：改展示文案的人可能顺手改了摘除行为。主源恒为 `false`（R-7：主源只记录、
    /// 不自动摘除）。
    let participatesInAutoExclusion: Bool
}

/// 源目录：**唯一**的手工点（加源 = 此处加一项）。
///
/// 派生关系（消除「漏改点」）：
/// - `SourceCatalog.all`（设置页多源管理目录）← 由本目录派生；
/// - `SourceHealthTracker.isAuxiliary`（自动摘除开关）← 读 `participatesInAutoExclusion`；
/// - 设置页「手动停用」开关 ← 对每个 `participatesInAutoExclusion` 的源生成。
///
/// 守卫（锚**性质**、不锚符号名）：`ZhishengWeatherTests/SourceDirectoryCoverageTests.swift`
/// 断言 `Set(SourceID.allCases) == Set(SourceCatalog.all.map(\.id))` ——
/// 既防**漏加**（声明了却没条目），也防**幽灵条目**（有条目没声明）。
enum SourceDirectory {

    /// 全部源描述符（**唯一**手工点）。
    static let all: [SourceDescriptor] = [
        SourceDescriptor(id: .openMeteoForecast,
                         displayName: "Open-Meteo",
                         role: .primary,
                         capabilities: [.currentObservation, .hourlyForecast,
                                        .dailyForecast, .minutelyPrecipitation],
                         // 主源的必填字段（运行期 EV-1 输入）。**主源不参与自动摘除**，
                         // 故这里只作声明，不驱动任何摘除行为。
                         requiredFields: [.temperature, .weatherCode],
                         needsCredential: false,
                         participatesInAutoExclusion: false),

        SourceDescriptor(id: .openMeteoAirQuality,
                         displayName: "Open-Meteo 空气质量",
                         role: .auxiliary,
                         capabilities: [.airQuality],
                         // 空气源的字段（aqi / pm2.5 / …）**不在** `WeatherFieldKey` 域内
                         // （它们属于 `AirQuality` 模型），故必填集**诚实留空** ——
                         // 绝不塞几个假字段进来充数。
                         // → 后果：空气源目前没有 EV-1 信号源（接线时再补齐字段域）。
                         requiredFields: [],
                         needsCredential: false,
                         // ⚠️ **尚未接线**：目前没有任何调用点对空气源上报
                         // `recordMissingFields` / `recordHTTPStatus`，故置 `false`
                         // 以保持「设置页不给一个点了没反应的开关」这一诚实纪律。
                         // 一旦把空气源接进摘除链，把这里改成 `true`：
                         // 自动摘除与设置页停用入口会**同时**生效（同一处声明）。
                         participatesInAutoExclusion: false),

        SourceDescriptor(id: .sunriseSunset,
                         displayName: "Sunrise-Sunset.org",
                         role: .auxiliary,
                         capabilities: [.solarEvents],
                         requiredFields: [.sunrise, .sunset, .daylightDuration],
                         needsCredential: false,
                         participatesInAutoExclusion: true)
    ]

    /// 按 id 取描述符（未登记 → nil；调用方按「未知源一律不参与自动摘除」处理）。
    static func descriptor(for id: SourceID) -> SourceDescriptor? {
        all.first { $0.id == id }
    }
}

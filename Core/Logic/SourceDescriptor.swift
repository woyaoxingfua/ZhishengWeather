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
    /// 该源的**官网 / 文档地址**（CC BY 4.0 署名义务要求的「可追溯的credit」）。
    ///
    /// ⚠️ 为什么是**非可选**：CC BY 4.0 要求 "giving appropriate credit"，而
    /// 「appropriate credit」的最低形态是**一个指向数据出处的可点击链接**。做成非可选
    /// 是刻意的 —— 新增源时**编译器强制**你填一个链接，漏填直接编译不过，
    /// 而不是静默地少一条署名（那正是本条被加进来要消灭的缺口）。
    ///
    /// 存**字符串**而非 `URL`：URL 是**可选类型**，构造一个非可选 `URL` 必须写
    /// `URL(string:)!` 强制解包 —— 那是一条运行期崩溃路径，且本仓禁 `try!` /
    /// `fatalError`（SC-10）， force-unwrap 与之同族。改由 `websiteURL`
    /// 计算属性做**可失败**转换，并由单测断言「每个源都能解析出 http/https URL」。
    let websiteURLString: String

    /// 解析后的官网地址（字面量写错 → nil，**不崩**）。
    ///
    /// 由 `DataAttributionTests` 断言「每个源都非nil 且 scheme 为 http/https」，
    /// 故 UI 侧可以放心 `if let`。这是本仓纪律的常态取舍：**声明处强约束 +
    /// 解析处可失败 + 测试兜住**，而不是 `URL(string:)!` 的运行期炸弹。
    var websiteURL: URL? {
        URL(string: websiteURLString)
    }

    /// 该源的**如实备注**（nil = 无需额外说明）。
    ///
    /// 存在的理由是**诚实纪律**而非免责声明：某些端点当前免 Key 可用，但上游官方
    /// 定价矩阵并未把它们列入免费档 —— 这属于「现状可用、官方矩阵不含」，
    /// **不得让用户误以为长期免费**，故必须写在用户看得见的地方。
    let usageNote: String?
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
                         participatesInAutoExclusion: false,
                         websiteURLString: "https://open-meteo.com/",
                         usageNote: nil),

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
                         participatesInAutoExclusion: false,
                         websiteURLString: "https://open-meteo.com/en/docs/air-quality-api",
                         usageNote: nil),

        SourceDescriptor(id: .sunriseSunset,
                         displayName: "Sunrise-Sunset.org",
                         role: .auxiliary,
                         capabilities: [.solarEvents],
                         requiredFields: [.sunrise, .sunset, .daylightDuration],
                         needsCredential: false,
                         participatesInAutoExclusion: true,
                         websiteURLString: "https://sunrise-sunset.org/api",
                         usageNote: nil),

        // 第三源：MET Norway（api.met.no locationforecast compact）。
        // 免 Key / 免账号，且是**与 Open-Meteo 不同的数值模式**。
        // ⚠️ `requiredFields` 必须**恰好**等于 `METNorwayMapper` 会写入的字段集合：
        //    · 多写一个 mapper 拿不到的字段（例如 `.windGust`，compact 端点无此字段）
        //      → 本源连续 3 次被判缺字段 → **EV-1 误摘**（设置页显示成"对端故障"，
        //      实际是本地声明写错，且完全静默）；
        //    · 少写一个 mapper 真的写了的字段 → 该字段**永不参与 EV-1**（守卫哑火）。
        //    两侧对齐由 `METNorwayTests.testFullResponseCoversEveryRequiredField` 钉住。
        SourceDescriptor(id: .metNorwayForecast,
                         displayName: "MET Norway",
                         role: .auxiliary,
                         capabilities: [.basicNumericFields],
                         requiredFields: [.temperature, .pressure, .humidity,
                                          .cloudCover, .windSpeed, .windDirection],
                         needsCredential: false,
                         participatesInAutoExclusion: true,
                         websiteURLString: "https://api.met.no/weatherapi/locationforecast/2.0/documentation",
                         usageNote: nil),

        // 第四源：海浪（`marine-api.open-meteo.com`，免 Key、独立子域名）。
        SourceDescriptor(id: .marineForecast,
                         displayName: "Open-Meteo 海浪",
                         role: .auxiliary,
                         capabilities: [.marineWaveConditions],
                         // ⚠️ **诚实留空**：浪高 / 浪向 / 周期 / 涌浪**不在**
                         // `WeatherFieldKey` 域内（它们属于 `MarineConditions` 模型），
                         // 塞几个天气字段进来充数只会让 EV-1 判"永远缺字段"。
                         // → 后果：与 `openMeteoAirQuality` 同处境，**无 EV-1 信号源**。
                         // ⚠️ 反面风险同样要防：**多写一个** mapper 拿不到的字段，
                         //   本源会被连续 3 次判缺字段而**误摘**（见上方 METNorway 注释）。
                         requiredFields: [],
                         needsCredential: false,
                         // 与空气源同处境：尚无调用点上报 `recordMissingFields` /
                         // `recordHTTPStatus`，故 `false` —— 不给设置页一个
                         // 点了没反应的开关（保持诚实纪律）。接线后再改 `true`。
                         participatesInAutoExclusion: false,
                         // ⚠️ 端点已迁到独立子域名，文档地址与之对应（写主站会 404）。
                         websiteURLString: "https://open-meteo.com/en/docs/marine-weather-api",
                         // `nil` = 无需额外说明。**这是核实过的结论，不是省略**：
                         // Open-Meteo 官方定价页的免费档功能表里**逐字列出了**
                         // "Flood API" 与 "Marine API"（2026-10-06 实测抓取），
                         // 故这两个源**在**官方免费矩阵内 —— 与 archive / ensemble
                         // 那种「现状可用、矩阵不含」的情况**相反**，
                         // 不该套用那句"不作长期免费承诺"的备注（那是虚假谨慎）。
                         usageNote: nil),

        // 第五源：河道流量（`flood-api.open-meteo.com`，免 Key、独立子域名）。
        SourceDescriptor(id: .floodForecast,
                         displayName: "Open-Meteo 河道流量",
                         role: .auxiliary,
                         capabilities: [.riverDischarge],
                         // ⚠️ 同上：`river_discharge`（m³/s）**不在** `WeatherFieldKey`
                         // 域内（属于 `RiverDischarge` 模型）→ 诚实留空、无 EV-1 信号源。
                         requiredFields: [],
                         needsCredential: false,
                         // 同 marine：未接线，诚实置 false。
                         participatesInAutoExclusion: false,
                         websiteURLString: "https://open-meteo.com/en/docs/flood-api",
                         // 同 marine：官方免费档功能表**逐字列出** "Flood API" → 无需备注。
                         usageNote: nil)
    ]

    /// 按 id 取描述符（未登记 → nil；调用方按「未知源一律不参与自动摘除」处理）。
    static func descriptor(for id: SourceID) -> SourceDescriptor? {
        all.first { $0.id == id }
    }
}

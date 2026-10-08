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
    /// 该源是否**已接入「今日用量」计数**（设置页「多源管理」逐源显示的那个数字）。
    ///
    /// ⚠️ **为什么必须是显式声明而不是「看有没有调用点」**：本项目反复出现的病灶是
    /// 「声明进目录了、设置页也列出它了，但**永远没有自增路径**」—— 于是设置页
    /// 常年显示「今日用量 0」，读起来像「这个源今天一次都没成功」，实际是
    /// **这个源压根没接计数**。两者对用户的含义完全相反，混淆即谎报。
    /// 故把「是否接入」**声明**下来，让设置页据此显示「—」而不是「0」，
    /// 并由 `ZhishengWeatherTests/SourceUsageCountingGuardTests` 反查
    /// **声明与实际调用点是否一致**（防将来又出现新的哑火源）。
    ///
    /// - `true`：本源存在真实自增路径（经 `SourceHealthTracker.recordSuccess`）。
    /// - `false`：**尚未接入** → 设置页显示「—」，**绝不**显示「0 次」。
    let countsUsage: Bool
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
                         // 主源：`WeatherViewModel.fetchAndApply` / `refresh`
                         // 在 `service.fetch` 成功后调用 `recordSuccess`。
                         countsUsage: true,
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
                         // `WeatherViewModel.loadAir` 在 `airService.fetch` 成功后计数。
                         countsUsage: true,
                         websiteURLString: "https://open-meteo.com/en/docs/air-quality-api",
                         usageNote: nil),

        SourceDescriptor(id: .sunriseSunset,
                         displayName: "Sunrise-Sunset.org",
                         role: .auxiliary,
                         capabilities: [.solarEvents],
                         requiredFields: [.sunrise, .sunset, .daylightDuration],
                         needsCredential: false,
                         participatesInAutoExclusion: true,
                         // 由 `SourceAttributionCoordinator.refresh` 统一计数
                         // （辅助源在降级链里被拉取成功后 `recordSuccess`）。
                         countsUsage: true,
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
                         // 同 sunriseSunset：由 `SourceAttributionCoordinator` 计数。
                         countsUsage: true,
                         websiteURLString: "https://api.met.no/weatherapi/locationforecast/2.0/documentation",
                         usageNote: nil),

        // 第四源：海浪（`marine-api.open-meteo.com`，免 Key、独立子域名）。
        SourceDescriptor(id: .marineForecast,
                         displayName: "Open-Meteo 海浪",
                         role: .auxiliary,
                         capabilities: [.marineWaveConditions, .marineTide],
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
                         // `WeatherViewModel.loadMarine` 在 `marineService.fetch`
                         // 成功后计数。
                         countsUsage: true,
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
                         // ⚠️ **已接线**（2026-10-08）：`FloodCardModel` +
                         // `FloodCard` 已挂进 ContentView，走
                         // `viewModel.resolvedCoordinateForRadar` 同一坐标真源。
                         // 但 `riverDischarge` 仍**不在 `WeatherFieldKey` 域内**
                         // → `requiredFields` 诚实留空、无 EV-1 信号源，
                         // 故**仍不参与**按字段的自动摘除（摘除判据是
                         // "该源声明的字段无人需要"，而本源的字段不在该域内，
                         // 参与会出现"摘了它界面也没变化"的假开关）。
                         participatesInAutoExclusion: false,
                         // `FloodCardModel.load` 在 `service.fetch` 成功后计数。
                         countsUsage: true,
                         websiteURLString: "https://open-meteo.com/en/docs/flood-api",
                         // 同 marine：官方免费档功能表**逐字列出** "Flood API" → 无需备注。
                         usageNote: nil),

        // 第六源：官方气象预警（中国气象局 NMC `www.nmc.cn/rest/findAlarm`，免 Key）。
        //
        // ⚠️ 这是本仓**第一个官方预警源** —— 前五家（Open-Meteo / sunrise-sunset /
        // MET Norway / marine / flood）都是**数值要素**，只有本源是**预警信号本身**。
        SourceDescriptor(id: .nmcAlarm,
                         displayName: "中国气象局预警",
                         role: .auxiliary,
                         capabilities: [.officialWarning],
                         // ⚠️ **诚实留空**：预警要素（颜色 / 类型 / 防御指南）**不在**
                         // `WeatherFieldKey` 域内（它们属于 `OfficialWarningItem` 模型），
                         // 塞几个天气字段进来充数只会让 EV-1 判"永远缺字段"。
                         // → 后果：与 air/marine/flood 同处境，**无 EV-1 信号源**。
                         requiredFields: [],
                         // 实测 2026-10-06：免 Key、无需 Referer、无需账号 → false。
                         needsCredential: false,
                         // 同marine / air：接线尚未完成，**无调用点上报**
                         // `recordMissingFields` / `recordHTTPStatus` → 诚实置false，
                         // 不在设置页给一个"点了没反应"的开关。
                         participatesInAutoExclusion: false,
                         // `WeatherViewModel.loadOfficialWarnings` 在
                         // `alarmService.fetchAllWarnings` 成功后计数。
                         countsUsage: true,
                         // 实测 2026-10-06 经代理：`http://www.nmc.cn/` → **HTTP 200**
                         //（https 亦 200）。CC BY 4.0 署名义务要求可追溯的 credit，
                         // 故这里填官网首页。
                         websiteURLString: "http://www.nmc.cn/",
                         // ⚠️⚠️ **许可状态必须如实写，不得美化**（这是硬要求）。
                         // 我们调用的是**公开网页接口**，**未获中国气象局任何形式的
                         // API 授权 / 许可协议签署** —— 无账号、无 Key、无协议。
                         // 故如实告知「未获官方授权 + 仅供个人自用」，
                         // **不得**写「官方授权」或任何暗示已获授权的字样。
                         usageNote: "数据来自中国气象局官网公开预警接口，未经官方 API 授权，仅供个人自用。预警信息请以官方发布为准。"),

        // 第七源：台风路径（中央气象台台风网 `typhoon.nmc.cn`，免 Key、零鉴权）。
        //
        // ⚠️ 与第六源 `nmcAlarm` **同机构、不同服务、不同数据形态**：
        //   第六源 `www.nmc.cn/rest/findAlarm` → 预警信号（文本 + 颜色）；
        //   本源 `typhoon.nmc.cn/.../jsons/view_<id>` → 台风路径点序列 + 官方预报。
        // 两者失败域独立，故是两个独立 SourceID（见 `SourceID.nmcTyphoon` 注释）。
        SourceDescriptor(id: .nmcTyphoon,
                         displayName: "中央气象台台风网",
                         role: .auxiliary,
                         capabilities: [.typhoonTrack],
                         // ⚠️ **诚实留空**：台风路径要素（经纬度 / 强度 / 气压 /
                         // 风速 / 风圈半径 / 预报时效）**不在 `WeatherFieldKey` 域内**
                         // （它们属于 `TyphoonTrack` 模型，且含坐标维度）。
                         // 塞几个天气字段进来充数只会让 EV-1 判"永远缺字段"
                         // → 后果：与 air / marine / flood / warning 同处境，
                         // **无 EV-1 信号源**。
                         requiredFields: [],
                         // 实测 2026-10-07：`https://typhoon.nmc.cn/…/list_default`
                         // → **HTTP 200/ 2797B**，无Key、无需 Referer、无需特定 UA
                         // （三种 UA 实测字节数一致）→ false。
                         needsCredential: false,
                         // 同 marine / air：接线走独立链路（不经`FieldSupplying`），
                         // 无调用点上报 `recordMissingFields` / `recordHTTPStatus`
                         // → 诚实置false，不在设置页给一个「点了没反应」的开关。
                         participatesInAutoExclusion: false,
                         // `TyphoonCardModel.load` 在 `service.fetchSummaries`
                         // 成功后计数（空数组 = 真的没有活跃台风，**仍是成功**）。
                         countsUsage: true,
                         // 实测 2026-10-07：`https://typhoon.nmc.cn/` → **HTTP 200**。
                         // CC BY 4.0 署名义务要求可追溯的 credit，故填官网首页。
                         websiteURLString: "https://typhoon.nmc.cn/",
                         // ⚠️⚠️ **许可状态必须如实写，不得美化**（与第六源同款要求）。
                         // 我们调用的是**公开网页前端接口**，**未获中国气象局任何形式
                         // 的 API 授权 / 许可协议签署** —— 无账号、无 Key、无协议。
                         // 且本源是**非承诺的开放 API**（网页前端随时可能改结构），
                         // 两条都必须让用户知道。
                         usageNote: "数据来自中国气象局台风网公开接口，未经官方 API 授权，"
                             + "仅供个人自用。该接口为网站前端数据、非承诺的开放 API，"
                             + "结构可能变动；台风路径与预报请以中央气象台官方发布为准。"),

        // 第八源：**兜底源** 7timer!（`www.7timer.info/bin/api.pl`，免 Key、零鉴权）。
        //
        // ⚠️ 与前七源**角色不同**：它被放在辅助链**末位**，仅当其余源都没给出某字段时
        //   才由 `FieldFallbackResolver.merge` 选中（主源非 nil 绝不覆盖；辅助源按链序
        //   取第一个有值者）。它是**单一故障域兜底** —— 与 Open-Meteo 不同域名 /
        //   不同服务端软件（实测 `Server: Apache/2.4.68 (Debian)` vs Open-Meteo 无
        //   `Server` 头）→ 主源整体挂掉时它仍可能可用。
        //
        // ⚠️ `requiredFields` 必须**恰好**等于 `SevenTimerMapper` 会写入的字段集合
        //   （温度 / 气压 / 风向）：多写 → EV-1 误摘；少写 → 该字段永不参与 EV-1。
        //   ⚠️ **不含**湿度 / 云量 / 风速 —— 上游给的是**档位码**而非物理量
        //   （`rh2m` 实测 −2…11、`cloudcover` 1…9、`wind10m.speed` 1…4），
        //   详见 `SevenTimerMapper` 文件头的逐字段诚实性对照表。
        //   两侧对齐由 `SevenTimerTests.testRequiredFieldsEqualMappedKeys` 钉住。
        SourceDescriptor(id: .sevenTimer,
                         displayName: "7timer!（兜底）",
                         role: .auxiliary,
                         capabilities: [.coarseFallbackFields],
                         requiredFields: [.temperature, .pressure, .windDirection],
                         // 实测 2026-10-08：免 Key、无额度声明、无需特定 UA → false。
                         needsCredential: false,
                         // 参与自动摘除：它是**在链的真实取数源**（与 MET Norway 同款纪律），
                         // 连续 3 次缺字段 / 非 2xx 时由 EV-1 / EV-3 摘除，设置页给停用入口。
                         participatesInAutoExclusion: true,
                         // 同 sunriseSunset：由 `SourceAttributionCoordinator` 计数。
                         countsUsage: true,
                         // 实测 2026-10-08：`https://www.7timer.info/` → HTTP 200。
                         // CC BY 4.0 署名义务要求可追溯的 credit，故填官网首页。
                         websiteURLString: "https://www.7timer.info/",
                         // 无需额外说明：本源为公开免费 API，官方文档（本仓 .tmp7t 已核）
                         // 明确「无需 API 密钥即可直接使用」，不存在「现状可用但矩阵不含」，
                         // 故**不**套用那句谨慎备注（那是虚假谨慎）。许可条款官方未声明 →
                         // 不臆测、不美化，保持 nil。
                         usageNote: nil),

        // 第九源：和风天气（QWeather，**需 Key**：JWT + 控制台专属 API Host）。
        //
        // ⚠️ **本轮未实测（无 Key）**：字段清单来自和风官方文档页
        //   `https://dev.qweather.com/docs/api/weather/weather-daily-forecast`
        //   （主理人 2026-10-08 抓取）。**官方文档示例 ≠ 该账号真实响应**，
        //   接入后必须真机核验（见 `Core/Models/QWeatherDaily.swift` 文件头）。
        SourceDescriptor(id: .qWeather,
                         displayName: "和风天气",
                         role: .auxiliary,
                         capabilities: [.qWeatherDailyForecast, .qWeatherHourlyForecast],
                         // ⚠️ **诚实留空**：和风逐日要素（自带单位的量纲对象 /
                         // 昼夜分块 / 天文时刻）**不在 `WeatherFieldKey` 域内**
                         // （它们属于 `QWeatherDailyForecast` 模型）——
                         // 同 flood / marine / warning 的处境，塞假字段充数
                         // 只会让 EV-1 判"永远缺字段"→ **误摘**。
                         // → 后果：**无 EV-1 信号源**。
                         requiredFields: [],
                         // 🔴 **true**：本源**无免费免 Key 路径**，必须配置
                         // API Host / Project ID / Credential ID / Ed25519 私钥
                         // 才能取数。无凭据 → 卡片显示「未配置 API 凭据」，
                         // **绝不静默换源、绝不伪造数据**（本仓铁律：
                         // 缺失就渲染如实空态）。
                         needsCredential: true,
                         // ⚠️ **false**，理由与 flood 同款且更明确：
                         //  ① `riverDischarge` 类比 —— 本源字段不在
                         //  `WeatherFieldKey` 域内 → 无 EV-1 按字段摘除信号；
                         //  ② 本轮**无任何调用点**上报 `recordMissingFields` /
                         //  `recordHTTPStatus` → 置 true 会给设置页一个
                         //  「点了没反应」的开关（违反诚实纪律）。
                         participatesInAutoExclusion: false,
                         // `QWeatherCardModel.loadDaily` / `loadHourly` 各自在
                         // fetch 成功后计数（两条链路是**两次独立请求**）。
                         countsUsage: true,
                         // ⚠️ 填**开发者门户**而非某个具体 API 路径：
                         // 本源的关键前提（专属 API Host 因账号而异）只在该站说明，
                         // 写死某条文档路径会在文档改版后 404。
                         // CC BY 4.0 署名义务要求可追溯的 credit，故填官网。
                         websiteURLString: "https://dev.qweather.com/",
                         // ⚠️⚠️ **必须如实写明"未接入 / 未实测"，不得美化**。
                         // 三件事都要让用户知道：
                         // ① 需要用户自备账号与凭据（不是开箱即用）；
                         // ② 本轮**未实测**（无 Key）→ 字段可能与文档不一致；
                         // ③ 和风官方要求 `metadata.attributions`
                         //    **必须与数据共同显示**（许可条件，非可选），
                         //    本应用已在卡片上逐条渲染。
                         usageNote: "数据来自和风天气（QWeather），需自行申请账号并配置"
                             + "API Host / Project ID / Credential ID / Ed25519 私钥；"
                             + "和风要求署名与数据同时展示，本应用会在卡片上显示其指定的署名内容。"),

        // 第十源：USGS 地震（`earthquake.usgs.gov`，FDSN Event Web Service）。
        //
        // ⚠️ 这是本仓**第一个非气象学科域**的数据源 —— 前面九个全是天气/海洋/
        // 预警/台风，本源是**地震学**（另一个学科域）。
        SourceDescriptor(id: .usgsEarthquake,
                         displayName: "USGS 地震",
                         role: .auxiliary,
                         capabilities: [.earthquakeEvents],
                         // ⚠️ **诚实留空**：地震要素（震级 / 震中 / 深度 / 时刻 /
                         // PAGER 警报）**不在 `WeatherFieldKey` 域内**
                         // （它们属于 `EarthquakeEvent` 模型）——
                         // 同 marine / flood / warning / typhoon 的处境，
                         // 塞假天气字段充数只会让 EV-1 判"永远缺字段"→ **误摘**。
                         // → 后果：**无 EV-1 信号源**。
                         requiredFields: [],
                         // 实测 2026-10-08：**完全免 Key、免注册、零鉴权**，
                         // 请求不带任何 Authorization 头即返回 200 → false。
                         needsCredential: false,
                         // 同marine / flood / warning / typhoon / qWeather：
                         // 地震要素不在 `WeatherFieldKey` 域内 → 无按字段摘除信号；
                         // 置 true 只会给设置页一个「点了没反应」的开关。
                         participatesInAutoExclusion: false,
                         // `EarthquakeCardModel.load` 在
                         // `service.fetchNearbyEvents` 成功后计数。
                         // ⚠️ `.none`（查过了、附近确实没有地震）**也算成功**——
                        // 请求成功返回、只是结果为空，把它算成失败会让用量虚低。
                         countsUsage: true,
                         websiteURLString: "https://earthquake.usgs.gov/",
                         // ⚠️ 如实写明**查询口径**（这是最容易被误读的地方）：
                         // 本源说的「附近无地震」**不等于**「附近没有震动」——
                         // 它实际是「**300 km 内没有 M2.5 以上的地震**」。
                         // 把这句话写清楚，才不会让用户以为「没报= 没发生」。
                         //
                         // 署名：USGS 数据属**美国联邦政府作品**，在美国境内
                         // 属公有领域（public domain），**一般不强制署名**；
                         // 但仍如实标注来源，不夸大也不虚构许可。
                         usageNote: "数据来自美国地质调查局（USGS）FDSN 地震目录，"
                             + "免注册、免密钥。查询口径为所选位置 300 公里内、"
                             + "近30 天内 M2.5 及以上地震；"
                             + "「附近无地震」指该口径下无记录，不代表该范围无任何震动。"
                             + "震级量表（mb/md/ml/mww 等）不同之间不可直接横向比较。")
    ]

    /// 按 id 取描述符（未登记 → nil；调用方按「未知源一律不参与自动摘除」处理）。
    static func descriptor(for id: SourceID) -> SourceDescriptor? {
        all.first { $0.id == id }
    }
}

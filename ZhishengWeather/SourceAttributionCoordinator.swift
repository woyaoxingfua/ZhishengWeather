//
//  SourceAttributionCoordinator.swift
//  ZhishengWeather（主 App target）
//
//  接线点 (b)（ARCH §12.3.2，裁定采纳；(a) 已否）。
//
//  职责：拉辅助源 → 逐字段合并 → 写归属。由 ContentView 的 `.task(id: 城市 id)`
//  驱动；**不做自己的定时器 / 独立刷新**（不引入第二个刷新生命周期，硬约束⑦）。
//
//  **硬约束⑥**：本协调器**不是**主源快照的第二份真相源——只持有
//  `solarOverlay`（辅助源补的稀疏字段补丁）+ `attribution`；**绝不**拷贝/缓存整份
//  `WeatherSnapshot`，**绝不**重发主源请求。主源快照唯一真相源仍是
//  `WeatherViewModel.snapshot`；overlay 仅在渲染 DaylightCard 时逐字段叠加。
//
//  ── T10 去硬编码（ARCH-T10 §3.3 / §3.5 / §E8）──────────────────────────────
//  原先这里写死了两处，都是「漏改即静默」的病灶：
//  · `isFieldNil` 只 `switch` 4 个 solar 字段、`default: return false`
//    → 任何**新字段**都判「不缺失」→ EV-1（连续 3 次缺字段 → 摘除）**恒不触发**，
//      坏掉的源永远不被摘除、设置页还一直显示它「备用」（已真实发生过）。
//    现在判缺下沉为 `FieldPatch.isMissing`（判据是 `source.requiredFields`
//    与补丁实际字段的差集，**与字段名无关**）→ 新字段**自动参与**，无 default 可漏写。
//  · 早退分支写死 `.sunriseSunset` → 接入第二个辅助源时它的停用/摘除判定完全失效。
//    现在改为**逐源**判定（手动停用 / 会话摘除 / 冷却中 → 跳过**该源**）。
//
//  ⚠️ **明确不做**（ARCH-T10 §7，已评估 · 需单独立项）：可切换的「第二主源」。
//  主源被硬编码在本类、`WeatherViewModel`、`ZhishengWeatherApp` 与 Widget 侧
//  `WeatherProvider` 等处，且与「绝不静默换源」纪律正面冲突。
//  → 本轮**不动主源链路**；下面的 `.openMeteoForecast` 是「当前主源是谁」的既有常量，
//    不是待泛化项。
//
//  诚实红线：主源有值绝不覆盖（merge 纯函数保证）；时区未知不补值（§3.5）。
//

import SwiftUI

/// 主源已有的 solar 输入（由 ContentView 从当前主快照取出后注入）。
struct PrimarySolarInput: Sendable {
    var sunrise: Date?
    var sunset: Date?
}

/// 主备源分歧量（诊断用：同字段皆非 nil 且差异超容差）。
struct SolarDivergence: Equatable, Sendable {
    var sunriseDiffSeconds: TimeInterval?
    var sunsetDiffSeconds: TimeInterval?
}

/// 来源标注协调器（App target，@MainActor / ObservableObject）。
@MainActor
final class SourceAttributionCoordinator: ObservableObject {

    /// 合并后的 solar 字段覆盖层（只装辅助源真正补上的字段；缺失字段完全退回主快照值）。
    ///
    /// ⚠️ T10 后本属性**按能力泛化**：`handledCapabilities` 里的任何能力所产出的字段
    /// 都会进这里（名字里的 "solar" 是历史遗留）。当前**唯一消费者**是 `DaylightCard`，
    /// 它只读 solar 字段；MET Norway 的数值字段进来后**没有任何视图读取**。
    /// 若将来要上屏 MET 的数值或做对比 UI：请把这个覆盖层按能力拆开（或改名），
    /// 并同步收紧下面「只在辅助源真的贡献了字段时才发布」那条判据 ——
    /// 否则纯数值源一旦成功，会把**调用当刻**的主源 solar 值一并发布出去，
    /// 顶掉 `DaylightCard` 本可退回的**更新**快照值（跨日场景下这就是旧值锁定）。
    @Published private(set) var solarOverlay: FieldPatch?
    /// 逐字段来源图（L2 标注依据）。
    @Published private(set) var solarProvenance: FieldProvenanceMap?
    /// L1 页脚归因（也落地到 SourceAttributionStore 供冷启动/缓存态诚实）。
    @Published private(set) var attribution: SourceAttribution
    /// 主备源分歧量（诊断用，不用于上屏）。
    @Published private(set) var divergence: SolarDivergence?

    private let sources: [any FieldSupplying]
    private let health: SourceHealthTracker
    private let preferences: SourcePreferences
    private let attributionStore: SourceAttributionStore

    /// 默认接线：辅助源取自组装点，健康/偏好/归属取 App 本地默认实例。
    init(sources: [any FieldSupplying] = SourceComposition.makeAuxiliarySources(),
         health: SourceHealthTracker = .shared,
         preferences: SourcePreferences = .shared,
         attributionStore: SourceAttributionStore = .shared) {
        self.sources = sources
        self.health = health
        self.preferences = preferences
        self.attributionStore = attributionStore
        // 初始归因读本地最近一次成功记录（缓存态也诚实）。
        self.attribution = attributionStore.load()
            ?? SourceAttribution(primarySourceID: .openMeteoForecast, hasFieldFallback: false, at: Date())
    }

    /// 主源在 `.solarEvents` 能力上**本应提供**的字段集。
    ///
    /// 只含 `sunrise` / `sunset`：主源的 `daily` 请求面带这两个字段。
    /// **不含** `solarNoon` / `daylightDuration` —— 主源从不提供它们，
    /// 由辅助源作为**指定提供方**给出，因此不构成"降级"。
    /// 判定 `hasFieldFallback` 必须以此集合求交，否则页脚会恒定谎称主源不可用。
    ///
    /// ⚠️ 这是本类**唯一**残留的「字段清单」手工点，而且它声明的是**主源的事实**
    /// （"主源确实提供哪些 solar 字段"），不是按字段列举的分支逻辑：
    /// 若将来主源真的开始提供某个新的 solar 字段，必须在此登记，否则该字段被备源
    /// 顶上时页脚会**漏标**降级。**不要**把它改成对某个源 id 的写死判断。
    static let primarySolarDeclaredFields: Set<WeatherFieldKey> = [.sunrise, .sunset]

    /// 本协调器负责的能力面（取数 + 逐字段合并 + EV-1/EV-3 健康判定）。
    ///
    /// 源是否进入本协调器、以及向它请求哪些能力，都由此集合与
    /// `source.capabilities` 求交**派生** —— 不写死任何一个源 id。
    ///
    /// ⚠️ **接入一个新辅助源时，必须把它的能力登记在这里**：漏登记 → 该源
    /// **根本不会被拉取**（`for source in sources where !source.capabilities
    /// .isDisjoint(with: Self.handledCapabilities)` 直接把它筛掉）→ 它的
    /// `lastSuccessAt` / 今日用量永远为空、EV-1 永不触发，设置页却把它显示成
    /// 一行"备用"的正常源 —— 这就是本仓库反复出现的**静默哑火**位置。
    ///
    /// 当前两项：
    /// - `.solarEvents`：日出/日落覆盖层（`DaylightCard` 逐字段叠加，唯一有消费者的能力面）；
    /// - `.basicNumericFields`：MET Norway 的温/压/湿/云/风。本轮**只**参与
    ///   「逐字段降级链 + 多源管理状态行」，**没有**上屏消费者
    ///   （对比/诊断 UI 属后续批次）—— 故这些值进入 overlay 后无任何视图读取。
    static let handledCapabilities: Set<SourceCapability> = [.solarEvents, .basicNumericFields]

    /// 按城市拉取辅助源并逐字段合并（输入 = 坐标 + 主源 solar + 注入 now）。
    ///
    /// - Parameters:
    ///   - city: 当前城市（`City.timeZoneIdentifier == nil` → 不补值，不猜测）。
    ///   - primarySolar: 主快照已有的 sunrise/sunset（用于逐字段对比）。
    ///   - now: 采集时刻（调用方注入）。
    func refresh(for city: City, primarySolar: PrimarySolarInput, now: Date) async {
        // 诚实红线（§3.5）：城市时区未知 → 不补值、不退回设备时区、不猜城市。
        //
        // ⚠️ P2 复盘修复：原实现只判 `!= nil`，**没有校验标识符是否合法**。
        // 若 `timeZoneIdentifier` 是一个**非法 IANA 串**（非 nil 但 `TimeZone(identifier:)`
        // 返回 nil），下游渲染会退回设备时区——那就是"用设备时区渲染异地城市的日出日落"，
        // 正是 §3.5 要防的静默错误。此处把"合法"与"存在"一并作为门槛。
        guard let zoneID = city.timeZoneIdentifier, TimeZone(identifier: zoneID) != nil else {
            applyEmptyOverlay(now: now)
            return
        }

        // 主源已有的 solar 字段（来自主快照；solarNoon/daylightDuration 主源无）。
        var primaryPatch = FieldPatch(sourceID: .openMeteoForecast, capturedAt: now)
        if let sunrise = primarySolar.sunrise { primaryPatch.set(.sunrise, .instant(sunrise)) }
        if let sunset = primarySolar.sunset { primaryPatch.set(.sunset, .instant(sunset)) }

        var auxiliary: [FieldPatch] = []
        /// 逐源累计的必填缺失（EV-1 的输入）。
        var missingBySource: [SourceID: Set<WeatherFieldKey>] = [:]

        // 失败隔离：自带调用、catch 只置本槽位、不 rethrow、不连累主链路。
        // 纳入范围由「源声明了本协调器负责的能力」**派生**（不写死任何源 id）。
        for source in sources where !source.capabilities.isDisjoint(with: Self.handledCapabilities) {
            // 手动停用 / 会话摘除 / 冷却中 → 跳过**该源**（其余源不受影响）。
            // 逐源判定：新增辅助源自动获得同一判定，不需要再在别处补一行。
            if await health.exclusionReason(for: source.id, now: now) != nil { continue }

            do {
                let patch = try await source.fetchFields(latitude: city.latitude,
                                                         longitude: city.longitude,
                                                         capabilities: source.capabilities
                                                            .intersection(Self.handledCapabilities),
                                                         now: now)
                auxiliary.append(patch)
                // EV-1 判缺：`requiredFields` 与补丁实际字段的差集 —— **与字段名无关**，
                // 所以任何新字段只要被某源列进 requiredFields 就自动参与，无需改这里。
                let missing = Set(source.requiredFields.filter { patch.isMissing($0) })
                if missing.isEmpty {
                    // 字段齐全才算"真成功" → 清零该源的 EV-1 连续缺失计数。
                    await health.recordSuccess(source.id, at: now)
                } else {
                    // ⚠️ **成功但缺字段时绝不能记成功**（P2 复盘修复的哑火线）：
                    // `recordSuccess` 会把连续缺失计数清零，而每次轮询都是
                    // "先成功、后缺失"——计数于是永远停在 1，
                    // **EV-1（连续 3 次缺失 → 摘除）在集成路径里永不触发**。
                    // 单测之所以绿，是因为它直接连调三次 `recordMissingFields`、
                    // 中间没有 `recordSuccess` 插入 → 典型的"单测绿、集成废"。
                    // 缺字段只计入本源的待累计集合，**不碰成功计数**。
                    missingBySource[source.id, default: []].formUnion(missing)
                }
            } catch let error as WeatherError {
                // EV-3：401/403/429 按状态码裁定（会话摘除 / 冷却）。
                if case .badStatus(let code) = error {
                    _ = await health.recordHTTPStatus(source.id, status: code, at: now)
                }
                // 其余错误：仅本槽位失败，不 rethrow。
            } catch {
                // 非 WeatherError：同样仅本槽位失败。
            }
        }

        // EV-1：逐源累计必填缺失。
        // 按 `source.id` 而非写死某一源——否则将来接入第二个辅助源时，
        // 两源的缺失会累计到同一个计数器上（假摘除）。
        // 主源不参与自动摘除，由 `SourceHealthTracker` 内部保证。
        for (sourceID, missing) in missingBySource {
            _ = await health.recordMissingFields(sourceID, missing: missing, at: now)
        }

        // 逐字段合并（纯函数：主源非 nil 绝不被覆盖、绝不平均）。
        let (merged, provenance) = FieldFallbackResolver.merge(primary: primaryPatch, auxiliary: auxiliary)

        // ⚠️ 覆盖层只在**辅助源真的贡献了字段**时才发布（T10 复盘修复的陈旧回归）。
        //
        // 为什么不能无条件发布 `merged`：`merged` 里含**主源补丁**的 sunrise/sunset，
        // 而主源补丁是**协调器被调用那一刻**从快照取的值。而协调器只由 `ContentView` 的
        // `.task(id: 城市 id)` 驱动 —— **同一城市后续的快照刷新不会重跑它**
        // （例如跨日换了日出日落）。于是 overlay 会锁住**旧的主源值**，
        // 而 `DaylightCard` 的取值阶梯是 `overlay?.X ?? snapshot.X` → **显示旧值**。
        // 旧实现（源全被跳过时 `overlay = nil`）没有这个问题，因为 nil 会退回**当前快照**。
        //
        // 故：辅助源一个字段都没贡献时**不发布 overlay**（置 nil），
        // 让 `DaylightCard` 退回快照取到**当次最新**的值。阶梯等价，上屏语义不变。
        // `auxiliary` 非空但补丁为空（例如源返回 status != OK 的空补丁）同样走此分支。
        let auxiliaryContributed = auxiliary.contains { !$0.fields.isEmpty }
        if auxiliaryContributed {
            self.solarOverlay = merged
            self.solarProvenance = provenance
        } else {
            self.solarOverlay = nil
            self.solarProvenance = nil
        }

        // 分歧量（主源报值 vs 辅助源报值，差异 > 60s 视为分歧，诊断用）。
        self.divergence = Self.computeDivergence(primary: primarySolar, auxiliary: auxiliary)

        // L1 归因：**字段级降级** = 某个「主源本应提供」的字段却取自备源。
        //
        // ⚠️ P2 复盘修复（屏幕上正在说谎的缺陷）：原实现写成
        //     `hasFallback = !provenance.degradedFields.isEmpty`
        // 但主源补丁只装 `sunrise` / `sunset`，而辅助源**永远**会返回
        // `solarNoon` / `daylightDuration` → `degradedFields` **恒非空** →
        // 页脚**恒定**显示「主源不可用，当前数据来自 sunrise-sunset.org（备源）」。
        // 也就是说：即使主源一切正常，App 也会一直宣称它挂了。这是诚实红线的违反。
        //
        // 根因是**把"降级"与"该字段由指定提供方给出"混为一谈**：
        // `solarNoon` / `daylightDuration` **主源从不提供**，它们本来就该由辅助源给，
        // 那不属于降级。只有 `sunrise` / `sunset`（主源声明提供）缺了才算降级。
        let degraded = Set(provenance.degradedFields)
        let hasFallback = !degraded.isDisjoint(with: Self.primarySolarDeclaredFields)
        let attr = SourceAttribution(primarySourceID: .openMeteoForecast,
                                     hasFieldFallback: hasFallback,
                                     at: now)
        self.attribution = attr
        attributionStore.record(primaryID: .openMeteoForecast, hasFieldFallback: hasFallback, at: now)
    }

    // MARK: - Private

    /// 清空覆盖层并仅记录主源归因（**时区未知**路径：不补值、不猜测城市）。
    private func applyEmptyOverlay(now: Date) {
        self.solarOverlay = nil
        self.solarProvenance = nil
        self.divergence = nil
        let attr = SourceAttribution(primarySourceID: .openMeteoForecast, hasFieldFallback: false, at: now)
        self.attribution = attr
        attributionStore.record(primaryID: .openMeteoForecast, hasFieldFallback: false, at: now)
    }

    /// 主备分歧量：**主源报出的值** 与 **辅助源自己报出的值** 之差（诊断用，判断源质量）。
    ///
    /// ⚠️ P2 复盘修复（死代码）：原实现拿 `merged` 与主源比 —— 但硬约束① 保证
    /// "主源非 nil 时绝不被覆盖"，于是 `merged.instant(.sunrise) == primary.sunrise` **恒成立**、
    /// 差值**恒为 0**、`SolarDivergence` **永远是 nil**，整条分歧能力形同虚设
    /// （单测还断言它非 nil，即断言了一条**不可能成立**的性质）。
    /// 分歧的正确比较对象是**辅助源自己的报值**，不是合并后的结果。
    private static func computeDivergence(primary: PrimarySolarInput,
                                          auxiliary: [FieldPatch]) -> SolarDivergence? {
        // 取第一个真正报出该字段的辅助源值（同字段多源时以链序优先者为准）。
        let auxSunrise = auxiliary.compactMap { $0.instant(.sunrise) }.first
        let auxSunset = auxiliary.compactMap { $0.instant(.sunset) }.first

        var result = SolarDivergence()
        if let p = primary.sunrise, let a = auxSunrise,
           abs(p.timeIntervalSince(a)) > 60 {
            result.sunriseDiffSeconds = p.timeIntervalSince(a)
        }
        if let p = primary.sunset, let a = auxSunset,
           abs(p.timeIntervalSince(a)) > 60 {
            result.sunsetDiffSeconds = p.timeIntervalSince(a)
        }
        guard result.sunriseDiffSeconds != nil || result.sunsetDiffSeconds != nil else { return nil }
        return result
    }
}

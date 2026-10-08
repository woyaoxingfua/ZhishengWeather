//
//  QWeatherCardModel.swift
//  ZhishengWeather
//
//  第九源「和风天气」卡的**主屏状态容器**（`@MainActor @Observable`）。
//  覆盖**逐日 + 逐时**两个端点。
//
//  ✅ 实测基准：2026-10-08 逐日 / 2026-10-09 逐时（主理人用真实凭据打通，HTTP 200）
//  ══════════════════════════════════════════════════════════════════════════
//
//  ── 四态（与本仓其它卡同款，但 `.noData` 的判据是本源的）────────────────
//  · `.idle`未加载
//  · `.available`上游下发了 ≥1 天/ ≥1 小时
//  · `.noData`     响应结构完整但 `days` / `hours` 为空 → **合法响应，不是故障**
//  · `.unavailable(String)` 取不到（网络 / 鉴权 / 解码）
//
//  🔴 `.noData` 与 `.unavailable` **必须分开** —— 把「上游没给数据」
// 显示成「取不到」，用户会去查网络，而问题在上游（纪律同台风/洪水/地震卡）。
//
//  ── 🔴 为什么**逐日与逐时是两个独立四态**，而不是合成一个 ────────────────
//  两个端点是**两次独立请求、两个独立失败域**（实测：同一凭据下逐日 200
// 不代表逐时 200 ——套餐权限、上游超时都可能只命中其中一个）。
// 合成单一状态会导致：「逐日成功 + 逐时 401」被显示成「和风天气取不到」，
// 用户会把**整个源**关掉，而其实逐日是好的。
// → 故 `state`（逐日）与 `hourlyState`（逐时）各自独立派生、各自渲染。
//
//  ── 🔴 鉴权失败必须**可区分**（401 vs 403）─────────────────────────────
//  `QWeatherService` 只保留原始状态码（`WeatherError.badStatus(Int)`），
// 「人话说明」由本类的 `describe(_:)` 依
// `QWeatherService.authenticationHint(statusCode:)` **二次渲染** ——
//  错误消息这一层保持**单一真源**（不在两个地方各拼一次）。
//
//  ── ⚠️ 凭据未配置 → **如实空态**，绝不伪造数据 ─────────────────────────
//  本仓铁律：缺失就渲染如实空态。`QWeatherService` 在无凭据时抛
//  `WeatherError.dataMissing`，本类显示「未配置 API 凭据」，
//  **绝不**静默换源、**绝不**拿别的源的数据冒充和风。
//
//  ── 🔴 `attributions` **无条件透传**（官方许可条件）──────────────────────
//  官方文档明文：「必须与当前数据共同显示」。故本类**即使在 `.unavailable`
//  状态也保留**已知署名（若曾取到过），供卡片页脚渲染。
//
//  本仓纪律：View 整体 `@MainActor`（P-06）；禁 `try!` / `fatalError`。
//

import Foundation

/// 和风天气卡状态容器（逐日 + 逐时）。
@MainActor
@Observable
final class QWeatherCardModel {

    // MARK: - 状态

    /// 四态（**纯枚举 + 无 raw type** —— 本仓陷阱：enum 不能同时用 raw type
    /// 与关联值 case，见 P-10）。
    enum State: Equatable {
        /// 未加载。
        case idle
        /// 上游响应完整但序列为空（**合法响应，不是故障**）。
        case noData
        /// 已取到至少一条。
        case available
        /// 取不到（附用户可读原因）。
        case unavailable(String)
    }

    /// 逐日状态。
    private(set) var state: State = .idle

    /// 逐时状态（**与逐日独立的失败域**，见文件头）。
    private(set) var hourlyState: State = .idle

    /// 是否正在取数。
    private(set) var isLoading: Bool = false

    /// 本次加载是否超时（用于卡内如实提示"结果可能不是最新"）。
    private(set) var hasTimedOut: Bool = false

    /// 取到的逐日预报（`state` 非 `.unavailable` 时非 nil）。
    private(set) var forecast: QWeatherDailyForecast?

    /// 取到的逐时预报（`hourlyState` 非 `.unavailable` 时非 nil）。
    private(set) var hourlyForecast: QWeatherHourlyForecast?

    // MARK: - 超时

    /// 取数超时阈值（**秒**）。
    /// 🔴 **25 秒**（2026-10-08 改）：原 12 秒在主屏多 `.task` 串行排队下被误爆。
    /// 排队问题已由「合并成单 `.task` + `async let` 并发」治本；
    /// 此值上调仅作弱网兜底。同 `EarthquakeCardModel` 注释。
    static let loadTimeout: TimeInterval = 25

    // MARK: - 依赖

    private let service: any QWeatherProviding

    /// 用量计数落点（测试注入隔离实例；理由同 `EarthquakeCardModel.health`）。
    private let health: SourceHealthTracker

    /// 初始化。
    /// - Parameter service: 取数实现（测试注入 Stub）。
    ///
    /// 🔴 `QWeatherService()` **必须显式传 `now`**（2026-10-08 门禁 SC-11 教训）：
    ///   Core层禁 `Date()`，所以 `QWeatherService.init` 的 `now` 参数**没有默认值**；
    ///   本类在 **App 层**（`ZhishengWeather/`），此处传 `Date()` 是合规的
    ///   —— SC-11 只扫 `Core/`。
    /// - Parameters:
    ///   - service: 取数实现（测试注入 Stub）。
    ///   - health: 用量计数落点（默认共享实例；测试注入隔离 ledger）。
    init(service: any QWeatherProviding = QWeatherService(now: { Date() }),
         health: SourceHealthTracker = .shared) {
        self.service = service
        self.health = health
    }

    // MARK: - 取数

    /// 拉取逐日 + 逐时预报（**两条链路并发**）。
    ///
    /// ⚠️ **为什么并发而不是两次 `await`**：主屏已有 4 条 `.task` 链路在
    /// 串行排队（见 `ContentView`），本卡再串行加 2 次请求会让最慢的那条
    /// 成为整屏的**尾延迟瓶颈**。`async let` 保证逐日与逐时**同时发起**，
    /// 谁都不阻塞谁。
    ///
    /// - Parameters:
    ///   - latitude: 选中城市纬度（WGS84，**由调用方从既有真源取**）。
    ///   - longitude: 选中城市经度（WGS84）。
    ///   - days: 请求逐日天数（官方 1–10；越界由 Endpoint 收敛为 `badURL`）。
    ///   - hours: 请求逐时小时数（官方 1–360；越界收敛为 `badURL`）。
    ///   - now: 本次加载的**起点**（**注入**，单测可固定；超时判定用它）。
    func load(latitude: Double,
              longitude: Double,
              days: Int = QWeatherEndpoint.defaultDays,
              hours: Int = QWeatherEndpoint.defaultHours,
              now: Date = Date()) async {
        isLoading = true
        hasTimedOut = false
        defer { isLoading = false }

        async let dailyLoad: Void = loadDaily(latitude: latitude,
                                              longitude: longitude,
                                              days: days)
        async let hourlyLoad: Void = loadHourly(latitude: latitude,
                                                longitude: longitude,
                                                hours: hours)
        // 🔴 两条链路**各自 catch 自己的错**（在 `loadDaily` / `loadHourly` 内部），
        //   所以这里永远不会因一条失败而丢掉另一条的结果。
        _ = await (dailyLoad, hourlyLoad)

        // 超时兜底：读**完成时刻**与注入起点的差（不能自己减自己 —— 恒为 0）。
        hasTimedOut = Date().timeIntervalSince(now) > Self.loadTimeout
    }

    // MARK: - Private（取数）

    /// 拉取逐日并落到 `state` / `forecast`（**内部吃掉所有错误**）。
    ///
    /// ⚠️ 为什么错误在这里被 catch 而不是往外抛：两条链路并发时，
    ///   若让错误外抛，`async let` 会在第一个抛出的地方中断，
    ///   **另一条已完成的结果会被丢弃** —— 那就是「逐时成功但整卡显示取不到」。
    private func loadDaily(latitude: Double, longitude: Double, days: Int) async {
        do {
            let fetched = try await service.fetchDaily(latitude: latitude,
                                                       longitude: longitude,
                                                       days: days)
            // ⚠️ 实质无数据 → `.noData`，**不抛错、不当故障**
            //（判据的权威在 Core `QWeatherDailyForecast.isEffectivelyEmpty`，
            //  此处只转发，不重算）。
            forecast = fetched
            // 和风源用量计数（逐日链路）。`.noData`（上游没给数据）**也算成功**——
            // 请求成功返回、只是内容为空，与 `.unavailable`（鉴权/网络失败）严格分开。
            await health.recordSuccess(.qWeather, at: Date())
            state = fetched.isEffectivelyEmpty ? .noData : .available
        } catch {
            // ⚠️ 故障 → `.unavailable`，**绝不**落到 `.noData`
            //（否则鉴权失败会被显示成「上游没给数据」）。
            forecast = nil
            state = .unavailable(Self.describe(error))
        }
    }

    /// 拉取逐时并落到 `hourlyState` / `hourlyForecast`（**内部吃掉所有错误**）。
    ///
    /// ⚠️ 与逐日**完全同构**，但状态写到**独立**的 `hourlyState`
    ///   （理由见文件头「两个独立失败域」）。
    private func loadHourly(latitude: Double, longitude: Double, hours: Int) async {
        do {
            let fetched = try await service.fetchHourly(latitude: latitude,
                                                        longitude: longitude,
                                                        hours: hours)
            hourlyForecast = fetched
            // 和风源用量计数（逐时链路）—— 逐日/逐时是**两次独立请求**，各计一次。
            await health.recordSuccess(.qWeather, at: Date())
            hourlyState = fetched.isEffectivelyEmpty ? .noData : .available
        } catch {
            hourlyForecast = nil
            hourlyState = .unavailable(Self.describe(error))
        }
    }

    // MARK: - 派生便捷量（视图只渲染，不判定）

    /// 逐日序列（**逐日视图唯一入口**；非 `.available` → 空数组）。
    var days: [QWeatherDay] {
        forecast?.days ?? []
    }

    /// 逐时序列（**逐时视图唯一入口**；非 `.available` → 空数组）。
    var hours: [QWeatherHour] {
        hourlyForecast?.hours ?? []
    }

    /// 🔴 上游署名（**合规硬要求**，视图页脚**无条件**渲染）。
    ///
    /// ⚠️ 逐日与逐时是**两次独立请求**，各有各的 `metadata.attributions`
    ///   （内容通常相同，但**不保证**相同 —— 官方文档未承诺两端口径一致）。
    ///   → 本属性做**并集 + 去重 + 保持逐日在前**，
    ///     这样页脚只需渲染一处，且**任一端点带来的署名都不会丢**
    ///     （丢掉一条就是违反许可条件）。
    var attributions: [String] {
        var merged: [String] = []
        // ⚠️ 不用 `count` / `first` 等作循环变量名（P-32 纪律）。
        for candidate in [forecast?.attributions ?? [], hourlyForecast?.attributions ?? []] {
            for item in candidate where !merged.contains(item) {
                merged.append(item)
            }
        }
        return merged
    }

    // MARK: - 错误文案

    /// 故障 → 用户可读文案。
    ///
    /// ⚠️ **单一真源**：先走 Core 的 `FaultDomain.classify` + `.message(for:)`
    ///（与 `FloodCardModel.describe` / `EarthquakeCardModel.describe` 同一对函数）
    ///；**401 / 403** 则改用 `QWeatherService.authenticationHint(statusCode:)`
    /// ——因为「重签可自愈」与「必须改配置」的处置完全不同，
    /// 混成一句通用文案等于把「需要改配置」误报成「网络波动」。
    ///
    /// ⚠️ `nonisolated`：与同款`describe` 一样是**纯函数**（只依赖入参）。
    nonisolated static func describe(_ error: Error) -> String {
        if let weatherError = error as? WeatherError,
           case .badStatus(let code) = weatherError,
           let hint = QWeatherService.authenticationHint(statusCode: code) {
            return hint
        }
        return FaultDomain.message(for: FaultDomain.classify(error))
    }
}

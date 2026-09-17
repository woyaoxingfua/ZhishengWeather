//
//  WidgetDataResolver.swift
//  Core / Logic  [App + Widget 共用]
//
//  数据阶梯（L0 → L1 → L2）的编排 —— 小组件自力取数的**核心判定**。
//
//      城市阶梯产出 WidgetCityOutcome
//              │
//      ┌───────┴───────────────────────────────────────────────┐
//      │ L0 共享容器载荷（复用 WidgetPayloadResolver 的容器 / 归属 / 新鲜度判定）│
//      │     命中 → .sharedContainer（零网络、零配额）          │
//      ├───────────────────────────────────────────────────────┤
//      │ 无城市 → 按成因给空因（**不取数**，诚实空态）：          │
//      │         .noCity / .locationNotAuthorized / .locationUnavailable │
//      ├───────────────────────────────────────────────────────┤
//      │ L1 自力取数（原样复用 WeatherService，**至多一次**请求）│
//      │     成功 → .selfFetched；失败 → L2                    │
//      ├───────────────────────────────────────────────────────┤
//      │ L2 如实空态（WidgetEmptyReason 驱动可操作文案）        │
//      └───────────────────────────────────────────────────────┘
//
//  为什么放 Core（P-18 同源盲区纪律）：`ZhishengWeatherTests` 只依赖主 App target，
//  Widget target 不进测试包 —— 判定必须在 Core 才能被 CI 单测。测试把
//  「容器状态 / 取数结果 / 时刻」全部**参数注入**，绝不手工模拟实现的假设。
//
//  catch 在哪（ARCH §6.1）：**在本文件内**。`AppIntentTimelineProvider` 的
//  `timeline` / `snapshot` 签名本身**非 throwing**，故失败必须是**返回值**而非异常：
//  任何失败一律收敛为 `WidgetEntryResolution`，**禁止** `try!` / 让错误冒泡 /
//  返回空 `Timeline`（空 Timeline 会触发系统异常渲染）。
//
//  配额纪律（ARCH §14）：全路径**只允许一次** `weather.fetch(latitude:longitude:)`，
//  不新增第二端点、不新增第二请求；权重恒为 1×（不含 climate / ensemble / seasonal
//  等加权参数）。L0 命中 / 无城市 / 快照路径的请求数恒为 **0**。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 小组件数据阶梯编排器（无状态、`now` 与 `weather` 全部注入）。
enum WidgetDataResolver {

    /// L1 取数的**外层硬上限**（秒）。
    ///
    /// 与注入的 8 秒 `URLSession` 超时构成双重保障（ARCH §9）：URLSession 超时
    /// 覆盖绝大多数情况，本上限兜住「URLSession 超时未如期触发」的极端情况
    /// （`WeatherService` 内部只把 `URLError.timedOut` 细分为 `.timeout`）。
    /// 超时 → 取消等待 → L2（`.fetchFailed`），绝不拖垮时间线预算。
    static let fetchBudget: TimeInterval = 10

    /// 数据阶梯主入口（纯编排：无 IO、无时钟，全部依赖注入）。
    /// - Parameters:
    ///   - cityOutcome: 城市阶梯产出（`.resolved` / `.needsConfiguration` /
    ///     `.locationNotAuthorized` / `.locationUnavailable`）。
    ///   - containerAvailable: `AppGroupStore.isSharedContainerAvailable` 的探测结果（**注入**）。
    ///   - loadResult: `AppGroupStore.loadResult()` 的三态结果。
    ///   - now: 当前时刻（注入；Core 禁内部 `Date()`）。
    ///   - allowNetwork: 是否允许 L1 自力取数。`snapshot`（画廊 / 瞬时预览）传 false
    ///     → 只走 L0，绝不触发网络（`snapshot(for:)` 请求数恒为 0）。
    ///   - weather: 取数器（生产传短超时 `WeatherService`；测试传 Fake）。
    ///   - staleThreshold: 陈旧阈值（秒）；默认 `StalePolicy.defaultThreshold`。
    ///   - fetchBudget: L1 硬上限（秒）；默认 `fetchBudget`（测试可注入极小值验证超时收敛）。
    /// - Returns: 收敛值；**永不抛错**（失败一律成为带 `emptyReason` 的返回值）。
    static func resolve(cityOutcome: WidgetCityOutcome,
                        containerAvailable: Bool,
                        loadResult: AppGroupStore.PayloadLoadResult,
                        now: Date,
                        allowNetwork: Bool,
                        weather: WeatherProviding,
                        staleThreshold: TimeInterval = StalePolicy.defaultThreshold,
                        fetchBudget: TimeInterval = WidgetDataResolver.fetchBudget) async -> WidgetEntryResolution {

        // ── L0：共享容器（本地、快路径、零配额）──────────────────────────────
        // 复用 WidgetPayloadResolver（已被单测覆盖的纯函数），保证「容器不可用 /
        // 损坏 / 缺失 / 归属不符 / 过旧」的判定只有**一处**真源：只有真正
        // 「容器可用 + 归属匹配」时才拿到非 nil 载荷（其余一律 nil → 落到下方阶梯）。
        let local = WidgetPayloadResolver.resolve(
            containerAvailable: containerAvailable,
            loadResult: loadResult,
            ownershipMatches: ownershipMatches(city: cityOutcome.city, loadResult: loadResult),
            now: now,
            staleThreshold: staleThreshold)

        if let payload = local.payload, let city = cityOutcome.city {
            // 归属命中的载荷**即便过旧也照发**（保持既有语义：有数据就渲染，只标注）。
            return WidgetEntryResolution(city: city,
                                         payload: payload,
                                         status: local.status,
                                         dataSource: .sharedContainer,
                                         emptyReason: nil)
        }

        // ── 无城市：诚实空态，**不取数**（即便 allowNetwork == true）──────────
        // 这是「幽灵北京」修复的验收点：容器真空 → 无城市 → 引导用户主动配置，
        // 绝不替用户默认北京、绝不冒充城市归属。
        //
        // 空因**不写死**为 `.noCity`：无城市有三种成因（未配置 / 定位未授权 / 定位
        // 落空），三者的**下一步动作完全不同**（选城市 / 授权 / 改选城市），
        // 合并成一句话就是给用户开错处方。映射的唯一真源是
        // `WidgetCityOutcome.emptyReason`（穷尽 switch，新增产出时编译器会指出漏改）。
        guard let city = cityOutcome.city else {
            return WidgetEntryResolution(city: nil,
                                         payload: nil,
                                         status: .missing,
                                         dataSource: .none,
                                         // `?? .noCity` 不可达（`emptyReason` 为 nil
                                         // **仅** `.resolved` 一途），留作类型兜底。
                                         emptyReason: cityOutcome.emptyReason ?? .noCity)
        }

        // ── 快照路径：仅 L0，不联网（画廊 / 瞬时预览不消耗时间线与配额）──────
        guard allowNetwork else {
            return WidgetEntryResolution(city: city,
                                         payload: nil,
                                         status: containerAvailable ? .missing : .unavailable,
                                         dataSource: .none,
                                         emptyReason: containerAvailable ? .noCachedData : .sharedContainerDown)
        }

        // ── L1：自力取数（原样复用 WeatherService；本函数内唯一一次请求）──────
        let outcome = await fetchWithBudget(weather: weather, city: city, budget: fetchBudget)
        switch outcome {
        case .snapshot(var snapshot):
            // 城市名覆盖（对齐 WeatherViewModel 的 R-3 事实更正）：服务层只知坐标，
            // snapshot.location 的 name 恒为「当前位置」；不覆盖则小组件城市名错误。
            snapshot.location = city.locationInfo
            let payload = SharedWeatherPayload(snapshot: snapshot,
                                               updatedAt: now,   // 刚取回 → 必新鲜
                                               timeZoneIdentifier: city.timeZoneIdentifier)
            return WidgetEntryResolution(city: city,
                                         payload: payload,
                                         status: .available,
                                         dataSource: .selfFetched,
                                         emptyReason: nil)

        case .failure(let error):
            return emptyResolution(city: city, error: error)
        }
    }

    // MARK: - 内部

    /// 载荷归属校验：仅当载荷坐标规范化 id 与本实例目标城市 id 相等才算命中
    /// （R-C2 / AC-C6：绝不拿别城数据冒充）。
    /// - Parameters:
    ///   - city: 本实例目标城市；nil → 恒不匹配。
    ///   - loadResult: 容器载荷三态。
    /// - Returns: 是否归属匹配（容器不可用 / 无载荷 / 无城市 → false）。
    private static func ownershipMatches(city: City?,
                                        loadResult: AppGroupStore.PayloadLoadResult) -> Bool {
        guard let city, case .loaded(let payload) = loadResult else { return false }
        return city.id == City.makeID(latitude: payload.snapshot.location.latitude,
                                      longitude: payload.snapshot.location.longitude)
    }

    /// 取数失败 → 如实空态（「无数据」与「取不到」必须分开：文案与处置不同）。
    /// - Parameters:
    ///   - city: 目标城市（保留在 entry 里，标题不丢）。
    ///   - error: `WeatherService` 收敛出的错误。
    /// - Returns: 收敛值（`dataSource = .none`）。
    private static func emptyResolution(city: City, error: WeatherError) -> WidgetEntryResolution {
        if case .dataMissing = error {
            return WidgetEntryResolution(city: city,
                                         payload: nil,
                                         status: .missing,
                                         dataSource: .none,
                                         emptyReason: .cityHasNoData)
        }
        return WidgetEntryResolution(city: city,
                                     payload: nil,
                                     status: .unavailable,
                                     dataSource: .none,
                                     emptyReason: .fetchFailed)
    }

    /// L1 取数 + 外层硬上限竞速（ARCH §9）。
    ///
    /// 用**非 throwing** 的 `withTaskGroup`：取数子任务把错误就地映射为
    /// `FetchRaceResult`（`WeatherError` 是 `Sendable`，跨子任务安全），
    /// 计时子任务只产出 `.failure(.timeout)` —— 故**没有**任何错误会从任务组
    /// 逃逸出去（throwing 任务组在 body 正常返回时对残留子任务错误的行为
    /// 不值得赌），失败一律成为**返回值**。
    /// - Parameters:
    ///   - weather: 取数器（Sendable）。
    ///   - city: 目标城市（坐标来源）。
    ///   - budget: 硬上限（秒）。
    /// - Returns: 首个子任务结果；超时 / 任务组异常 → `.failure(.timeout)`。
    private static func fetchWithBudget(weather: WeatherProviding,
                                        city: City,
                                        budget: TimeInterval) async -> FetchRaceResult {
        let nanoseconds = UInt64(max(budget, 0) * 1_000_000_000)
        return await withTaskGroup(of: FetchRaceResult.self,
                                   returning: FetchRaceResult.self) { group in
            group.addTask {
                do {
                    let snapshot = try await weather.fetch(latitude: city.latitude,
                                                          longitude: city.longitude)
                    return .snapshot(snapshot)
                } catch let error as WeatherError {
                    return .failure(error)
                } catch {
                    // 非 WeatherError（例如取消）→ 按传输层失败收敛，绝不外泄异常。
                    return .failure(.network(error.localizedDescription))
                }
            }
            group.addTask {
                // 计时子任务：取消感知（try?），被取消时立即返回（结果会被丢弃）。
                try? await Task.sleep(nanoseconds: nanoseconds)
                return .failure(.timeout("小组件取数超过 \(Int(budget)) 秒硬上限"))
            }
            let first = await group.next() ?? .failure(.timeout("小组件取数任务组为空"))
            group.cancelAll()
            return first
        }
    }

    /// 取数竞速结果（`Sendable`：跨子任务传递，故不携带泛型 `Error`）。
    private enum FetchRaceResult: Sendable {

        /// 取数成功。
        case snapshot(WeatherSnapshot)
        /// 取数失败（含硬上限超时 / 任务组异常）。
        case failure(WeatherError)
    }
}

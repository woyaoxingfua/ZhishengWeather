//
//  EarthquakeCardModel.swift
//  ZhishengWeather（主 App target）
//
//  地震卡的主屏状态容器（`@Observable` + `@MainActor`）—— 与
//  `TyphoonCardModel` / `FloodCardModel` / `RadarCardModel` **同款**
//  （独立链路 + 独立失败域 + `@State` 持有）。
//
//  ── 为什么独立于 `WeatherViewModel` ───────────────────────────────────
//  `earthquake.usgs.gov` 是**独立域名 + 独立失败域**，取数失败只该写
//  自己的状态。塞进主 VM 会污染主 `state` → 违反本仓「失败隔离」纪律。
//  同时 `EarthquakeEvent` **不在 `WeatherFieldKey` 域内**，本就进不了
//  `WeatherSnapshot`，故独立成类型是**唯一合理形状**。
//
//  ── 🔴 四态（**本类型唯一的判定出口**，视图只渲染不判定）─────────────
//  · `.idle`       未开始取数；
//  · `.unavailable(String)` **取不到**（网络 / 非 2xx / 解码失败 /
//                   返回了非 JSON 错误页）；
//  · `.none`       **取到了，且该坐标附近确实没有符合条件的地震**
//                —— **合法业务结果，不是故障**；
//  · `.available([EarthquakeEvent])` 附近确有地震（**已按距离升序**）。
//
//  🔴 `.none` 与 `.unavailable` **必须分开**（与台风卡 `.none`、
//  洪水卡 `.noData` 同款纪律）：
//  实测北京 300km / 30 天 / M2.5+ 返回 **0 条**（主理人已确认那是
//  **真的没地震**，不是参数写错）—— 「附近没有地震」在地震带之外
//  是**长期常态**。把它显示成「地震数据取不到」是**内容错误**：
//  用户无从分辨，而两者给出的行动建议完全相反。
//
//  🔴 `.none` 的判据（**只看 `isEffectivelyEmpty`，不看任何别的东西**）：
//  Core 层 mapper 已经把「缺时刻 / 缺经纬 / 坐标越界 / 距离算不出」的
//  feature **逐条丢弃**，所以 feed 只有两种状态：
//  有完整事件 / 空。→ **空 == 真的没有可展示的附近地震**。
//  ⚠️ 反向的坑要防：**绝不能**用「条数 < limit（20）」判`.none`
//  —— 那是「取满了 20 条」，恰恰**有**地震。
//
//  ⚠️ **`.none` 的语义边界（文案必须如实带上）**：本源说的是
// 「**300km 内没有 M2.5 以上的地震**」，**不是**「300km 内任何震动都没有」。
//  微弱的、被过滤掉的地震仍然可能发生过。文案必须带上这个限定，
//  否则用户会以为「这里从来没有过震」。
//
//  ── 坐标来源：复用既有真源，绝不新建第二套 ───────────────────────────
//  坐标由 `ContentView` 传入（`viewModel.resolvedCoordinateForRadar` ——
//  与雷达卡 / 洪水卡**同一个**属性）。本类型**只接收**坐标，
//  不自己去查城市、不持有任何城市状态。
//
//  ── 时间注入 ─────────────────────────────────────────────────────────
//  `now` **注入**（默认 `Date()` 只在 App 调用点生效），由它派生
// `startDate`（查询窗口起点），单测可固定它断言 URL 与超时判定。
//
//  Core 纪律：本文件在 App target，但**不含**任何取数判据逻辑
//  （那些都在 Core 的纯函数里），本文件只做「状态 + 生命周期」。
//

import Foundation
import Observation

/// 地震卡主屏状态。
@MainActor
@Observable
final class EarthquakeCardModel {

    // MARK: - 对外状态

    /// 四态（**视图只消费这个**）。
    private(set) var state: State = .idle

    /// 是否正在取数（**只用于显示"正在加载"，不参与四态判定**）。
    private(set) var isLoading: Bool = false

    /// 加载是否已超时（秒）。
    ///
    /// ⚠️ **必须有超时兜底**（与 `FloodCardModel` 同款纪律）：取数卡住时
    /// 一直转圈，用户看到的就是「转圈卡死」——那是最容易被当成
    /// 「功能正常只是慢」的失败态。
    /// 🔴🔴 **为什么 25 秒**（2026-10-08 改，实测定位）：
    /// 原本 12 秒，而主屏**同 id 的多个 `.task` 会串行排队** → 排在后面的链路
    /// 等十几秒才轮到 → 12 秒阈值被打爆 → 用户频繁看到「加载超时」。
    /// → 已把四条链路**合并成一个 `.task` + `async let` 并发**（治本）；
    /// 本阈值上调到 25 秒是**兜底**（承弱网 / 限流 / 冷启动 DNS），不是治本。
    /// ⚠️ 别再用「调大超时」掩盖排队问题 —— 那会让真慢的请求更难被发现。
    static let loadTimeout: TimeInterval = 25

    /// 本次加载是否已超时。
    private(set) var hasTimedOut: Bool = false

    /// **回溯窗口**（天）：查询起始时刻 = `now - lookbackDays`。
    ///
    /// ⚠️ 为什么**注入 `now` 再回溯**，而不是让 Core 自己算：
    /// Core内禁 `Date()`（SC-11）→ Core 拿不到「现在」。
    /// 故 `lookbackDays` 放在 App 层（这里是**取数窗口的业务参数**，
    /// 不是 Core 的协议常量），由 `load` 派生并注入 `startDate`。
    ///
    /// 取 30 天的理由：30 天覆盖一个完整的「日常无感期」——
    /// 若 300km 内 30 天内连M2.5 都没有，那就是**真的安稳**，
    /// 卡片显示「附近没有地震」是**如实结论**而非信息不足。
    static let lookbackDays = 30

    // MARK: - 状态枚举

    /// 四态（**纯枚举 + 无 raw type**，本仓陷阱：enum 不能同时用 raw type
    /// 与关联值 case）。
    enum State: Equatable {

        /// 未开始取数。
        case idle

        /// **取到了，且附近确实没有符合条件的地震**（合法业务结果，非故障）。
        case none

        /// **附近确有地震**（已按距用户的距离升序，可直接渲染）。
        case available([EarthquakeEvent])

        /// **取不到**（网络 / 非 2xx / 非 JSON 错误页 / 解码失败）。
        case unavailable(String)
    }

    // MARK: - 依赖

    /// 取数服务（测试注入 Stub）。
    private let service: any UsgsEarthquakeProviding

    // MARK: - 构造

    /// 初始化。
    /// - Parameter service: 取数实现（测试注入 Stub）。
    init(service: any UsgsEarthquakeProviding = UsgsEarthquakeService()) {
        self.service = service
    }

    // MARK: - 生命周期

    /// 加载附近地震（主屏 `.task(id: 城市 id)` 调用）。
    ///
    /// - Parameters:
    ///   - latitude: 选中城市纬度（WGS84，**由调用方从既有真源取**，本类不查城市）。
    ///   - longitude: 选中城市经度（WGS84）。
    ///   - now: 本次加载的**起点**（**注入**，单测可固定；超时判定与
    ///     查询窗口起点都由它派生）。
    func load(latitude: Double, longitude: Double, now: Date = Date()) async {
        isLoading = true
        hasTimedOut = false
        defer { isLoading = false }

        do {
            // 查询窗口起点（注入给 Core，Core 内不取时钟）。
            let windowSeconds = TimeInterval(Self.lookbackDays) * 24 * 60 * 60
            let startDate = now.addingTimeInterval(-windowSeconds)

            let fetched = try await service.fetchNearbyEvents(latitude: latitude,
                                                              longitude: longitude,
                                                              startDate: startDate)
            // ⚠️ 实质无数据 → `.none`，**不抛错、不当故障**
            //（判据的权威在 Core `EarthquakeFeed.isEffectivelyEmpty`，此处只转发）。
            //
            // ⚠️ **绝不用「条数 < limit」当判据**（那是「取满了」，恰恰有地震）。
            if fetched.isEffectivelyEmpty {
                state = .none
            } else {
                state = .available(fetched.events)
            }
        } catch {
            // ⚠️ 故障 → `.unavailable`，**绝不**落到 `.none`
            //（否则网络失败会被显示成「附近没有地震」——
            //  那是一条**内容错误**，且用户无从分辨）。
            state = .unavailable(Self.describe(error))
        }

        // 超时兜底：读**完成时刻**与注入起点的差（不能自己减自己 —— 恒为 0）。
        hasTimedOut = Date().timeIntervalSince(now) > Self.loadTimeout
    }

    // MARK: - 派生便捷量

    /// 附近地震里**最大震级**的那一条（nil = 无事件 / 全部未给出震级）。
    ///
    /// ⚠️ **只统计有震级的地震**（`magnitude != nil`）——
    /// 缺震级的地震**不参与**「最大震级」比较，否则 nil 会被当成 0
    /// 让「最大震级」凭空变成 0.0（那是凭空造一条读数）。
    ///
    /// ⚠️ **不能靠「第一条」**：事件是**按距离升序**排的（mapper 的展示口径），
    /// 最近的地震**未必**是最大的那一次。故必须**真的按震级比较**。
    /// 这是「排序口径 ≠ 极值口径」的典型：同一数组两种用法。
    ///
    /// ⚠️ 这与 `EarthquakeFeed.isEffectivelyEmpty` **不是同一条判据**：
    /// 那里问「有没有**任何**可展示事件」，这里问「**最大震级**是谁」。
    var strongestEvent: EarthquakeEvent? {
        guard let events = stateOfAvailable else { return nil }
        var best: EarthquakeEvent?
        for event in events {
            guard let magnitude = event.magnitude else { continue }
            guard let current = best, let currentMagnitude = current.magnitude else {
                best = event
                continue
            }
            // 严格大于：并列时保留**先遇到**的那条 → 顺序稳定、可复现。
            if magnitude > currentMagnitude { best = event }
        }
        return best
    }

    /// 把 `.available` 的关联值取出来（非 `.available` → nil）。
    ///
    /// 单一出口：视图与派生量都走这里，避免**三处各写一遍 switch**。
    ///
    /// ⚠️ **对 `EarthquakeCard` 开放**：视图渲染列表需要同一份事件数组，
    ///   故**暴露为只读属性**（而不是让视图自己再 switch 一次 `state` ——
    ///   那会形成第二个真源，模型一改状态机视图就跟着坏）。
    var availableEvents: [EarthquakeEvent]? { stateOfAvailable }

    private var stateOfAvailable: [EarthquakeEvent]? {
        if case .available(let events) = state { return events }
        return nil
    }

    // MARK: - 错误文案

    /// 故障 → 用户可读文案。
    ///
    /// ⚠️ **单一真源**：走 Core 的 `FaultDomain.classify` + `.message(for:)`
    /// （与 `FloodCardModel.describe` / `WeatherViewModel` 同一对函数）。
    /// **不在这里 switch `WeatherError` 自己拼句子** —— 那正是本仓栽过的
    /// 「一处改了、别处没改」的同源漂移。
    ///
    /// ⚠️ `nonisolated`：与 `FloodCardModel.describe` / `TyphoonCardModel.describe`
    /// 同款理由 —— 静态成员默认会带 `@MainActor` 隔离，而这是**纯函数**
    ///（只依赖入参）。
    nonisolated static func describe(_ error: Error) -> String {
        FaultDomain.message(for: FaultDomain.classify(error))
    }
}
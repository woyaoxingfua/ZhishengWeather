//
//  FloodCardModel.swift
//  ZhishengWeather（主 App target）
//
//  河道流量（洪水）卡的主屏状态容器（`@Observable` + `@MainActor`）—— 与
//  `TyphoonCardModel` / `RadarCardModel` / `SatelliteCardModel` **同款**
//  （独立链路 + 独立失败域 + `@State` 持有）。
//
//  ── 为什么独立于 `WeatherViewModel` ─────────────────────────────────
//  `flood-api.open-meteo.com` 是**独立子域名 + 独立失败域**，取数失败只该写
//  自己的状态。塞进主 VM 会污染主 `state` → 违反本仓「失败隔离」纪律。
//  同时 `RiverDischarge` **不在** `WeatherFieldKey` 域内（见 `FloodProviding`
//  文件头），本就进不了 `WeatherSnapshot`，故独立成类型是**唯一合理形状**。
//
//  ── 🔴 四态（**本类型唯一的判定出口**，视图只渲染不判定）─────────────
//  · `.idle`       未开始取数；
//  · `.unavailable(String)` **取不到**（网络 / 非 2xx / 解码失败）；
//  · `.noData`     **取到了，且该坐标确实没有河道数据** —— 合法业务结果；
//  · `.available`  取到了**至少一天有非 nil 流量**的序列。
//
//  ⚠️ `.noData` 与 `.unavailable` **必须分开**（与台风卡的 `.none` 同款纪律）：
//  实测 flood 端点存在「整块静默省略」形态（`daily` 键不存在，HTTP **200**，
//  见 `SnapshotCompleteness.isEffectivelyEmpty(_:)` 文件头）——此时解码成功、
//  序列为空。把「这一带没有河道数据」显示成「数据取不到」是**内容错误**：
//  用户会以为产品坏了，而实际是正常的地理事实。
//
//  ⚠️ **反向的坑同样要防**：实测乌鲁木齐 (43.8,87.6) 断流时返回
//  `[0.00, 0.00, 0.00]` —— **有键、有值、值为零**，那是**真实的断流读数**，
//  不是"没查到"。故本类型的 `.available` 判据是「**有没有非 nil 的值**」，
//  **不是**「值是否全为零」。这条判据的权威在
//  `SnapshotCompleteness.isEffectivelyEmpty(_ discharge:)`（Core 单一真源），
//  本类型只转发，不重算。
//
//  ── 坐标来源：复用既有真源，绝不新建第二套 ─────────────────────────
//  坐标由 `ContentView` 传入（`viewModel.resolvedCoordinateForRadar` ——
//  与雷达卡**同一个**属性，"当前位置"项用 VM 已解析的 `location` 覆盖）。
//  本类型**只接收**坐标，不自己去查城市、不持有任何城市状态。
//
//  ── 时间注入 ──────────────────────────────────────────────────────
//  `now` **注入**（默认 `Date()` 只在 App 调用点生效），单测可固定它
//  断言超时判定。
//
//  Core 纪律：本文件在 App target，但**不含**任何取数判据逻辑
// （那些都在 Core 的纯函数里），本文件只做「状态 + 生命周期」。
//

import Foundation
import Observation

/// 河道流量卡主屏状态。
@MainActor
@Observable
final class FloodCardModel {

    // MARK: - 对外状态

    /// 四态（**视图只消费这个**）。
    private(set) var state: State = .idle

    /// 已取到的逐日序列（`nil` = 未取到 / 取不到 / 实质无数据）。
    ///
    /// ⚠️ 与 `state` **并存**而非塞进枚举关联值：序列本身可能有 7 条，
    /// 放进 `State` 会让四态枚举同时承担"判定"与"数据"两件事 ——
    /// 那是 `RadarCardModel` 早期形状，本仓已改为「派生四态 + 独立数据槽位」。
    private(set) var discharge: RiverDischarge?

    /// 是否正在取数（**只用于显示"正在加载"，不参与四态判定**）。
    private(set) var isLoading: Bool = false

    /// 加载是否已超时（秒）。
    ///
    /// ⚠️ **必须有超时兜底**（与 `RadarCardModel` 同款纪律）：取数卡住时
    /// 一直转圈，用户看到的就是「转圈卡死」——那是最容易被当成
    /// 「功能正常只是慢」的失败态。
    /// 🔴 **25 秒**（2026-10-08 改）：原 12秒在主屏多 `.task` 串行排队下被误爆。
    /// 排队问题已由「合并成单 `.task` + `async let` 并发」治本；
    /// 此值上调仅作弱网兜底。同 `EarthquakeCardModel` 注释。
    static let loadTimeout: TimeInterval = 25

    /// 本次加载是否已超时。
    private(set) var hasTimedOut: Bool = false

    // MARK: - 状态枚举

    /// 四态（**纯枚举 + 无 raw type**，本仓陷阱：enum 不能同时用 raw type
    /// 与关联值 case）。
    enum State: Equatable {

        /// 未开始取数。
        case idle

        /// **取到了，且该坐标确实没有河道数据**（合法业务结果，非故障）。
        case noData

        /// **取到了至少一天有非 nil 流量的序列**。
        case available

        /// **取不到**（网络 / 非 2xx / 解码失败）。
        case unavailable(String)

        /// 供 UI 显示的一句话（**如实，不夸大**；判定本身在下面的 `switch`）。
        var headline: String {
            switch self {
            case .idle: return "未加载"
            case .noData: return "该坐标无河道数据"
            case .available: return "已更新"
            case .unavailable: return "河道流量取不到"
            }
        }
    }

    // MARK: - 依赖

    /// 取数服务（测试注入 Stub）。
    private let service: any FloodProviding

/// 用量计数落点（测试注入隔离实例）。
    ///
    /// ⚠️ **为什么可注入**：设置页「今日用量」的数字必须能被单测**真的观察到
    /// 变化**。若这里写死 `.shared`，测试就只能去读进程级共享账本 ——
    /// 那既污染真实 `UserDefaults.standard`，又让「失败不加」这类断言
    /// 依赖上一个测试留下的残留（典型的**顺序依赖假绿**）。
    /// 故与 `service` 同款做成注入项。
    private let health: SourceHealthTracker

    // MARK: - 构造

    /// 初始化。
    /// - Parameter service: 取数实现（测试注入 Stub）。
    /// - Parameters:
    ///   - service: 取数实现（测试注入 Stub）。
    ///   - health: 用量计数落点（默认共享实例；测试注入隔离 ledger）。
    init(service: any FloodProviding = FloodService(),
         health: SourceHealthTracker = .shared) {
        self.service = service
        self.health = health
    }

    // MARK: - 生命周期

    /// 加载河道流量（主屏 `.task(id: 城市 id)` 调用）。
    ///
    /// - Parameters:
    ///   - latitude: 选中城市纬度（WGS84，**由调用方从既有真源取**，本类不查城市）。
    ///   - longitude: 选中城市经度（WGS84）。
    ///   - now: 本次加载的**起点**（**注入**，单测可固定；超时判定用它）。
    func load(latitude: Double, longitude: Double, now: Date = Date()) async {
        isLoading = true
        hasTimedOut = false
        defer { isLoading = false }

        do {
            let fetched = try await service.fetch(latitude: latitude, longitude: longitude)
            // 河道流量源用量计数。⚠️ `.noData`（该坐标无河道数据）**也算成功**——
            // 请求成功返回、只是内容为空，与 `.unavailable`（真取不到）严格分开。
            await health.recordSuccess(.floodForecast, at: Date())
            // ⚠️ 实质无数据 → `.noData`，**不抛错、不当故障**
            //（判据的权威在 Core `SnapshotCompleteness`，此处只转发）。
            //
            // ⚠️ 全 0 的序列**判为有数据**（`isEffectivelyEmpty` 只看「有没有非 nil」）——
            //   断流是真实读数，把它说成缺测是另一种谎报。
            if fetched.isEffectivelyEmpty {
                discharge = nil
                state = .noData
            } else {
                discharge = fetched
                state = .available
            }
        } catch {
            // ⚠️ 故障 → `.unavailable`，**绝不**落到 `.noData`
            //（否则网络失败会被显示成「这一带没有河道」）。
            discharge = nil
            state = .unavailable(Self.describe(error))
        }

        // 超时兜底：读**完成时刻**与注入起点的差（不能自己减自己 —— 恒为 0）。
        hasTimedOut = Date().timeIntervalSince(now) > Self.loadTimeout
    }

    // MARK: - 派生便捷量

    /// 逐日序列中**第一个有值**的日期（视图用它说明"哪天真的有流量"）。
    ///
    /// ⚠️ 不是 `daily.first`：实测存在「首日缺测、后续有值」的形态
    /// （`FloodMapper` 对时刻为 null 的日子是**跳过**、对值缺测是**保留 nil**），
    /// `daily.first` 未必有值。
    ///
    /// ⚠️ 判据是「有没有非 nil」，与 `SnapshotCompleteness.isEffectivelyEmpty(_:)`
    /// 同源但**方向相反**：那里问「是否**全部**为空」，这里问「**首个**非空是谁」。
    /// 故这不是重复实现，而是同一判据的两种问法。
    var firstMeasuredPoint: RiverDischargePoint? {
        discharge?.daily.first { $0.cubicMetresPerSecond != nil }
    }

    // MARK: - 错误文案

    /// 故障 → 用户可读文案。
    ///
    /// ⚠️ **单一真源**：走 Core 的 `FaultDomain.classify` + `.message(for:)`
    /// （与 `WeatherViewModel` 同一对函数）。**不在这里 switch `WeatherError`
    /// 自己拼句子** —— 那正是本仓栽过的「一处改了、别处没改」的同源漂移。
    ///
    /// ⚠️ `nonisolated`：与 `TyphoonCardModel.describe` 同款理由 ——
    /// 静态成员默认会带 `@MainActor` 隔离，而这是**纯函数**（只依赖入参）。
    nonisolated static func describe(_ error: Error) -> String {
        FaultDomain.message(for: FaultDomain.classify(error))
    }
}
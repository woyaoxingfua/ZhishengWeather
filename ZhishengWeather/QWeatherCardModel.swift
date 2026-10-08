//
//  QWeatherCardModel.swift
//  ZhishengWeather
//
//  第九源「和风天气」逐日预报卡的**主屏状态容器**（`@MainActor @Observable`）。
//
//  ✅ 实测基准：2026-10-08（主理人用真实凭据在本机打通，HTTP 200）
//  ══════════════════════════════════════════════════════════════════════════
//
//  ── 四态（与本仓其它卡同款，但 `.noData` 的判据是本源的）────────────────
//  · `.idle`未加载
//  · `.available`上游下发了≥1 天
//  · `.noData`     响应结构完整但 `days` 为空 → **合法响应，不是故障**
//  · `.unavailable(String)` 取不到（网络 / 鉴权 / 解码）
//
//  🔴 `.noData` 与 `.unavailable` **必须分开** —— 把「上游没给数据」
//显示成「取不到」，用户会去查网络，而问题在上游（纪律同台风/洪水/地震卡）。
//
//  ── 🔴 鉴权失败必须**可区分**（401 vs 403）─────────────────────────────
//  `QWeatherService` 只保留原始状态码（`WeatherError.badStatus(Int)`），
//  「人话说明」由本类的 `describe(_:)` 依
//  `QWeatherService.authenticationHint(statusCode:)` **二次渲染** ——
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

/// 和风逐日预报卡状态容器。
@MainActor
@Observable
final class QWeatherCardModel {

    // MARK: - 状态

    /// 四态（**纯枚举 + 无 raw type** —— 本仓陷阱：enum 不能同时用 raw type
    /// 与关联值 case，见 P-10）。
    enum State: Equatable {
        /// 未加载。
        case idle
        /// 上游响应完整但 `days` 为空（**合法响应，不是故障**）。
        case noData
        /// 已取到至少一天。
        case available
        /// 取不到（附用户可读原因）。
        case unavailable(String)
    }

    /// 当前状态。
    private(set) var state: State = .idle

    /// 是否正在取数。
    private(set) var isLoading: Bool = false

    /// 本次加载是否超时（用于卡内如实提示"结果可能不是最新"）。
    private(set) var hasTimedOut: Bool = false

    /// 取到的逐日预报（`.available` 时非 nil）。
    private(set) var forecast: QWeatherDailyForecast?

    // MARK: - 超时

    /// 取数超时阈值（**秒**）。
    static let loadTimeout: TimeInterval = 12

    // MARK: - 依赖

    private let service: any QWeatherProviding

    /// 初始化。
    /// - Parameter service: 取数实现（测试注入 Stub）。
    init(service: any QWeatherProviding = QWeatherService()) {
        self.service = service
    }

    // MARK: - 取数

    /// 拉取逐日预报。
    ///
    /// - Parameters:
    ///   - latitude: 选中城市纬度（WGS84，**由调用方从既有真源取**）。
    ///   - longitude: 选中城市经度（WGS84）。
    ///   - days: 请求天数（官方文档 1–10；越界由 Endpoint 收敛为 `badURL`）。
    ///   - now: 本次加载的**起点**（**注入**，单测可固定；超时判定用它）。
    func load(latitude: Double,
              longitude: Double,
              days: Int = QWeatherEndpoint.defaultDays,
              now: Date = Date()) async {
        isLoading = true
        hasTimedOut = false
        defer { isLoading = false }

        do {
            let fetched = try await service.fetchDaily(latitude: latitude,
                                                       longitude: longitude,
                                                       days: days)
            // ⚠️ 实质无数据 → `.noData`，**不抛错、不当故障**
            //（判据的权威在 Core `QWeatherDailyForecast.isEffectivelyEmpty`，
            //  此处只转发，不重算）。
            if fetched.isEffectivelyEmpty {
                forecast = fetched
                state = .noData
            } else {
                forecast = fetched
                state = .available
            }
        } catch {
            // ⚠️ 故障 → `.unavailable`，**绝不**落到 `.noData`
            //（否则鉴权失败会被显示成「上游没给数据」）。
            forecast = nil
            state = .unavailable(Self.describe(error))
        }

        // 超时兜底：读**完成时刻**与注入起点的差（不能自己减自己 —— 恒为 0）。
        hasTimedOut = Date().timeIntervalSince(now) > Self.loadTimeout
    }

    // MARK: - 派生便捷量（视图只渲染，不判定）

    /// 逐日序列（**视图唯一入口**；非 `.available` → 空数组）。
    var days: [QWeatherDay] {
        forecast?.days ?? []
    }

    /// 🔴 上游署名（**合规硬要求**，视图页脚**无条件**渲染）。
    var attributions: [String] {
        forecast?.attributions ?? []
    }

    // MARK: - 错误文案

    /// 故障 → 用户可读文案。
    ///
    /// ⚠️ **单一真源**：先走 Core 的 `FaultDomain.classify` + `.message(for:)`
    /// （与 `FloodCardModel.describe` / `EarthquakeCardModel.describe` 同一对函数）
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
//
//  TyphoonCardModel.swift
//  ZhishengWeather（主 App target）
//
//  台风卡的主屏状态容器（`@Observable` + `@MainActor`）—— 与 `RadarCardModel`
//  **同款**（独立链路 + 独立失败域 + `@State` 持有）。
//
//  ── 为什么独立于 `WeatherViewModel` ─────────────────────────────────
//  与雷达同款理由：台风是**独立链路**（独立端点、独立失败域），
//  失败只该写自己的状态。塞进主 VM 会污染主 `state` → 违反失败隔离纪律。
//
//  ── 🔴 四态（**本类型唯一的判定出口**，视图只渲染不判定）─────────────
//  · `.idle` 未开始取数；
//  · `.loading` 首次加载中（显示"正在加载"，**不参与**四态判定）；
//  · `.none` **取到了，且上游当前确实没有活跃台风** → 显示
//    「当前无活跃台风」。⚠️ 这是**合法业务结果**、不是故障：
//    台风并非全年都有（实测历史年份 `list_1950` 42 条**全部** `"stop"`）。
//  · `.active` 有活跃台风（附列表）；
//  · `.unavailable` **取不到** → 显示「台风数据取不到」+ 重试。
//
//  ⚠️ `.none` 与 `.unavailable` **必须分开**：实测上游约3 小时量级延迟、
//  且免Key 无鉴权，失败极可能来自网络。把「取不到」显示成「无台风」是
//  **内容错误**（用户在台风季最需要信息时看到"没有台风"），
//  且用户**无从分辨**。这与 `NmcAlarmProviding` 的
//  「返回空数组 ≠ 成功」是同一条纪律。
//
//  ── 历史年份 ──────────────────────────────────────────────────────
//  实测 `list_<年>` 可回溯到 **1950**（`NmcTyphoonEndpoint.earliestSupportedYear`）。
//  故年份选择器给出「当前年 − 5 .. 当前年」，**不铺开 76 年**
//  （实测历史年份条目全为 `"stop"`，铺开只是让用户点进一堆空结果）。
//
//  ── 时间注入 ──────────────────────────────────────────────────────
//  所有 `now` 均**注入**（默认 `Date()` 只在 App 侧调用点生效），
//  单测可固定它断言「延迟提示」。
//
//  Core 纪律：本文件在 App target；但**不含**任何取数判据逻辑
//  （那些都在 Core 的纯函数里），本文件只做「状态 + 生命周期」。
//

import Foundation
import Observation

/// 台风卡主屏状态。
@MainActor
@Observable
final class TyphoonCardModel {

    // MARK: - 对外状态

    /// 降级四态 + 活跃台风列表（**视图只消费这个**）。
    private(set) var state: State = .idle

    /// 是否正在加载（**只用于显示"正在加载"，不参与四态判定**）。
    private(set) var isLoading: Bool = false

    /// 当前选中的历史年份（nil = 看当前活跃台风）。
    private(set) var selectedYear: Int?

    /// 已展开详情的台风（nil = 未展开）。
    private(set) var detail: TyphoonTrack?

    /// 详情取数失败（true = 展开过某个台风但取不到）。
    private(set) var detailFailed: Bool = false

    /// 四态。
    enum State: Equatable {
        /// 未开始取数。
        case idle
        /// **取到了，且当前没有活跃台风**（合法业务结果，非故障）。
        case none
        /// 有活跃台风。
        case active([TyphoonSummary])
        /// **取不到**（网络 / 解码 / 非 2xx）。
        case unavailable(String)
    }

    /// 可选年份（**注入 `currentYear`**，单测不读系统时钟）。
    ///
    /// ⚠️ 上界 = 当前年，下界 = `currentYear - 4`，且**不低于实测下界 1950**。
    ///
    /// ⚠️ **必须标 `nonisolated`**：本类是 `@MainActor`，静态成员**默认也带
    /// 隔离**，而单测在非隔离的同步上下文里调它 —— 不标会编译失败
    /// （"call to main actor-isolated … in a synchronous nonisolated context"）。
    /// 标注与实际依赖一致：本函数**只依赖入参**与
    /// `NmcTyphoonEndpoint.earliestSupportedYear`（静态常量，非隔离）。
    nonisolated static func selectableYears(currentYear: Int) -> [Int] {
        let lower = max(NmcTyphoonEndpoint.earliestSupportedYear, currentYear - 4)
        guard lower <= currentYear else { return [] }
        return Array((lower...currentYear).reversed())
    }

    // MARK: - 依赖

    private let service: any NmcTyphoonProviding

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
    init(service: any NmcTyphoonProviding = NmcTyphoonService(),
         health: SourceHealthTracker = .shared) {
        self.service = service
        self.health = health
    }

    // MARK: - 生命周期

    /// 加载台风列表（主屏 `.task` 调用）。
    ///
    /// - Parameters:
    ///   - year: 历史年份；nil = 当前活跃台风（`list_default`）。
    ///   - currentYear: 当前年份（**注入**，用于筛掉未来年份）。
    func load(year: Int?, currentYear: Int = Date().currentYearValue) async {
        selectedYear = year
        isLoading = true
        defer { isLoading = false }

        do {
            let summaries: [TyphoonSummary]
            if let year {
                // 未来年份**不构造请求**（实测 `list_2030` → 404 HTML）。
                guard year <= currentYear else {
                    state = .unavailable("所选年份尚未到来")
                    return
                }
                summaries = try await service.fetchSummaries(year: year)
            } else {
                summaries = try await service.fetchSummaries()
            }
            let active = NmcTyphoonMapper.activeOnly(summaries)
            // 台风源用量计数（设置页「今日用量」）。
            // ⚠️ **`.none`（无活跃台风）也计数**：请求成功返回、只是结果为空，
            // 把它算成失败会让用量虚低 —— 与 `.unavailable`（真取不到）严格分开。
            await health.recordSuccess(.nmcTyphoon, at: Date())
            // ⚠️ 空数组 = **真的没有活跃台风**（不是失败）→ `.none`。
            state = active.isEmpty ? .none : .active(active)
        } catch {
            // ⚠️ 故障 → `.unavailable`，**绝不**落到 `.none`
            //（否则网络失败会被显示成「当前无活跃台风」）。
            state = .unavailable(Self.describe(error))
        }
    }

    /// 展开某个台风的详情（路径 + 预报）。
    ///
    /// - Parameter summary: 目标台风。
    func loadDetail(for summary: TyphoonSummary) async {
        detail = nil
        detailFailed = false
        do {
            detail = try await service.fetchTrack(id: summary.id)
            // ⚠️ 解码成功但结构不符 → `detail` 为 nil：这**是**一种取不到，
            // 必须显示为失败（而不是静默什么都不渲染）。
            detailFailed = (detail == nil)
        } catch {
            detailFailed = true
        }
    }

    /// 收起详情。
    func clearDetail() {
        detail = nil
        detailFailed = false
    }

    // MARK: - 错误文案

    /// 故障 → 用户可读文案（**如实区分网络 / 状态码 / 解码**）。
    ///
    /// ⚠️ `nonisolated`：与上面同理，静态成员默认会带 `@MainActor` 隔离，
    /// 而这是**纯函数**（只依赖入参 `WeatherError`，不碰任何隔离状态）。
    nonisolated static func describe(_ error: Error) -> String {
        guard let weatherError = error as? WeatherError else {
            return "未知错误"
        }
        switch weatherError {
        case .badURL:
            return "请求地址构造失败"
        case .badStatus(let code):
            // ⚠️ 实测 404 是「台风 id 不存在或未来年份」，如实呈现状态码。
            return "服务返回状态码 \(code)"
        case .network(let detail):
            return "网络失败：\(detail)"
        case .decoding, .decodingDetail:
            return "数据格式无法解析"
        case .timeout:
            return "请求超时"
        case .dataMissing(let detail):
            return detail
        case .appGroup(let detail):
            return detail
        }
    }
}

// MARK: - 年份取值

extension Date {
    /// 当前年份（**由 App 侧调用**；`Core/` 内不读内部 `Date()`）。
    var currentYearValue: Int {
        // ⚠️ 固定 locale + 公历，避免设备区域设置让年份解析异常。
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.component(.year, from: self)
    }
}
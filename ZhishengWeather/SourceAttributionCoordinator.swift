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
//  `solarOverlay`（4 个 solar 字段补丁）+ `attribution`；**绝不**拷贝/缓存整份
//  `WeatherSnapshot`，**绝不**重发主源请求。主源快照唯一真相源仍是
//  `WeatherViewModel.snapshot`；overlay 仅在渲染 DaylightCard 时逐字段叠加。
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

    /// 合并后的 solar 字段覆盖层（仅 4 格；nil 字段完全退回主快照值）。
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

    /// 按城市拉取辅助源并逐字段合并（输入 = 坐标 + 主源 solar + 注入 now）。
    ///
    /// - Parameters:
    ///   - city: 当前城市（`City.timeZoneIdentifier == nil` → 不补值，不猜测）。
    ///   - primarySolar: 主快照已有的 sunrise/sunset（用于逐字段对比）。
    ///   - now: 采集时刻（调用方注入）。
    func refresh(for city: City, primarySolar: PrimarySolarInput, now: Date) async {
        // 诚实红线（§3.5）：城市时区未知 → 不补值、不退回设备时区、不猜城市。
        guard city.timeZoneIdentifier != nil else {
            applyEmptyOverlay(now: now)
            return
        }
        // 手动停用 / 会话摘除 / 冷却中 → 跳过辅助源，仅记录主源归因。
        if await health.exclusionReason(for: .sunriseSunset, now: now) != nil {
            applyEmptyOverlay(now: now)
            return
        }

        // 主源已有的 solar 字段（来自主快照；solarNoon/daylightDuration 主源无）。
        let primaryPatch = FieldPatch(sourceID: .openMeteoForecast,
                                      capturedAt: now,
                                      sunrise: primarySolar.sunrise,
                                      sunset: primarySolar.sunset,
                                      solarNoon: nil,
                                      daylightDuration: nil)

        var auxiliary: [FieldPatch] = []
        var missingFields: Set<WeatherFieldKey> = []

        // 失败隔离：自带调用、catch 只置本槽位、不 rethrow、不连累主链路。
        for source in sources where source.capabilities.contains(.solarEvents) {
            do {
                let patch = try await source.fetchFields(latitude: city.latitude,
                                                         longitude: city.longitude,
                                                         capabilities: [.solarEvents],
                                                         now: now)
                await health.recordSuccess(source.id, at: now)
                auxiliary.append(patch)
                for field in source.requiredFields where isFieldNil(patch, field) {
                    missingFields.insert(field)
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

        // EV-1：必填缺失计数（仅辅助源）。
        if !missingFields.isEmpty {
            _ = await health.recordMissingFields(.sunriseSunset, missing: missingFields, at: now)
        }

        // 逐字段合并（纯函数：主源非 nil 绝不被覆盖、绝不平均）。
        let (merged, provenance) = FieldFallbackResolver.merge(primary: primaryPatch, auxiliary: auxiliary)
        self.solarOverlay = merged
        self.solarProvenance = provenance

        // 分歧量（主备同字段皆非 nil 且差异 > 60s 视为分歧，诊断用）。
        self.divergence = Self.computeDivergence(primary: primarySolar, merged: merged)

        // L1 归因：字段级降级 = 任一字段由备源补齐（provenance 标记 .fallback）。
        let hasFallback = !provenance.degradedFields.isEmpty
        let attr = SourceAttribution(primarySourceID: .openMeteoForecast,
                                     hasFieldFallback: hasFallback,
                                     at: now)
        self.attribution = attr
        attributionStore.record(primaryID: .openMeteoForecast, hasFieldFallback: hasFallback, at: now)
    }

    // MARK: - Private

    /// 清空覆盖层并仅记录主源归因（时区未知 / 摘除 / 冷却等路径）。
    private func applyEmptyOverlay(now: Date) {
        self.solarOverlay = nil
        self.solarProvenance = nil
        self.divergence = nil
        let attr = SourceAttribution(primarySourceID: .openMeteoForecast, hasFieldFallback: false, at: now)
        self.attribution = attr
        attributionStore.record(primaryID: .openMeteoForecast, hasFieldFallback: false, at: now)
    }

    /// 判断某字段在补丁中是否为 nil（requiredFields 仅需检查 solar 四格）。
    private func isFieldNil(_ patch: FieldPatch, _ key: WeatherFieldKey) -> Bool {
        switch key {
        case .sunrise: return patch.sunrise == nil
        case .sunset: return patch.sunset == nil
        case .solarNoon: return patch.solarNoon == nil
        case .daylightDuration: return patch.daylightDuration == nil
        default: return false
        }
    }

    /// 主备分歧量：主源与合并结果同字段皆非 nil 且差 > 60s。
    private static func computeDivergence(primary: PrimarySolarInput, merged: FieldPatch) -> SolarDivergence? {
        var result = SolarDivergence()
        if let p = primary.sunrise, let a = merged.sunrise, abs(p.timeIntervalSince(a)) > 60 {
            result.sunriseDiffSeconds = p.timeIntervalSince(a)
        }
        if let p = primary.sunset, let a = merged.sunset, abs(p.timeIntervalSince(a)) > 60 {
            result.sunsetDiffSeconds = p.timeIntervalSince(a)
        }
        guard result.sunriseDiffSeconds != nil || result.sunsetDiffSeconds != nil else { return nil }
        return result
    }
}

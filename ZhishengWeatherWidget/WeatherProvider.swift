//
//  WeatherProvider.swift
//  ZhishengWeatherWidget（Widget target）
//
//  AppIntentTimelineProvider（F-C：由 TimelineProvider 升级，结构不变）：
//  **L0 共享容器本地优先；L0 未命中时 L1 自力取数（至多 1 次、8s 有界）；
//  L2 如实空态**。刷新策略用 `.after(now + 45min)`（而非 `.atEnd`），
//  避免超出系统刷新预算。
//
//  ⚠️ 前提修订（原文件头「全程无网络、无同步阻塞调用」**作废**，被
//  docs/handover/ARCH-zhisheng-ios-widget-selfsufficiency.md 取代）：
//  CI 出的是**完全未签名** IPA → entitlements 不生效 → App Group 容器在侧载
//  产物上**永远不可用** → 旧架构（只读共享容器）结构性死亡。故小组件改为
//  自己取数；「全程无网络」这条前提**不再成立**，保留的是**执行预算纪律**：
//    · 常见路径（容器有归属数据）→ **零网络**；
//    · 每条时间线**至多一次**请求，且仅在 L0 完全未命中且有城市时发起；
//    · 8s 请求超时 + 10s 硬上限（`WidgetDataResolver.fetchBudget`）；
//    · `snapshot(for:)`（画廊 / 瞬时预览）**不联网**。
//
//  本文件是**薄编排层**：只做「取值 + 组装」，一切判定（城市阶梯 / 数据阶梯 /
//  文案）都在 Core 的纯函数里（`WidgetCityResolver` / `WidgetDataResolver` /
//  `WidgetCopy`）—— Widget target 不进测试包，写在这里的逻辑 CI 无法单测
//  （CI-pitfalls P-18 同源盲区）。
//
//  网络配置的唯一真源在 Core：`WidgetWeatherService`（8s ephemeral 会话）。
//  本文件**不出现任何网络符号**（`qa-static-check.sh` SC-40 纪律，见该文件说明）。
//
//  iOS 16 兼容（任务 B）：`containerBackground(for: .widget)` 是 iOS 17 API。
//  iOS 16 上小组件**没有** containerBackground，系统对时间线视图的渲染路径
//  与 17 不同（系统仍会自行裁圆角），此时改为：
//    1. 保持 `.after` 45 分钟常规刷新；
//    2. 追加一条 30 分钟处的兜底条目（双条目 Timeline）。
//  本轮**收紧**：两条目复用**同一份** resolution（旧实现会二次读容器；现在既不
//  二次读容器、更不二次取数）—— 每轮请求数上界因此严格是 1。
//  View 层的 `#available` 分支只解决「怎么画」，Provider 层的判断解决
//  「要不要按旧系统调整时间线」，两处判据同源于 `WidgetRuntime`。
//

import WidgetKit
import Foundation

/// 小组件时间线提供者。
struct WeatherProvider: AppIntentTimelineProvider {

    private let store: AppGroupStore
    private let weather: WeatherProviding

    /// 初始化。
    /// - Parameters:
    ///   - store: 共享容器读取器（widget 进程只用其读路径）。
    ///   - weather: 取数器；默认注入**短超时会话**的 `WeatherService`
    ///     （Core 的 `WidgetWeatherService`，8s + 不等待连通性）。测试可注入 Fake。
    init(store: AppGroupStore = AppGroupStore(),
         weather: WeatherProviding = WidgetWeatherService.makeDefault()) {
        self.store = store
        self.weather = weather
    }

    /// 占位条目（系统首次渲染 / 画廊预览）；示例数据路径不变。
    func placeholder(in context: Context) -> WeatherEntry {
        WeatherEntry(date: Date(), resolution: .placeholder)
    }

    /// 快速快照（画廊 / 瞬时展示）：**只走 L0，不联网**（避免昂贵 IO 与配额）。
    func snapshot(for configuration: WidgetCitySelectionIntent,
                  in context: Context) async -> WeatherEntry {
        let now = Date()
        let resolution = await makeResolution(configuration: configuration,
                                              now: now,
                                              allowNetwork: false)
        return WeatherEntry(date: now,
                            resolution: resolution,
                            backgroundStyle: configuration.backgroundStyle)
    }

    /// 生成时间线（**单次数据阶梯**，至多 1 次请求）。
    ///
    /// - iOS 17+：单条目 + `.after(now + 45min)`。
    /// - iOS 16 ：两条目（现在、+30min）+ `.after(now + 45min)`；
    ///   两条目**复用同一份 resolution**（不二次读容器、不二次取数）。
    func timeline(for configuration: WidgetCitySelectionIntent,
                  in context: Context) async -> Timeline<WeatherEntry> {
        let now = Date()
        // 唯一的阶梯调用点：一次 timeline = 至多一次网络请求。
        let resolution = await makeResolution(configuration: configuration,
                                              now: now,
                                              allowNetwork: true)

        // 45 分钟后请求下一次刷新；主 App 每次成功取数后也会 reloadAllTimelines() 提前刷新。
        let refreshDate = now.addingTimeInterval(45 * 60)

        let entries: [WeatherEntry]
        if WidgetRuntime.isIOS17OrLater {
            // 主路径：containerBackground 可用，单条目即可。
            entries = [WeatherEntry(date: now,
                                    resolution: resolution,
                                    backgroundStyle: configuration.backgroundStyle)]
        } else {
            // iOS 16 降级路径：追加中途条目让展示至少每 30 分钟对齐一次；
            // 复用同一份 resolution（无第二次读取、无第二次取数）。
            entries = [
                WeatherEntry(date: now,
                             resolution: resolution,
                             backgroundStyle: configuration.backgroundStyle),
                WeatherEntry(date: now.addingTimeInterval(30 * 60),
                             resolution: resolution,
                             backgroundStyle: configuration.backgroundStyle)
            ]
        }

        // 失败也照常返回（哪怕只有一个空态条目）；**绝不**返回空 Timeline（会触发系统异常渲染）。
        return Timeline(entries: entries, policy: .after(refreshDate))
    }

    // MARK: - 唯一组装入口（snapshot / timeline 共用）

    /// 组装本实例的收敛值：城市阶梯（纯本地）→ 数据阶梯（L0 → L1 → L2）。
    ///
    /// ① 城市阶梯读的是**原始容器**（`WidgetCityCatalog.rawCities`：
    ///    missing / corrupt → 空数组），**绝不**经 `CityDirectory.initial()` 兜底
    ///    —— 那是「幽灵北京」的来源（把防御性默认城市冒充成用户的城市归属）。
    /// ② 数据阶梯在 Core（`WidgetDataResolver`），失败一律收敛为 entry，不抛错。
    ///
    /// - Parameters:
    ///   - configuration: 系统按实例持久化的配置 Intent。
    ///   - now: 当前时刻（注入给 Core 的新鲜度判定，Core 禁内部 `Date()`）。
    ///   - allowNetwork: 是否允许 L1 自力取数（`snapshot` 传 false）。
    /// - Returns: 城市 + 载荷 + 状态 + 来源 + 空因的收敛值。
    private func makeResolution(configuration: WidgetCitySelectionIntent,
                                now: Date,
                                allowNetwork: Bool) async -> WidgetEntryResolution {
        let container = WidgetContainerSnapshot(
            cities: WidgetCityCatalog.rawCities(from: store.loadCities()),
            selectedID: store.selectedCityID,
            containerAvailable: AppGroupStore.isSharedContainerAvailable)

        let selection = WidgetCitySelection(id: configuration.city.id,
                                            name: configuration.city.name,
                                            subtitle: configuration.city.subtitle)

        let cityOutcome = WidgetCityResolver.resolveOutcome(selection: selection,
                                                            container: container,
                                                            builtIn: WidgetBuiltInCities.cities)

        return await WidgetDataResolver.resolve(cityOutcome: cityOutcome,
                                                containerAvailable: container.containerAvailable,
                                                loadResult: store.loadResult(),
                                                now: now,
                                                allowNetwork: allowNetwork,
                                                weather: weather)
    }
}

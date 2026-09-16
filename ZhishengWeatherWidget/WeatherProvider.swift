//
//  WeatherProvider.swift
//  ZhishengWeatherWidget（Widget target）
//
//  AppIntentTimelineProvider（F-C：由 TimelineProvider 升级，结构不变）：
//  从 App Group 共享容器**只读**加载数据并生成时间线。
//  刷新策略用 `.after(now + 45min)`（而非 `.atEnd`），避免超出系统刷新预算。
//
//  F-C 单实例 entry 构造（makeEntry，四步，§2.4）：
//    1. directory = CityDirectory.loadReadOnly(from:)（纯本地，三态不落盘）；
//    2. city = WidgetCityResolver.resolve(mode(forEntityID:), directory:)；
//    3. payload 归属校验（R-C2）：仅当 City.makeID(snapshot.location) == city.id
//       才随 entry 下发，否则 payload 置 nil → 渲染"城市名 + --° + 暂无数据"
//       （AC-C6，不冒充）；
//    4. 全程无网络、无同步阻塞调用（UserDefaults 读为可接受本地 IO）。
//
//  iOS 16 兼容（任务 B）：`containerBackground(for: .widget)` 是 iOS 17 API。
//  iOS 16 上小组件**没有** containerBackground，系统对时间线视图的渲染路径
//  与 17 不同（系统仍会自行裁圆角），此时改为：
//    1. 保持 `.after` 45 分钟常规刷新；
//    2. 追加一条 30 分钟处的兜底条目（双条目 Timeline，见下）。
//  View 层的 `#available` 分支只解决「怎么画」，Provider 层的判断解决
//  「要不要按旧系统调整时间线」，两处判据同源于 `WidgetRuntime`。
//

import WidgetKit
import Foundation

/// 小组件时间线提供者。
struct WeatherProvider: AppIntentTimelineProvider {

    private let store: AppGroupStore

    init(store: AppGroupStore = AppGroupStore()) {
        self.store = store
    }

    /// 占位条目（系统首次渲染 / 画廊预览）；city 传 nil（示例数据路径不变）。
    func placeholder(in context: Context) -> WeatherEntry {
        WeatherEntry(date: Date(), payload: .placeholder, city: nil)
    }

    /// 快速快照（画廊 / 瞬时展示）。
    func snapshot(for configuration: WidgetCitySelectionIntent,
                  in context: Context) async -> WeatherEntry {
        makeEntry(date: Date(), configuration: configuration)
    }

    /// 生成时间线。
    ///
    /// - iOS 17+：单条目 + `.after(now + 45min)`。
    /// - iOS 16 ：两条目（现在、+30min）+ `.after(now + 45min)`。
    ///   旧系统上「更新于 HH:mm」文案不会随共享数据变化自动刷新，
    ///   追加一条中间条目让展示至少每 30 分钟对齐一次数据。
    ///
    /// （F-C：仅把"读一份 payload"替换为 `makeEntry`；双条目分支与刷新策略逐行保留。）
    func timeline(for configuration: WidgetCitySelectionIntent,
                  in context: Context) async -> Timeline<WeatherEntry> {
        let now = Date()

        // 45 分钟后请求下一次刷新；主 App 每次成功取数后也会 reloadAllTimelines() 提前刷新。
        let refreshDate = now.addingTimeInterval(45 * 60)

        let entries: [WeatherEntry]
        if WidgetRuntime.isIOS17OrLater {
            // 主路径：containerBackground 可用，单条目即可。
            entries = [makeEntry(date: now, configuration: configuration)]
        } else {
            // iOS 16 降级路径：追加中途条目，重新读取共享容器，
            // 让「更新于 HH:mm」在两次系统刷新之间也能跟上主 App 的写入。
            let midEntry = makeEntry(date: now.addingTimeInterval(30 * 60),
                                     configuration: configuration)
            entries = [makeEntry(date: now, configuration: configuration), midEntry]
        }

        return Timeline(entries: entries, policy: .after(refreshDate))
    }

    // MARK: - 单实例 entry 构造（snapshot 与 timeline 共用）

    /// 按本实例配置构造 entry（四步见文件头；纯本地读，无网络无阻塞）。
    ///
    /// - Parameters:
    ///   - date: 条目时间。
    ///   - configuration: 系统按实例持久化的配置 Intent。
    /// - Returns: 目标城市 + 归属校验后的 entry。
    private func makeEntry(date: Date, configuration: WidgetCitySelectionIntent) -> WeatherEntry {
        // ① 只读载入目录（missing / corrupt → 内存 initial，不落盘）。
        let directory = CityDirectory.loadReadOnly(from: store)

        // ② 配置模式 → 目标城市（fixed 已删/坏值 → 自动回退 followApp，AC-C5）。
        let city = WidgetCityResolver.resolve(
            WidgetCityResolver.mode(forEntityID: configuration.city.id),
            directory: directory)

        // ③ 快照归属校验（R-C2 / AC-C6）：共享容器只有一份快照，
        //    仅当它确实属于本实例目标城市（规范化坐标 id 相等）才下发；
        //    不匹配 / 无快照 → payload 置 nil，绝不拿其他城市数据冒充。
        let payload: SharedWeatherPayload?
        if let city,
           let loaded = store.load(),
           city.id == City.makeID(latitude: loaded.snapshot.location.latitude,
                                  longitude: loaded.snapshot.location.longitude) {
            payload = loaded
        } else {
            payload = nil
        }

        // ④ 构造 entry（无网络、无同步阻塞调用）。
        return WeatherEntry(date: date, payload: payload, city: city,
                            backgroundStyle: configuration.backgroundStyle)
    }
}

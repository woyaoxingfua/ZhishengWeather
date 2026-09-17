//
//  HomeSection.swift
//  ZhishengWeather（主 App target）
//
//  主屏区块排序/隐藏（A2-7，ARCH-A2P1 后续批）：
//   - 区块枚举 + UserDefaults 持久化（**不放共享容器**——小组件不感知，AC-A2-23）；
//   - Hero 与页脚**不参与**排序/隐藏（始终显示，AC-A2-21 例外条款）；
//   - 隐藏 = 从顺序表中移除；"恢复默认" = 清除 UserDefaults 键。
//
//  存储设计：`[String]`（原始顺序的子集排列）。崩溃/半写防护：读取时对
//  未知标识与缺失区块做**补齐回默认位**（新加区块天然出现在默认位置）。
//
//  store 纪律（对齐 IconChoicePreference）：**store 是实例依赖，读与写必须绑
//  同一个实例**（默认 `.standard`，单测注入独立 suite `zs.test.homeSection.<UUID>`）。
//  ContentView 保留的 static 调用点只是**默认实例的薄壳转发**，不另存 store。
//

import Foundation

/// 主屏可排序/可隐藏区块（顺序 = 主屏默认顺序）。
enum HomeSection: String, CaseIterable, Identifiable, Sendable {
    case yesterday      // A1-5 昨日对比行
    case metrics        // 指标格（风速/湿度/气压）
    case airQuality     // A2-1 空气卡
    case hourly         // 逐时预报
    case daily          // 逐日预报
    case lifeIndex      // A2-3 生活指数
    case moon           // 月相 + 日出日落 + 月出月落

    /// Identifiable（主屏 ForEach 排序渲染用）。
    var id: String { rawValue }

    /// UserDefaults 存储键（主 App 本地，非共享容器）。
    static let storageKey = "zs.weather.homeSections"

    /// 默认顺序（= CaseIterable 声明顺序）。
    static var defaultOrder: [HomeSection] { allCases }
}

/// 主屏区块顺序管理（读写绑注入的 store）。
@MainActor
struct HomeSectionOrder {

    /// 读写共用的存储实例（构造时一次性选定，任何分支都不得绕开）。
    private let defaults: UserDefaults

    /// - Parameter defaults: 读写共用的存储（App 用 `.standard`，AC-A2-23：
    ///   非共享容器）；单测注入独立 suite 以隔离。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 读取当前顺序（含用户隐藏的区块——返回全量排序；隐藏与否由调用方过滤）。
    /// 读取失败 / 存了未知标识 / 缺失新区块 → 补齐回默认位（防旧数据裁剪新功能）。
    func current() -> [HomeSection] {
        guard let raw = defaults.stringArray(forKey: HomeSection.storageKey) else {
            return HomeSection.defaultOrder
        }
        let saved = raw.compactMap(HomeSection.init(rawValue:))
        // 补齐：默认顺序中不在 saved 里的区块，追加到尾部（新版本新增区块不丢失）。
        let missing = HomeSection.defaultOrder.filter { !saved.contains($0) }
        let result = saved + missing
        // 校验：必须恰好包含全部区块（去重后数量一致），否则回默认。
        guard Set(result).count == HomeSection.defaultOrder.count else {
            return HomeSection.defaultOrder
        }
        return result
    }

    /// 保存顺序（全量，含已隐藏项——隐藏状态另由隐藏集合管理，见 `hidden()`）。
    func save(_ order: [HomeSection]) {
        defaults.set(order.map(\.rawValue), forKey: HomeSection.storageKey)
    }

    /// 读取隐藏集合。
    func hidden() -> Set<HomeSection> {
        guard let raw = defaults.stringArray(forKey: HomeSection.storageKey + ".hidden") else {
            return []
        }
        return Set(raw.compactMap(HomeSection.init(rawValue:)))
    }

    /// 保存隐藏集合。
    func saveHidden(_ hidden: Set<HomeSection>) {
        defaults.set(hidden.map(\.rawValue).sorted(),
                     forKey: HomeSection.storageKey + ".hidden")
    }

    /// 恢复默认（清两个键，AC-A2-22）。
    func reset() {
        defaults.removeObject(forKey: HomeSection.storageKey)
        defaults.removeObject(forKey: HomeSection.storageKey + ".hidden")
    }

    // MARK: - 生产默认实例（static 便捷 API 的薄壳）
    //
    // ContentView 的调用点保持 `HomeSectionOrder.current()` 形态不变，但全部转发
    // 到**同一个默认实例**（App 本地 `.standard`）。这里不另存 store。

    /// 生产默认实例（App 本地标准 UserDefaults）。
    private static let shared = HomeSectionOrder()

    static func current() -> [HomeSection] { shared.current() }
    static func save(_ order: [HomeSection]) { shared.save(order) }
    static func hidden() -> Set<HomeSection> { shared.hidden() }
    static func saveHidden(_ hidden: Set<HomeSection>) { shared.saveHidden(hidden) }
    static func reset() { shared.reset() }
}

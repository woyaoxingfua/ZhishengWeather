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

import Foundation

/// 主屏可排序/可隐藏区块（顺序 = 主屏默认顺序）。
enum HomeSection: String, CaseIterable, Sendable {
    case yesterday      // A1-5 昨日对比行
    case metrics        // 指标格（风速/湿度/气压）
    case airQuality     // A2-1 空气卡
    case hourly         // 逐时预报
    case daily          // 逐日预报
    case lifeIndex      // A2-3 生活指数
    case moon           // 月相 + 日出日落 + 月出月落

    /// UserDefaults 存储键（主 App 本地，非共享容器）。
    static let storageKey = "zs.weather.homeSections"

    /// 默认顺序（= CaseIterable 声明顺序）。
    static var defaultOrder: [HomeSection] { allCases }
}

/// 主屏区块顺序管理（读 UserDefaults，进程内缓存）。
@MainActor
enum HomeSectionOrder {

    /// 读取当前顺序（含用户隐藏的区块——返回全量排序；隐藏与否由调用方过滤）。
    /// 读取失败 / 存了未知标识 / 缺失新区块 → 补齐回默认位（防旧数据裁剪新功能）。
    static func current() -> [HomeSection] {
        let defaults = UserDefaults.standard
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

    /// 保存顺序（全量，含已隐藏项——隐藏状态另由隐藏集合管理，见 `hidden`）。
    static func save(_ order: [HomeSection]) {
        UserDefaults.standard.set(order.map(\.rawValue), forKey: HomeSection.storageKey)
    }

    /// 读取隐藏集合。
    static func hidden() -> Set<HomeSection> {
        let defaults = UserDefaults.standard
        guard let raw = defaults.stringArray(forKey: HomeSection.storageKey + ".hidden") else {
            return []
        }
        return Set(raw.compactMap(HomeSection.init(rawValue:)))
    }

    /// 保存隐藏集合。
    static func saveHidden(_ hidden: Set<HomeSection>) {
        UserDefaults.standard.set(hidden.map(\.rawValue).sorted(),
                                  forKey: HomeSection.storageKey + ".hidden")
    }

    /// 恢复默认（清两个键，AC-A2-22）。
    static func reset() {
        UserDefaults.standard.removeObject(forKey: HomeSection.storageKey)
        UserDefaults.standard.removeObject(forKey: HomeSection.storageKey + ".hidden")
    }
}

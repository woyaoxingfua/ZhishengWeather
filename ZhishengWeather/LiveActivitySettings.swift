//
//  LiveActivitySettings.swift
//  ZhishengWeather（主 App target）
//
//  实时活动开关的持久化：**App 本地标准 UserDefaults**，不进 App Group 共享容器。
//
//  为什么不进共享容器：本开关只表达「用户想不想看实时活动」，是**主 App 的
//  意图**；小组件侧不读它（实时活动的渲染由系统在 Widget 扩展里驱动，
//  与本开关无读写关系）。塞进共享容器只会制造一处无人消费的写入。
//
//  store 纪律（对齐 AppearancePreference / IconChoicePreference）：
//  store 是**实例依赖**，读与写必须绑同一个实例 —— 本仓库踩过「读注入、
//  写 standard」的半条注入缝（CI run 35206149080），故本类型**不提供**
//  任何 static 读写便捷 API，唯一入口是绑定 store 的实例方法；
//  键名 `key` 与 store 无关，保持 static。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 实时活动开关持久化（App 本地）。
struct LiveActivitySettings {

    /// 持久化键（App 本地；**不放** App Group 共享容器）。
    static let key: String = "zs.weather.liveActivityEnabled"

    /// 读写共用的存储实例（构造时一次性选定，任何分支都不得绕开）。
    private let defaults: UserDefaults

    /// - Parameter defaults: 读写共用的存储（App 用 `.standard`；
    ///   单测注入 `UserDefaults(suiteName: "zs.test.liveactivity.<UUID>")` 以隔离）。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 开关是否开启（**缺省为关**）。
    ///
    /// 为什么默认关：实时活动在侧载（重签）渠道上的可用性未知，而且它会在
    /// 锁屏/灵动岛长期占位。默认打开等于替用户做了一个可能无效、且显眼的
    /// 决定；开启应由用户显式选择。`bool(forKey:)` 在键缺失时返回 false，
    /// 缺省行为天然就是「关」，无需再判 `object(forKey:) == nil`。
    var isEnabled: Bool {
        defaults.bool(forKey: Self.key)
    }

    /// 写入开关（写**本实例绑定的** store）。
    ///
    /// - Parameter enabled: 目标状态。
    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.key)
    }
}

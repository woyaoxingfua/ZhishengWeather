//
//  WeatherActivityAttributes.swift
//  ZhishengWeather（Core：主 App 与 Widget 双 target 共享）
//
//  实时活动（ActivityKit）的数据契约：静态属性（活动生命周期内不变）+
//  动态内容状态（可随 update 变化）。
//
//  为什么住在 Core（**本文件由 `ZhishengWeather/` 迁入的理由**）：
//  - 实时活动的 **UI 渲染在 Widget 扩展里** —— Widget 侧的 `WeatherLiveActivity`
//    提供 `ActivityConfiguration`，系统启动活动时按这份 configuration 渲染
//    锁屏横幅与灵动岛。而 Core 是主 App 与 Widget 两个 target 的**共享源码目录**，
//    活动契约必须**两侧同构**：
//    · 契约只在 App 侧 → Widget 侧无 UI 可渲染，活动能 `Activity.request`
//      启动、用户却永远看不到任何内容（有类型、无渲染的半截状态）；
//    · 契约只在 Widget 侧 → App 侧无法启动活动。
//    故本文件迁入 Core：一次声明、两侧可见；`project.yml` 无需改动
//    （Core 已在两个 target 的 sources 里）。
//
//  纪律：
//  - **字段一律可空**：没有真实数据就是 nil，由 UI 侧渲染占位符。
//    **绝不用「26°」「晴」这类假数据把空态填成满屏** —— 伪数据比空态更糟，
//    用户会以为真的取到了数。
//  - **城市名不落任何默认值**：城市名缺失就是 nil，由 UI 侧渲染「—」；
//    绝不允许出现未经用户选择的城市名，也不在默认值里写死任何城市。
//  - **时间由调用方传入**：更新时间是**文案**（调用方按城市时区格式化后传入），
//    本文件不自行 `Date()`，与 Core 的「时间可注入」同款纪律。
//  - 仅 import ActivityKit + Foundation（不引 UIKit；Core 同时进 Widget target）。
//

import ActivityKit
import Foundation

/// 实时活动的静态属性（活动创建后不再变化的部分）。
///
/// `cityID` 是「同一城市重复启动」的幂等判据：同 ID 走更新、异 ID 先结束后新建，
/// 避免用户来回切设置开关时灵动岛上叠出多个活动。
struct WeatherActivityAttributes: ActivityAttributes {

    /// 城市稳定标识（无城市数据时填 `unknownCityID`）。
    var cityID: String

    /// 未知城市的标识常量（单一真源；避免各处散落 "unknown" 字面量）。
    ///
    /// 为什么不用空串：空串与「有城市但名字为空」在排查时无法区分，
    /// 显式常量让日志与诊断里一眼看出「调用方没给城市」。
    static let unknownCityID: String = "unknown"

    /// 实时活动的动态内容（每次 `update` 可整体替换）。
    ///
    /// 全部字段可空：**无数据即 nil**，由渲染侧决定占位符样式。
    struct ContentState: Codable, Hashable {

        /// 城市名（用户所选城市的展示名；无数据为 nil，UI 侧渲染「—」）。
        var cityName: String?

        /// 温度文案（由调用方按单位偏好格式化后传入；无数据为 nil）。
        var temperatureText: String?

        /// 天气描述文案（由调用方经 WMO 码映射后传入；无数据为 nil）。
        var conditionText: String?

        /// 更新时间文案（由调用方按城市时区格式化后传入；无数据为 nil）。
        var updatedAtText: String?
    }
}

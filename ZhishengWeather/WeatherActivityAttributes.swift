//
//  WeatherActivityAttributes.swift
//  ZhishengWeather（主 App target）
//
//  实时活动（ActivityKit）的数据契约：静态属性（活动生命周期内不变）+
//  动态内容状态（可随 update 变化）。
//
//  纪律：
//  - **仅 App target，不进 Core**：Core 被主 App 与 Widget 共用，而本轮
//    Widget 扩展**不提供** `ActivityConfiguration`（实时活动的 UI 不在本轮范围），
//    把活动类型塞进 Core 会让 Widget 侧出现「有类型、无 UI」的半截契约。
//  - **字段一律可空**：没有真实数据就是 nil，由 UI 侧渲染占位符。
//    **绝不用「26°」「晴」这类假数据把空态填成满屏** —— 伪数据比空态更糟，
//    用户会以为真的取到了数。
//  - **时间由调用方传入**：更新时间是**文案**（调用方按城市时区格式化后传入），
//    本文件不自行 `Date()`，与 Core 的「时间可注入」同款纪律。
//  - 仅 import ActivityKit + Foundation（不引 UIKit）。
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

        /// 城市名（如「北京」；无数据为 nil）。
        var cityName: String?

        /// 温度文案（如「26°」；无数据为 nil）。
        var temperatureText: String?

        /// 天气描述文案（如「多云」；无数据为 nil）。
        var conditionText: String?

        /// 更新时间文案（由调用方按城市时区格式化后传入；无数据为 nil）。
        var updatedAtText: String?
    }
}

//
//  WidgetWeatherService.swift
//  Core / Networking  [App + Widget 共用]
//
//  小组件自力取数（L1）的**短超时** `WeatherService` 工厂。
//
//  为什么放在 Core 而不是 Widget target（**有意偏差**，ARCH §6.2 伪代码把它写在
//  `WeatherProvider.swift`）：
//    1. `qa-static-check.sh` 的 **SC-40** 明令 widget 目录零网络符号
//       （`URLSession` / `dataTask` / `NSURLRequest` / `dataTaskPublisher`）。
//       本服务**只被小组件时间线取数**路径使用（`WidgetDataResolver`）；
//       **配置解析路径零网络**（AC-C8 / 真机判据 F-C-8；「配置解析」范围澄清见
//       PRD-zhisheng-ios-P1.md §4.7，及 AC-C17 的「经 Core service 间接联网同等违规」）——
//       故网络类型引用不应散落在 Widget target；
//    2. 把「一个短超时会话 + 一个 WeatherService」的构造收进 Core，网络配置
//       只有**一处**真源（将来调超时只改这里），Widget 侧只引用 `WeatherService`
//       这一类型名（不出现任何网络符号）。
//
//  超时取值（ARCH §9）：8 秒。理由：小组件时间线预算有限；8s 足够一次
//  Open-Meteo 请求（正常 < 1s），又能快速失败转入 L2。外层另有 10s 硬上限
//  （`WidgetDataResolver.fetchBudget`）兜底。
//
//  `waitsForConnectivity = false`：无网络时**立即失败**，绝不挂起等待
//  （等待会吃光小组件执行预算）。`ephemeral`：不落磁盘缓存，避免在扩展进程里
//  持有一份无人清理的 URL 缓存。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 小组件取数用的短超时会话与 `WeatherService` 工厂。
enum WidgetWeatherService {

    /// 请求 / 资源超时（秒）。与 `WidgetDataResolver.fetchBudget`（10s 硬上限）
    /// 配套：本值必须先于硬上限触发，才能让 `WeatherService` 内部把
    /// `URLError.timedOut` 细分为 `WeatherError.timeout`。
    static let requestTimeout: TimeInterval = 8

    /// 构造小组件专用短超时会话。
    /// - Returns: `ephemeral` + 8s 超时 + 不等待网络连通性的 `URLSession`。
    static func makeShortTimeoutSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// 生产默认取数器（复用既有 `WeatherService`，**零新增映射代码**）。
    /// - Returns: 注入短超时会话的 `WeatherService`。
    static func makeDefault() -> WeatherProviding {
        WeatherService(session: makeShortTimeoutSession())
    }
}

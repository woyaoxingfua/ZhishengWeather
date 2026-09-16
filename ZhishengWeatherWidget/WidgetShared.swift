//
//  WidgetShared.swift
//  ZhishengWeatherWidget（Widget target）
//
//  Widget 各尺寸视图共用的**时区感知**格式化工具。
//
//  D-4（异地城市时区）Widget 侧补齐——**决策与理由（写入提交信息）**：
//  1. Core 的 `WeatherTimeFormatter` 整体 `@MainActor`（其缓存是主 actor 不变式，
//     commit 4709054 刻意钉住）。而 Widget 视图的**计算属性在 Xcode 15.4 下非隔离**
//     （`View` 协议未整体 MainActor 化，见 CI-pitfalls P-06），从非隔离上下文调用
//     主 actor 成员是**硬编译错误**。
//  2. 故 Widget **走自己的非隔离路径**（本类型），而非把三个 widget 视图整体改标
//     `@MainActor`——后者会牵动成员初始化器隔离，面更大、更易在 CI 上失控。
//  3. 时区**裁定**仍复用 `WeatherTimeFormatter.resolveTimeZone`（已声明 `nonisolated`，
//     单一真源）；仅**格式化**在本类型内以**锁保护的 (格式, 时区) 缓存**完成
//     （`DateFormatter` 非线程安全，且禁止逐行新建）。
//
//  纪律：Core 的时区裁定语义（nil / 非法 → 设备时区）在此**不重复实现**，直接委托。
//

import Foundation

/// Widget 展示用格式化器集合（**非隔离** + 时区感知 + 缓存复用）。
enum WidgetTimeFormatter {

    /// 保护 `cache` 的互斥锁（`DateFormatter` 非线程安全）。
    private static let lock = NSLock()
    /// (格式 | 已解析时区标识) → 复用实例。
    private static var cache: [String: DateFormatter] = [:]

    // MARK: - 时区裁定（复用 Core 单一真源）

    /// 解析共享载荷携带的城市时区；缺省 / 非法 → **设备时区**（绝不硬编码偏移）。
    /// - Parameter payload: 共享容器载荷；nil 或无 `timeZoneIdentifier` 键 → 设备时区。
    /// - Returns: 城市时区，缺省回退 `.current`。
    static func timeZone(for payload: SharedWeatherPayload?) -> TimeZone {
        WeatherTimeFormatter.resolveTimeZone(identifier: payload?.timeZoneIdentifier)
    }

    // MARK: - 格式化（缓存复用，不逐行新建）

    /// 「14:05」。
    static func hourMinute(_ date: Date, in timeZone: TimeZone) -> String {
        string(from: date, format: "HH:mm", timeZone: timeZone)
    }

    /// 「14时」（Large 逐时趋势列）。
    static func hourLabel(_ date: Date, in timeZone: TimeZone) -> String {
        string(from: date, format: "HH时", timeZone: timeZone)
    }

    /// 「9月11日」。
    static func monthDay(_ date: Date, in timeZone: TimeZone) -> String {
        string(from: date, format: "M月d日", timeZone: timeZone)
    }

    /// 「9月11日 周四」。
    static func monthDayWeekday(_ date: Date, in timeZone: TimeZone) -> String {
        string(from: date, format: "M月d日 EEEE", timeZone: timeZone)
    }

    /// 「周三」（Large 逐日列星期标签）。
    static func weekdayShort(_ date: Date, in timeZone: TimeZone) -> String {
        string(from: date, format: "EEE", timeZone: timeZone)
    }

    /// 按指定时区 + 格式格式化（缓存复用版 `DateFormatter.string(from:)`）。
    /// - Parameters:
    ///   - date: 待格式化的绝对时刻。
    ///   - format: `dateFormat` 模式串。
    ///   - timeZone: 目标时区。
    /// - Returns: 格式化字符串。
    static func string(from date: Date, format: String, timeZone: TimeZone) -> String {
        formatter(format: format, timeZone: timeZone).string(from: date)
    }

    /// 取（或构造并缓存）指定格式 + 时区的 `DateFormatter`。
    ///
    /// 缓存键 = `格式 | 已解析时区标识`（规范化 `.current` 为具体实例，避免命中过期哨兵）。
    /// - Parameters:
    ///   - format: `dateFormat` 模式串。
    ///   - timeZone: 目标时区。
    /// - Returns: 可复用实例（同一 key 恒返回同一实例）。
    private static func formatter(format: String, timeZone: TimeZone) -> DateFormatter {
        let resolved = TimeZone(identifier: timeZone.identifier) ?? timeZone
        let key = format + "|" + resolved.identifier
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = resolved
        formatter.dateFormat = format
        cache[key] = formatter
        return formatter
    }
}

//
//  WeatherTimeFormatter.swift
//  Core / Logic  [App + Widget 共用]
//
//  D-4（异地城市时区）时区裁定 + 时间格式化的 Core 纯逻辑。
//
//  裁定（ARCH-zhisheng-ios-multi-source §6.2 D-4，方案 b）：
//  `WeatherSnapshot.location`（`LocationInfo`）**无时区字段**，故时区取自
//  **选中的 `City`**（`City.timeZoneIdentifier`）。缺省 / 非法 IANA 标识一律
//  回退 `.current`（设备时区），保持既有行为、绝不硬编码固定偏移。
//
//  缓存纪律：`DateFormatter` 按 (格式, 时区) 复用，**禁止逐行/逐次新建**。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 时间渲染的时区裁定与格式化（纯逻辑 + 格式器缓存）。
enum WeatherTimeFormatter {

    // MARK: - 纯裁定（无共享状态，可纯单测）

    /// IANA 标识 → `TimeZone`；nil / 非法标识 → 设备当前时区。
    /// - Parameter identifier: 例如 "Asia/Shanghai"、"America/New_York"。
    /// - Returns: 解析出的时区；无法解析时返回 `.current`（绝不崩、绝不硬编码 +8）。
    static func resolveTimeZone(identifier: String?) -> TimeZone {
        guard let identifier, let timeZone = TimeZone(identifier: identifier) else {
            return .current
        }
        return timeZone
    }

    /// 城市 → 时区；`city == nil`（无选中项）→ 设备当前时区。
    /// - Parameter city: 选中的城市；可为 nil。
    /// - Returns: 城市时区，缺省 / 非法回退 `.current`。
    static func timeZone(for city: City?) -> TimeZone {
        resolveTimeZone(identifier: city?.timeZoneIdentifier)
    }

    // MARK: - 带缓存的格式化

    /// 格式器缓存（键 = 格式 + 时区标识）。仅主线程（UI 渲染）访问。
    private static var formatterCache: [String: DateFormatter] = [:]

    /// 取（或构造并缓存）指定格式 + 时区的 `DateFormatter`。
    /// - Parameters:
    ///   - format: 例如 "HH:mm"、"M月d日 HH:mm"。
    ///   - timeZone: 目标时区。
    /// - Returns: 可复用的格式器实例（同一 (格式, 时区) 恒返回同一实例）。
    static func formatter(format: String, timeZone: TimeZone) -> DateFormatter {
        let key = format + "|" + timeZone.identifier
        if let cached = formatterCache[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        formatterCache[key] = formatter
        return formatter
    }

    /// 按指定时区 + 格式格式化时刻（时区化版 `DateFormatter.string(from:)`）。
    /// - Parameters:
    ///   - date: 待格式化的绝对时刻。
    ///   - format: 日期格式。
    ///   - timeZone: 目标时区。
    /// - Returns: 格式化字符串。
    static func string(from date: Date, format: String, timeZone: TimeZone) -> String {
        formatter(format: format, timeZone: timeZone).string(from: date)
    }
}

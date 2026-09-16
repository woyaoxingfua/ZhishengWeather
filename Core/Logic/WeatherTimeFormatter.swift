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
//  并发纪律：本类型整体 `@MainActor`（缓存是未加锁共享可变状态，且 `DateFormatter`
//  非线程安全）——由编译器强制"仅在主 actor 访问"，见下方类型注解。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 时间渲染的时区裁定与格式化（纯逻辑 + 格式器缓存）。
///
/// **@MainActor（并发不变式，编译期强制）**：`formatterCache` 是未加锁的共享可变
/// 状态，且 `DateFormatter` **非线程安全**。当前所有调用方（ContentView /
/// WeatherViewModel / 单测）本来就都在主 actor，故不存在实际竞态；但此前没有任何
/// 东西**约束**这一点——日后一旦从后台上下文误调，就是静默的数据竞争。标注本类型
/// 使编译器替我们守住这条不变式（越界调用直接编译失败，而非线上偶发崩溃）。
@MainActor
enum WeatherTimeFormatter {

    // MARK: - 纯裁定（无共享状态，可纯单测）

    /// IANA 标识 → `TimeZone`；nil / 非法标识 → 设备当前时区。
    ///
    /// **`nonisolated`**：本函数是**无共享状态的纯裁定**，显式脱离类型级 `@MainActor`，
    /// 供 **Widget target 的非隔离格式化路径**复用（Widget 视图计算属性在 Xcode 15.4 下
    /// 非隔离，不能调用主 actor 成员，见 CI-pitfalls P-06 / WidgetShared.swift 决策说明）。
    /// 格式化（触碰缓存）仍留在本类型的 `@MainActor` 侧。
    /// - Parameter identifier: 例如 "Asia/Shanghai"、"America/New_York"。
    /// - Returns: 解析出的时区；无法解析时返回 `.current`（绝不崩、绝不硬编码 +8）。
    nonisolated static func resolveTimeZone(identifier: String?) -> TimeZone {
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

    /// 格式器缓存（键 = 格式 + **已解析**时区标识）。仅主 actor 访问（见类型上的
    /// `@MainActor`，由编译器强制）。
    private static var formatterCache: [String: DateFormatter] = [:]

    /// 取（或构造并缓存）指定格式 + 时区的 `DateFormatter`。
    ///
    /// 缓存键 = `格式 | 已解析时区标识`。入参先被**规范化**为具体时区实例
    /// （`TimeZone(identifier:)`），以保证：
    ///   1. 键里存的是**解析后的标识**，而非 `.current` / `.autoupdatingCurrent`
    ///      这类自动更新哨兵——运行时切换系统时区会得到新标识 → 新键 →
    ///      新格式器，**绝不会命中过期实例**（沿用设备时区的调用方随之自动更新）；
    ///   2. 存入格式器的是不带自动更新语义的确定实例（`.current` 本身即快照，双保险）。
    /// - Parameters:
    ///   - format: 例如 "HH:mm"、"M月d日 HH:mm"。
    ///   - timeZone: 目标时区（可直接传 `.current`，内部会解析为具体实例）。
    /// - Returns: 可复用的格式器实例（同一 (格式, 已解析时区) 恒返回同一实例）。
    static func formatter(format: String, timeZone: TimeZone) -> DateFormatter {
        // 规范化为具体实例；极端情形下 `TimeZone(identifier:)` 返回 nil 则沿用入参。
        let resolvedTimeZone = TimeZone(identifier: timeZone.identifier) ?? timeZone
        let key = format + "|" + resolvedTimeZone.identifier
        if let cached = formatterCache[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = resolvedTimeZone
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

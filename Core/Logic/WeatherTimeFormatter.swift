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

    // MARK: - ISO8601 解析（容错）

    /// 🔴 **容错 ISO8601 解析**：依次尝试多个候选格式，返回第一个成功的。
    ///
    /// ══════════════════════════════════════════════════════════════════════
    /// ⚠️ **为什么不能用单个 `ISO8601DateFormatter` + `.withInternetDateTime`**
    /// ══════════════════════════════════════════════════════════════════════
    /// **实测（CI run#37758888046，`QWeatherHourlyTests.testHourTextRendersInGivenTimeZone`）**：
    /// `.withInternetDateTime` 要求串里**必须有秒**（`hh:mm:ss`），
    /// 而和风下发的逐时 / 逐日 `forecastTime` **实测是无秒的**：
    ///   · 逐时 `2026-10-08T15:00Z`  → **解析失败**
    ///   · 逐日 `2026-10-07T16:00Z`  → 同款形态（**同样失败，此前从未被测到**）
    /// → 表现为 `date(from:)` 返回 nil，代码如实退回**上游原始串**，
    ///   于是卡片上显示 `2026-10-08T15:00Z` 而不是 `23:00`。
    ///   这是**本项目「声明 ≠ 渲染 ≠ 用户可见」最典型的一次**：
    ///   类型签名、模型字段、单测全绿，只有真机渲染才暴露。
    ///
    /// ⚠️ 加 `.withFractionalSeconds` **也不对**（社区实测 + Apple 文档）：
    ///   那是为 `ss.sss`（带毫秒）准备的，加了反而**不再**解析无秒/无毫秒的形态。
    ///
    /// ══════════════════════════════════════════════════════════════════════
    /// → 故此处用 `DateFormatter` + **多格式回退链**，逐个试到成功为止。
    ///   覆盖 ISO8601 允许的四种常见形态（带/不带秒、带/不带毫秒），
    ///   外加 `+08:00` 数字时区偏移。
    /// ══════════════════════════════════════════════════════════════════════
    ///
    /// - Parameters:
    ///   - raw: 上游时刻**原始串**（例如 `2026-10-08T15:00Z`）。
    ///   - locale: 解析用 locale；nil → `en_US_POSIX`（🔴 **必须**固定，
    ///     否则在非公历 / 非拉丁数字 locale（如 `th_TH`、阿拉伯语）下
    ///     `yyyy`/`MM` 解析会被本地化规则改写）。
    /// - Returns: 解析出的绝对时刻；**全部格式都失败 → nil**
    ///   （调用方据此如实退回原始串，**绝不**编造时刻）。
    static func parseISO8601(_ raw: String, locale: Locale? = nil) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let resolvedLocale = locale ?? Locale(identifier: "en_US_POSIX")
        for format in iso8601CandidateFormats {
            let formatter = DateFormatter()
            formatter.locale = resolvedLocale
            // 🔴 解析基准固定 UTC：串尾的 `Z` / 偏移只是被解析，不参与运算。
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let parsed = formatter.date(from: trimmed) { return parsed }
        }
        return nil
    }

    /// 🔴 ISO8601 候选格式链（**顺序敏感**：先精确后宽松）。
    ///
    /// ⚠️ **实测只有前两种形态真出现过**（见文件头）：
    ///   `2026-10-08T15:00Z`（无秒）/ `2026-10-07T16:00Z`（无秒）；
    ///   带秒、带毫秒、带数字偏移的形态是按 ISO8601 规范补的防御项，
    ///   **未在本机实测**（本机无编译器）。
    ///
    /// 🔴 **为什么 `XXX` 与 `'Z'` 两套都要列**：
    ///   `XXX`（ISO8601 扩展时区占位符）社区实测能同时吃 `Z` 与 `+08:00`，
    ///   但那是社区口径、**本机未实测**；而把 `Z` 写成**字面量** `'Z'`
    ///   只能吃 `Z`、吃不了 `+08:00`，却是**最无争议**的写法。
    ///   → 两套都列进回退链：谁先命中都用，**都不命中就返回 nil**
    ///     （调用方如实退回原始串，绝不编造）。
    ///   这是「没有编译器时用回退链对冲不确定」的常规做法。
    static let iso8601CandidateFormats: [String] = [
        "yyyy-MM-dd'T'HH:mmXXX",// 🔴 无秒 + 扩展时区（实测形态，最常见）
        "yyyy-MM-dd'T'HH:mm'Z'",        // 无秒 + 字面 Z（最无争议的兜底）
        "yyyy-MM-dd'T'HH:mm:ssXXX",     // 有秒 + 扩展时区
        "yyyy-MM-dd'T'HH:mm:ss'Z'",     // 有秒 + 字面 Z
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXX", // 有毫秒 + 扩展时区
        "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"  // 有毫秒 + 字面 Z
    ]
}

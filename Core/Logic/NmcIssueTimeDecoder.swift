//
//  NmcIssueTimeDecoder.swift
//  Core / Logic  [App + Widget 共用]
//
//  NMC 预警 `issuetime` 字符串 → Date 的**独立解码器**（纯函数、零 IO）。
//
//  ═══════════════════════════════════════════════════════════════════════
//  实测形态（2026-10-06 逐字，全161 条一致）
//  ═══════════════════════════════════════════════════════════════════════
//  "issuetime": "2026/10/06 20:28"
//  "issuetime": "2026/10/06 20:50"
//  ⚠️ **不是** ISO8601（无 `-` 分隔日期、无 `T`）、**没有秒**、**没有时区标识**。
//
//  ── 为什么时区必须**注入**而不是读 `.current` ──────────────────────────
//  `issuetime` 是**发布地墙钟**（发布机构所在地的时间）。
//  若按设备时区解释，则当设备在境外（`Asia/Shanghai` 之外）时，
//  一条 20:28 发布的预警会被算成"8 小时前的旧数据"→ 直接触发 `.stale`
//  → **在灾害天气里谎报"数据不可信"**。
//  故本解码器要求调用方显式传入 `TimeZone`（由 `City.timeZoneIdentifier`
//  裁定，沿用既有 D-4 纪律），**绝不**读 `TimeZone.current`、也**绝不**
//  硬编码 `+8`（`TimeZone(secondsFromGMT:)` 只在调用方明确知道偏移时用；
//  本文件走`TimeZone` 对象，不碰固定偏移）。
//
//  ── 纪律：不用 `DateFormatter`（与 `ISOTimeStringDecoder` 同款理由）────
//  `DateFormatter` 的 locale / 宽松解析是不可控面（R-A4），且它是
//  非线程安全的共享可变状态。故手工逐位解析数字，行为完全确定、可单测；
//  日期合法性交给 `Calendar.date(from:)` 裁定（13 月 / 32 日 → nil）。
//
//  Core 纪律：仅 import Foundation；纯函数（无内部 Date()、无副作用）；
//  禁 UIKit / try! / fatalError。
//

import Foundation

/// NMC `issuetime`（`yyyy/MM/dd HH:mm`）解码器（纯函数 enum）。
enum NmcIssueTimeDecoder {

    /// 把 `2026/10/06 20:28` 形式的墙钟串解析为绝对时刻。
    ///
    /// - Parameters:
    ///   - string: 原始 `issuetime`。容忍变体：`/` 或 `-` 分隔日期、
    ///    空格或 `T` 分隔日期与时间、有/无秒段（实测上游恒为前两种形态，
    ///     后两种为**向前兼容**，不构成本仓对未实测行为的依赖 ——
    ///     解析失败一律返回 nil，绝不猜）。
    ///     🔴 四种形态**都**必须真能解析，由
    ///     `NmcAlarmTests.testIssueTimeAcceptsEveryDocumentedSeparatorVariant` 钉住
    ///     —— 2026-10-07 发现本函数曾因**两个**叠加 bug（日期分界字符选错、
    ///     无条件剥"秒"段）导致实测形态 100% 返回 nil。
    ///   - timeZone: 该预警**发布地**的时区（由调用方按选中城市注入，
    ///     见 D-4 纪律）。**不传则返回 nil** —— 宁可不解析，
    ///     也不拿设备时区把发布时刻算错。
    /// - Returns: 解析出的绝对时刻；格式不符 / 分量非法 / 空串 / 未给时区 → nil。
    static func date(from string: String, timeZone: TimeZone?) -> Date? {
        // ① 时区必须显式注入（绝不 `.current`、绝不硬编码 +8）。
        guard let timeZone else { return nil }

        // ② 切分日期段 / 时间段。
        //
        // 🔴 **日期与时间之间的分隔符只能是空格 / `T`**（2026-10-07 修正的真实 bug）。
        //
        // ⚠️ **曾经的 bug**：这里取「串里出现的**第一个**分隔符」来切，
        // 而分隔符集合里同时含 `/`、`-`、`T`、`t`。于是：
        //   "2026/10/06 20:28"    → 首个命中是**日期内部**的 `/` → datePart = "2026"
        //   "2026-10-06 21:29:27" → 首个命中是日期内部的 `-` → datePart = "2026"
        // 两者都被切成 1 个分量 → `count == 3` 不成立 → **返回 nil**。
        // ⇒ **实测形态 `2026/10/06 20:28` 全部解析失败**，
        // 每一条 NMC 预警的 `issuedAt` 都是 nil（→ 四态判定把真实预警当 stale）。
        // ⚠️ 注意：旧注释里"只认首个分隔符"的辩解**是错的** ——
        // 问题不在"切几次"，而在**把日期内部的 `/`、`-` 误当成了日期/时间的分界**。
        // 正解是分两层：**先**按 空格/`T`/`t` 切出日期段与时间段，
        // **再**在日期段内部按 `/` 或 `-` 切出年月日。
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundarySeparators: Set<Character> = [" ", "T", "t"]
        guard let boundaryIndex = trimmed.firstIndex(where: { boundarySeparators.contains($0) }),
              boundaryIndex != trimmed.startIndex,
              trimmed.index(after: boundaryIndex) < trimmed.endIndex else {
            return nil
        }
        let datePart = String(trimmed[trimmed.startIndex..<boundaryIndex])
        let timePartRaw = String(trimmed[trimmed.index(after: boundaryIndex)...])

        // ③ 日期段：`yyyy/MM/dd` 或 `yyyy-MM-dd`（3 分量、纯数字）。
        let dateSeparators: Set<Character> = ["/", "-"]
        let dateComponents = datePart.split(whereSeparator: { dateSeparators.contains($0) })
        guard dateComponents.count == 3 else { return nil }
        guard let year = Self.scalarInt(dateComponents[0], digits: 4),
              let month = Self.scalarInt(dateComponents[1]),
              let day = Self.scalarInt(dateComponents[2]) else {
            return nil
        }

        // ④ 时间段：`HH:mm` 或 `HH:mm:ss`（**秒段可选**，实测上游恒为前者）。
        //
        // 🔴 **第二个真实 bug**（2026-10-07 修正）：原实现**无条件**取
        // 「**最后一个** `:`」把尾段当**秒**剥掉，再要求剩下的是 2 段。
        // 但实测形态 `20:28`（**无秒段**）的尾段是**分钟** `28`：
        //   "20:28" → 误把 "28" 当秒剥掉 → 剩 "20" → 只有 1 段 → `count == 2`
        //   不成立 → **返回 nil**。
        // ⚠️ 旧注释写着"实测上游恒无秒段"，代码却恰恰**只**在有秒段时才正确
        // —— 注释与实现自相矛盾，正是这个 bug 的藏身处。
        // ⇒ 即便修好 ② 的日期分界，`"2026/10/06 20:28"` 仍会返回 nil。
        // 两个 bug **叠加**才导致实测形态 100% 解析失败。
        //
        // 正解：**先**按 `:` 切，再**按段数**裁定 —— 2 段 = HH:mm，3 段 = HH:mm:ss。
        var second = 0
        var timePart = timePartRaw
        // 去掉可能存在的毫秒小数部分（`20:28:30.123`）：实测上游不会出现，
        // 这里兼容它只是因为「解析失败返回 nil」已足够安全，不需要更多保证。
        if let dotIndex = timePart.firstIndex(of: ".") {
            timePart = String(timePart[timePart.startIndex..<dotIndex])
        }
        let timeComponents = timePart.split(separator: ":", omittingEmptySubsequences: false)
        guard timeComponents.count == 2 || timeComponents.count == 3 else { return nil }
        if timeComponents.count == 3 {
            guard let parsedSecond = Self.scalarInt(timeComponents[2]) else { return nil }
            second = parsedSecond
        }
        guard let hour = Self.scalarInt(timeComponents[0]),
              let minute = Self.scalarInt(timeComponents[1]) else {
            return nil
        }

        // ⑤ 组装：合法性交给 Calendar 裁定（13 月 / 32 日 / 25 时 → nil）。
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: components)
    }

    // MARK: - Private

    /// 子串 → 非负整数；要求全部字符为 ASCII 数字（`Int.init?(String)`
    /// 会接受 "+5"、"５"（全角）等宽松形态，手工逐位解析把"宽容面"
    /// 钉死为纯数字 —— 与 `ISOTimeStringDecoder.scalarInt` 同一纪律）。
    private static func scalarInt(_ raw: Substring, digits: Int? = nil) -> Int? {
        guard !raw.isEmpty else { return nil }
        if let digits, raw.count != digits { return nil }
        var value = 0
        for character in raw {
            guard let ascii = character.asciiValue,
                  ascii >= 48, ascii <= 57 else { return nil }  // "0"..."9"
            value = value * 10 + Int(ascii - 48)
        }
        return value
    }
}
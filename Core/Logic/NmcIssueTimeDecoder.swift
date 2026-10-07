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
//  日期合法性**由本文件显式校验**（范围 guard + 回读自证），
//  🔴 **绝不**委托 `Calendar.date(from:)` 裁定—— 它对越界分量
//  **按自然溢出归一化并返回非 nil**（13 月 → 次年 1 月），旧注释此处写了假话。
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

        // ⑤ 组装：合法性由**本函数显式校验**，**不**依赖 `Calendar.date(from:)`。
        //
        // 🔴 **第三个真实 bug**（2026-10-07 CI `testIssueTimeDecoding` 暴露）：
        // 旧实现把分量合法性**委托**给 `calendar.date(from:)`，并在上面的
        // 文件头注释里写「13 月 / 32 日 → nil」。**那是错的**：
        // Foundation 的 `Calendar.date(from:)` 对越界分量**不做校验、按自然
        // 溢出归一化**并返回**非 nil**（本仓`ISOTimeStringDecoderTests`
        // 的 `testNilWhenDateComponentsInvalid` 早就用实测记录了同一事实：
        // 13 月 → 次年 1 月、32 日 → 次月 2 日）。
        // ⇒ `"2026/13/06 20:28"` 被"编"成 **2027-01-06 20:28 +08**
        //   （= `2027-01-06 12:28:00 +0000`），正是 CI 报出的失败值。
        //而本项目的纪律是「**时刻解析绝不猜**」：一个**编出来的**日期比
        // `nil` 糟糕得多 —— 它会被当成真实发布时间参与四态新鲜度裁定，
        // 把一条 `issuedAt` 凭空推到 91 天之后（实测），无人能察觉。
        //
        // 正解：**逐分量显式范围校验**（下面的 `guard`）+ **回读自证**
        // （`dateComponents` 回来必须与输入逐项相等）。
        // 后者一次性覆盖「2 月 30 日」这类"范围合法但日历上不存在"的形态 ——
        // 只查 `1...31` 是拦不住的，而逐日查`range(of:.day,in:.month)`
        // 又要先造一个日期出来（自举）。回读是唯一既总括又无自举的写法。
        guard (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second) else {
            return nil
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: components) else { return nil }

        // 回读自证：Calendar 一旦做过任何归一化（13 月 / 2 月 30 日 / 25 时），
        // 回读的分量就与输入不等⇒ 判nil，绝不把归一化后的日期当合法时刻。
        let roundTrip = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        guard roundTrip.year == year,
              roundTrip.month == month,
              roundTrip.day == day,
              roundTrip.hour == hour,
              roundTrip.minute == minute,
              roundTrip.second == second else {
            return nil
        }
        return date
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
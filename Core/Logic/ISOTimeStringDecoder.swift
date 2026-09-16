//
//  ISOTimeStringDecoder.swift
//  Core / Logic  [App + Widget 共用]
//
//  ISO 本地墙钟字符串 → Date 的**独立解码器**（A1-4，ARCH-A1 §1.4 四铁律）。
//
//  背景（⚠️ run37 真机修正）：ARCH-A1 §1.4 原论断为"Open-Meteo 带
//  `timeformat=unixtime` 时 daily.sunrise/sunset 仍以 ISO 本地墙钟字符串
//  返回"。**真机实测该论断有误**——同一参数下二者返回 **epoch 整数**
//  （曾致真机 100% 解码失败）。现 DTO 用 FlexibleTime 双态容忍，
//  本解码器保留为 **ISO 形态（部分部署）的兜底路径**，不再承担主路径。
//
//  设计约束（缺一不可）：
//  1. **与 epoch 路径隔离**：与 `Date(timeIntervalSince1970:)` 完全分离，
//     仅由 FlexibleTime 的 `.iso` 分支调用（PRD R3 的"不混用"精神保留）。
//  2. **时区来源 = 同响应的 `utc_offset_seconds`**：不引入 TimeZone.current、
//     不依赖设备时区，字符串按"该偏移下的墙钟"解释。
//  3. **手工分量解析**：按 `T`/`:`/`-` 切分出年月日时分分量，
//     `DateComponents` + `TimeZone(secondsFromGMT:)` 构造 —— 不用
//     `DateFormatter`（其 locale/宽松解析是不可控面，R-A4）；
//     解析失败返回 nil，行为完全确定且可单测。
//  4. **DTO 存 String、领域层存 Date**：字符串不出 Networking 层
//     （mapper 是唯一调用点）。
//
//  Core 纪律：仅 import Foundation；纯函数（无内部 Date()、无副作用）；
//  禁 UIKit / try! / fatalError。
//

import Foundation

/// ISO 本地墙钟字符串解码器（纯函数 enum）。
enum ISOTimeStringDecoder {

    /// 将 "2026-09-11T05:53" 形式的本地墙钟字符串解析为绝对时刻。
    ///
    /// - Parameters:
    ///   - string: ISO 墙钟字符串。接受 `yyyy-MM-ddTHH:mm` 与
    ///     `yyyy-MM-ddTHH:mm:ss` 两种形态（Open-Meteo sunrise/sunset 为前者；
    ///     秒段存在时亦宽容解析）。**必须**含 `T` 分隔符与日期、时间两段。
    ///   - utcOffsetSeconds: 与该字符串同属一个响应的根级
    ///     `utc_offset_seconds`；字符串按"该偏移下的墙钟"解释。
    /// - Returns: 解析出的绝对时刻；格式不符 / 分量非法 / 空串 → nil。
    ///
    /// 实现要点：
    /// - 先按 `T` 切分日期段与时间段（大小写 `T` 与空格分隔均接受，
    ///   以覆盖 RFC 3339 的宽容变体；无分隔 → nil）。
    /// - 日期段按 `-` 切出年/月/日；时间段按 `:` 切出时/分（/秒）。
    ///   全部分量必须为纯数字，否则 nil。
    /// - 有效性交给 `DateComponents` → `Date` 的构造：Calendar 会对
    ///   13 月 / 32 日等非法组合返回 nil（`date(from:)` 的确定性语义），
    ///   不再自行写月份天数表。
    /// - `TimeZone(secondsFromGMT:)` 恒非 nil（任意秒值合法），故
    ///   直接用 `!` 之外的写法：先解包为局部常量再使用（项目禁 `!`）。
    static func date(from string: String, utcOffsetSeconds: Int) -> Date? {
        // ① 时区：由显式 offset 构造，绝不碰 TimeZone.current（铁律 2）。
        guard let timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds) else {
            return nil
        }

        // ② 切分日期段 / 时间段（必须含 T 分隔，两段均非空）。
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separatorIndex = normalized.firstIndex(where: { $0 == "T" || $0 == "t" || $0 == " " }),
              separatorIndex != normalized.startIndex,
              normalized.index(after: separatorIndex) < normalized.endIndex else {
            return nil
        }
        let datePart = String(normalized[normalized.startIndex..<separatorIndex])
        let timePart = String(normalized[normalized.index(after: separatorIndex)...])

        // ③ 日期段：yyyy-MM-dd（三分量、纯数字）。
        let dateComponents = datePart.split(separator: "-", omittingEmptySubsequences: false)
        guard dateComponents.count == 3 else { return nil }
        guard let year = Self.scalarInt(dateComponents[0], digits: 4),
              let month = Self.scalarInt(dateComponents[1]),
              let day = Self.scalarInt(dateComponents[2]) else {
            return nil
        }

        // ④ 时间段：HH:mm 或 HH:mm:ss（纯数字；秒段可选）。
        let timeComponents = timePart.split(separator: ":", omittingEmptySubsequences: false)
        guard timeComponents.count == 2 || timeComponents.count == 3 else { return nil }
        guard let hour = Self.scalarInt(timeComponents[0]),
              let minute = Self.scalarInt(timeComponents[1]) else {
            return nil
        }
        var second = 0
        if timeComponents.count == 3 {
            guard let parsedSecond = Self.scalarInt(timeComponents[2]) else { return nil }
            second = parsedSecond
        }

        // ⑤ 组装：有效性由 Calendar 裁定（13 月 / 32 日 / 25 时 → nil）。
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

    /// 子串 → 非负整数；要求全部字符为 ASCII 数字（`NumberFormatter`/
    /// `Int.init?(String)` 会接受 "+5"、"５"（全角）等宽松形态，
    /// 手工逐位解析把"宽容面"钉死为纯数字，R-A4）。
    /// - Parameters:
    ///   - raw: 待解析子串。
    ///   - digits: 非 nil 时要求精确位数（年份固定 4 位）。
    /// - Returns: 解析结果；空串 / 含非数字 / 位数不符 → nil。
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

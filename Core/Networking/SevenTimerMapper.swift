//
//  SevenTimerMapper.swift
//  Core / Networking  [App + Widget 共用]
//
//  第八源 DTO → 领域补丁（纯函数）。
//
//  ════════════════════════════════════════════════════════════════════════
//  ⚠️⚠️ **字段映射的诚实性 —— 本文件只映射 2 个字段，其余全部刻意不接**
//  ════════════════════════════════════════════════════════════════════════
//  7timer 的 `meteo` 产品虽然字段不少，但**多数不是可直接使用的物理量**。
//  逐字段实测结论（依据见每个条目的注释）：
//
//  | 7timer 字段 | 实测形态 | 接不接 | 理由 |
//  |---|---|---|---|
//  | `temp2m` | 整数 ℃（北京 14…28，与 Open-Meteo 同期逐时差 0.4–1.4℃） | ✅ 接 | 量纲与语义**完全一致** |
//  | `msl_pressure` | 整数 hPa（北京 1015…1025，与 Open-Meteo `pressure_msl` 差 ~2hPa） | ✅ 接 | 同上 |
//  | `rh2m` | 实测值域 **[−3, 10]**（东京 1…10、亚特兰大 9…13） | ❌ **不接** | 它是**档位码不是百分比**：官方 doc §2.3.1 逐字给出 `−4=0%–5% … 16=100%`。同期Open-Meteo `relative_humidity_2m` 是 31…71（真百分比）。接它= 产出**假湿度** |
//  | `cloudcover` | 实测值域 **[1, 9]** | ❌ **不接** | 同为档位码：doc 明文 `1=0–6% … 9=94–100%`。`WeatherFieldKey.cloudCover` 语义是**百分比**，接码= 假云量 |
//  | `wind10m.speed` | 实测值域仅 **{2,3,5}** | ❌ **不接** | doc 明文 `2=0.3–3.4 m/s`、`3=3.4–8.0 m/s` —— 是**风力等级码**。同期 Open-Meteo `wind_speed_10m` 是 0.9…11.0 **km/h**（3.06…0.25 m/s）。接码= 假风速 |
//  | `wind10m.direction` | **字符串** `"195"`（数字度数） | ⚠️ **接，但降级说明** | 量纲与 Open-Meteo `wind_direction_10m` 同为度，可接。**但跨产品不一致**：同一字段在 `astro` 产品实测是方位字母 `"S"`/`"NE"` → 若上游改回字母，本实现解析失败 → **该字段缺失**（显示 `--`），**绝不**猜 |
//  | `prec_amount` / `prec_type` | 档位码 / 字符串 | ❌ **不接** | 降水量无法映射到本仓字段域；`precipitation` 语义是 mm 实值 |
//
//  **这正是本仓纪律要求的「能精确映射的才接」。** 宁可少接，也绝不把
//  「档位码」当「百分比」写进补丁 —— 那会让 UI 显示一个看起来正常、
//  实际错得离谱的湿度/云量/风速，且**没有任何报错**（最坏的一类缺陷）。
//
//  ════════════════════════════════════════════════════════════════════════
//  时间处理
//  ════════════════════════════════════════════════════════════════════════
//  **绝对时刻 = `init` + `timepoint` 小时**（`init` 为 10 位 `YYYYMMDDHH`）。
//
//  ⚠️ **`init` 是 UTC**（实测推定，证据见下）：北京坐标实测序列
//    26,23,20,17,16,17,23,27（tp=3,6,9,…,24），若按 UTC 解读则最低温落在
//    tp=15 → `2026-10-07 21:00 UTC` = 北京 **05:00 当地**（黎明最低）、
//    最高落在 tp=24 → `06:00 UTC` = 北京 **14:00 当地**（午后最高）——
//    与真实气温日变化一致。按「本地时」解读则相位整体偏移 8 小时、与日变化矛盾。
//    ⚠️ 这是**推定**而非官方声明（官方未明说 `init` 时区）；若上游改为本地时，
//    本源会整体偏移 —— 故本仓对该源**不做跨源数值校验**（无消费者），
//    且下面取「离 now 最近的一条」而非「按时段选」，偏移时不至于张冠李戴。
//
//  **取离 `now` 最近的一条**（|时间差| 最小），与第三源 MET Norway 同款语义：
//  是序列里**离 now 最近的一格原值**，不是插值、不是估算。
//  ⚠️ **但本仓在此多一道门槛：|时间差| > 3 小时（一个序列步长）→ 直接返回空补丁。**
//    理由：MET Norway 的序列覆盖 `now`，而本源只有 192 小时（8 天）窗口；
//    若 `now` 落在窗口之外，「最近的一条」可能是**数天前**的 ——
//    把它当「当前气温」显示就是**陈旧数据冒充当前值**。
//    宁可返回空补丁让UI 显示 `--`，也不显示过期读数（诚实红线）。
//
//  **0 与缺失严格区分**：`-9999` 是上游的「无效值」哨兵（doc §2.3.1 明文），
//  **不是真实读数** —— 实测 `(0,0)` 无人区64 条 `msl_pressure` 全为 -9999，
//  南极 `lat=-89.9` 则 `temp2m`/`msl_pressure`/`wind10m.direction` 全部 -9999。
//  故本 mapper **把 -9999 一律当作缺失**（绝不显示「-9999 hPa」）。
//
//  Core 纪律：仅 import Foundation；纯函数；禁 UIKit / 内部 Date() / try! / fatalError。
//  （`now` 由调用方注入，本 mapper 不取时钟。）
//

import Foundation

/// 第八源 DTO → 领域补丁映射器（纯函数）。
enum SevenTimerMapper {

    /// 「无效值」哨兵（实测：无人区/南极的真实响应里成片出现）。
    static let invalidSentinel = -9999

    /// 允许的最大时间偏差（秒）：**一个序列步长**= 3 小时。
    ///
    /// 超出即视为「`now` 落在本源的预报窗口之外」→ 返回空补丁，
    /// 而非把窗口边缘的陈旧读数当当前值。
    static let maxTimeDriftSeconds: TimeInterval = 3 * 3600

    /// 映射。
    ///
    /// - Parameters:
    ///   - response: 解码后的 DTO。
    ///   - now: 采集时刻（调用方注入，写入 `FieldPatch.capturedAt`）。
    /// - Returns: 稀疏字段补丁；序列缺失 / 时间不可解析 / 全部超差 → 全 nil 空补丁。
    static func map(_ response: SevenTimerResponse, now: Date) -> FieldPatch {
        var patch = FieldPatch(sourceID: .sevenTimer, capturedAt: now)

        guard let initText = response.init,
              let base = baseDate(fromInit: initText),
              let entry = nearestEntry(in: response.dataseries,
                                       base: base,
                                       to: now),
              let fields = entryFields(entry) else {
            return patch
        }

        // 只写两个**量纲与语义都精确一致**的字段（见文件头映射表）。
        if let value = fields.temperature { patch.set(.temperature, .number(value)) }
        if let value = fields.pressure { patch.set(.pressure, .number(value)) }
        // 风向：量纲一致（度）→ 可接；但它是**字符串**，解析失败即缺失（绝不猜）。
        if let value = fields.windDirection { patch.set(.windDirection, .number(value)) }
        return patch
    }

    // MARK: - 归一后的单条数值（把哨兵过滤放在这里收口）

    /// 单条里**已过滤 -9999 哨兵**的可用数值。
    private struct EntryFields {
        var temperature: Double?
        var pressure: Double?
        var windDirection: Double?
    }

    /// 取一条 → 归一数值（哨兵在此**统一**转成 nil）。
    private static func entryFields(_ entry: SevenTimerResponse.Entry) -> EntryFields? {
        var result = EntryFields()
        if let value = entry.temp2m, value != invalidSentinel {
            result.temperature = Double(value)
        }
        if let value = entry.msl_pressure, value != invalidSentinel {
            result.pressure = Double(value)
        }
        // 方向是字符串，且实测**同一字段在不同产品里可能是方位字母**
        // （`astro` 实测 "S"/"NE"）。这里只接受纯数字串，其余一律 nil（宁缺不猜）。
        if let raw = entry.wind10m?.direction {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != String(invalidSentinel),
               let degrees = Double(trimmed), degrees.isFinite {
                // 上游给的是 0–360；越界值说明语义已变 → 当缺失。
                if (0.0...360.0).contains(degrees) {
                    result.windDirection = degrees
                }
            }
        }
        return result
    }

    // MARK: - 时间

    /// 取离 `now` **最近**且偏差 **≤ `maxTimeDriftSeconds`** 的一条。
    ///
    /// - Parameters:
    ///   - entries: 序列（可含 nil 元素）。
    ///   - base: `init` 对应的基准时刻（UTC）。
    ///   - now: 注入的采集时刻。
    /// - Returns: 命中的那一条；无可解析条目或全部超差 → nil。
    private static func nearestEntry(in entries: [SevenTimerResponse.Entry?]?,
                                    base: Date,
                                    to now: Date) -> SevenTimerResponse.Entry? {
        var best: SevenTimerResponse.Entry?
        var bestDistance: TimeInterval?

        for entry in entries ?? [] {
            guard let entry,
                  let hours = entry.timepoint,
                  let time = absoluteDate(base: base, hoursAfterInit: hours) else { continue }

            let distance = abs(time.timeIntervalSince(now))
            // 超差即视为窗口外 —— 不参与候选（陈旧值不冒充当前值）。
            guard distance <= maxTimeDriftSeconds else { continue }
            // 并列最小时取序列中靠前者（严格小于故首个最小者胜出，结果确定）。
            if let current = bestDistance, distance >= current { continue }
            best = entry
            bestDistance = distance
        }
        return best
    }

    /// 基准时刻 + `timepoint` 小时 → 绝对时刻。
    private static func absoluteDate(base: Date, hoursAfterInit hours: Int) -> Date? {
        guard hours >= 0,
              let seconds = TimeInterval(exactly: hours * 3600) else { return nil }
        return base.addingTimeInterval(seconds)
    }

    /// `"2026100706"` → 基准时刻（**UTC**）。
    ///
    /// ⚠️ 手工按位切分而**不用** `DateFormatter` / `%Y%m%d%H%M`：
    /// 实测 `init` 恒为 **10 位**（无分钟位），用 `%H%M` 解析 `"06"` 会得到
    /// 「0 点 6 分」而把时刻整体偏移 6 分钟 —— 这是一个**静默**偏移，无任何报错。
    ///
    /// - Returns: 基准时刻；长度 / 数字 / 取值范围任一不符 → nil。
    private static func baseDate(fromInit text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = Array(trimmed)
        // 实测恒 10 位；宽松接受 8…14 位会掩盖上游格式变更，故**要求恰好 10 位**。
        guard digits.count == 10 else { return nil }

        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                guard let digit = digits[index].wholeNumberValue, digits[index].isASCII,
                      digits[index].isNumber else { return nil }
                value = value * 10 + digit
            }
            return value
        }

        guard let year = number(0..<4),
              let month = number(4..<6),
              let day = number(6..<8),
              let hour = number(8..<10) else { return nil }

        // 范围校验：`Calendar.date(from:)` 会把 2 月 31 日**滚动**成 3 月 3 日
        // （静默改写）。故先按真实日历拦住非法值。
        guard (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour) else {
            return nil
        }
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return calendar.date(from: components)
    }
}
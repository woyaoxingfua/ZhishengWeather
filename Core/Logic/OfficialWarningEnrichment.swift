//
//  OfficialWarningEnrichment.swift
//  Core / Logic  [App + Widget 共用]
//
//  官方预警**逐字段补源**（第七源 weather.cn →第六源 NMC 的字段级富化）。
//
//  ═══════════════════════════════════════════════════════════════════════
//  架构裁定：为什么是「字段级补源」，而不是「二选一」也不是「列表兜底」
//  ═══════════════════════════════════════════════════════════════════════
//  实测数据支撑（同一时刻两次抓取比对，详见 `WeatherCnAlarmEndpoint` 文件头）：
//  · weather.cn 列表 138 条vs NMC 列表 162 条；
//  · 以 alertid **精确相等**求交集 = **127 条**；
//    weather.cn 独有**11** 条，NMC 独有 **35** 条。
//  → **两者互不包含**。故"以 d1 列表兜底 NMC 列表"会**丢掉那35 条**
//    （真实灾害预警被漏报）；"以 NMC 列表为准、d1 只兜底"又会让
//    d1 那 11 条独有的预警**根本进不了列表**。
//
//  ⚠️ 故本文件的定位是**第三种形态**：**列表仍由 NMC 单独负责**
//  （它覆盖更全、且免 Referer 无需伪装），d1 **只补NMC 条目上缺的字段**。
//  这样：
//   · NMC 独有那 35 条**不丢**（列表仍来自 NMC）；
//   · d1 独有那 11 条**不进列表**（⚠️ **如实告知的代价**：
//     本仓**主动放弃**了这 11 条，而不是假装没有 —— 见下方"已知缺口"）；
//   · NMC 列表条目**逐字段**被 d1 的信息补强（正文/秒级时间/英文色）。
//
//  ── 为什么**不**把d1 做成 `FieldFallbackResolver` 那套 `FieldPatch` ────
//  `FieldFallbackResolver` 的契约是「逐 `WeatherFieldKey` 选一个值」
//  （硬约束①：主源非 nil 绝不覆盖）。但预警**不在 `WeatherFieldKey` 域内**
//  —— `OfficialWarning` 文件头已明确它是**列表**模型、刻意不进
//  `WeatherSnapshot` / `SharedWeatherPayload`（为了 Widget 载荷契约零改动）。
// 硬把它塞进 `FieldPatch` 会**逼出一个假字段**（如`warning.defenseGuide`），
//  那是本仓明令禁止的（见 `SourceCapability.officialWarning` 的同类纪律）。
//  → 故这里**复用同一套纪律**（主源优先、绝不覆盖、绝不平均），
//    但作用在**领域模型自身**的字段上，走独立实现。这是**有意识的重复**。
//
//  ── 连接键：`alertid` **逐字相等**（精确相等判定，不用任何阈值/相似度）──
//  实测三方同一条预警的键**逐字相同**（5/5 抽样核对）：
//    weather.cn 列表 `data[i][4]` == 详情 `identifier` == NMC `alertid`
//    逐字例：`65402641600000_20261006212927`
//  → 故连接用**字符串相等**。⚠️ 刻意**不**做"前 6 位相同即视为同一条"
//    这类模糊匹配：实测 137 行里有 26 行的 [4]/[5] 是
//    「本轮 alertid / 上一轮 alertid」成对出现（差几小时），
//    模糊匹配会把**已更新的预警**与**上一轮**混成一条。
//
//  ── ⚠️ 已知缺口（如实记录，不粉饰）────────────────────────────────────
//  ① d1 独有的 11 条预警**不进本仓列表**（NMC 侧确实没有，无法连接）。
//  ② d1 列表里的 `NAMEEN` 实测是**汉语拼音**（`zhaosu yilihasake xinjiang`）
//     **不是英文**，故**不**当"多语言标题"用；真正可用的英文字段是
//     `YJYC_EN`（实测 `Yellow` / `Blue`）—— 只取它，且**只当颜色名**。
//  ③ `RELIEVETIME` 语义**未确**（实测 5 条里 4 条 = 发布 +12h），
//     疑为"有效期"而非"实际解除时刻"→ 故字段名取 `detailExpiresAt`
//     并在注释里标明**不得当"已解除"展示**。
//
//  Core 纪律：仅 import Foundation；**纯函数**（无 IO、无内部时钟、
//  无全局状态）；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 官方预警补源器（纯函数）。
enum OfficialWarningEnrichment {

    /// 把 weather.cn 的结构化详情**逐字段**补到 NMC 已映射的条目上。
    ///
    /// - Parameters:
    ///   - items: NMC（主源）已映射、**已按城市筛选**的条目。
    ///   - details: weather.cn 详情键值对（`identifier` → 详情）。
    ///   - timeZone: 发布地时区（**必须注入**；nil → 秒级时间全为 nil，
    ///     理由同`NmcIssueTimeDecoder`：墙钟串无时区标识）。
    /// - Returns: 补源后的新数组（**不修改入参**）。
    ///
    /// ## 逐字段裁决表（主源优先，绝不覆盖，绝不平均）
    /// | 字段 | 主源（NMC） | 补源（d1） | 裁决 |
    /// |---|---|---|---|
    /// | 防御指南正文 | 无此字段 | `ISSUECONTENT` | **d1 填**（主源恒缺） |
    /// | 发布时间 | `issuetime`（**分钟级**） | `ISSUETIME`（**秒级**） | **d1 填**（更精确，见下） |
    /// | 详情页地址 | NMC `url` | — | 保留主源 |
    /// | 省/市/县/类型/颜色 | 标题解析 | `PROVINCE`/`CITY`/… | **保留主源** |
    ///
    /// ## 为什么发布时间**让 d1 覆盖** NMC（这是唯一的"覆盖"）
    /// 实测同一 `alertid`：NMC `issuetime` 恒为**分钟**（`2026/10/06 21:29`），
    /// d1 `ISSUETIME` 为**秒**（`2026-10-06 21:29:27`），
    /// 且**真值一致**（实测 116/116 条 d1 秒戳 ≥ NMC 分钟戳，
    /// 差值全部为 0~1 分钟，即 NMC 是 d1 的分钟截断）。
    /// → 这是**同一真值的更精确表示**，不是冲突，故取更精确者；
    ///    **不是**"两个源各说各话"的取舍。
    ///
    /// - Note: `details` 里命中不到的主源条目**原样返回**（缺字段就是缺，
    ///   绝不因此丢弃条目 —— 丢一条真实预警比少一个字段危险得多）。
    static func enrich(_ items: [OfficialWarningItem],
                       with details: [String: WeatherCnAlarmDetail],
                       timeZone: TimeZone?) -> [OfficialWarningItem] {
        guard !details.isEmpty else { return items }
        return items.map { item in
            // ⚠️ 连接键用 `item.id` —— 它就是 NMC 的 `alertid`
            //   （mapper 里 `id = entry.alertid ?? 合成兜底串`）。
            //   兜底串（`nmc-unknown-…`）不会命中 d1 键 → 原样返回，
            //   符合"缺字段就是缺"的语义。
            guard let detail = details[item.id] else { return item }

            var merged = item

            // ① 防御指南正文（主源模型上**根本没有**这个字段 → 纯增量）。
            //    空串按缺失处理（实测恒非空，但空串不该显示成"有正文却空白"）。
            let guide = detail.ISSUECONTENT.flatMap { $0.isEmpty ? nil : $0 }
            if let guide { merged.defenseGuide = guide }

            // ② 秒级发布时间（更精确表示，见上方裁决表）。
            //    ⚠️ 主源已能解析出分钟级时刻时，d1 解析失败**不覆盖**
            //    （`??` 右侧留原值）—— 绝不把"有值"变成"没值"。
            if let precise = NmcIssueTimeDecoder.date(from: detail.ISSUETIME ?? "",
                                                      timeZone: timeZone) {
                merged.issuedAt = precise
            }

            // ③ 详情页失效/有效期（⚠️ 语义未确，见文件头"已知缺口"③）。
            if let expires = NmcIssueTimeDecoder.date(from: detail.RELIEVETIME ?? "",
                                                      timeZone: timeZone) {
                merged.detailExpiresAt = expires
            }

            // ④ 英文颜色名（实测 `Yellow` / `Blue`，**非空**）。
            //    ⚠️ 只取颜色名，**不取** `NAMEEN`（实测是汉语拼音非英文，
            //    拿它当"英文标题"展示是把拼音冒充英文 —— 内容错误）。
            //    ⚠️ 这是**新增旁注字段**，不是替换 `color`：
            //    实测 d1 的 `YJYC_EN` 与 NMC 标题解析出的颜色同源一致，
            //    故主源 `color` **一律保留**，此处只补一个英文说法。
            if let english = detail.YJYC_EN, !english.isEmpty {
                merged.englishColorName = english
            }

            return merged
        }
    }
}
//
//  FallbackSourceNote.swift
//  ZhishengWeather（主 App target）
//
//  🔴 兜底源数值的**上屏消费者**（2026-10-11 新增）。
//
//  ══════════════════════════════════════════════════════════════════════════
//  为什么有这个文件（主理人原话：「你说有那几个保底的数据，你说都写进去了
//  没有显示而已」—— 这条**属实**）
//  ══════════════════════════════════════════════════════════════════════════
//  · `METNorwayMapper` 写 6 个数值字段（temperature / pressure / humidity /
//    cloudCover / windSpeed / windDirection）；
//  · `SevenTimerMapper` 写 3 个（temperature / pressure / windDirection）；
//  · 它们进 `solarOverlay` 后**没有任何视图读取**
//    （`SourceAttributionCoordinator` 文件头原话：「进了 overlay 但没有
//    任何视图读取」；`ContentView` 里唯一传 overlay + provenance 的地方
//    只有 `DaylightCard`，而它只读 solar 字段）。
//  → 即：**数据取到了、计了用量、走了健康判定，但用户永远看不到。**
//
//  ── 🔴 本文件**只补缺失字段，绝不覆盖主源值** ────────────────────────
//  `FieldFallbackResolver.merge`（`Core/Logic/FieldFallbackResolver.swift:44-72`）
//  的语义是「主源非 nil 就无条件保留主源值」，那是**硬约束**，本文件不改它。
//  本文件是**纯展示层**：它读「主源快照该字段是否为 nil」+「overlay 里
//  备源给了什么值」，**只在主源确实缺该字段时**才显示一行小字。
//
//  ⚠️ **因此本文件永远不会与主源「并列显示两个温度」** —— 那会让用户
//   不知道该信哪个。缺 → 显示备源值并标注来源；不缺 → **整行不渲染**。
//
// ── 🔴 v1.6 分工澄清（「多源常显交叉对照」上线后）──────────────────────────
//  本文件与新增的 `FallbackCrossCheck` 是**两层，判据互斥**：
//  · **本文件 = 「补缺」层**：主源**缺** → 显示备源值并标注来源名。
//    （v1.6 起 `.temperature` / `.humidity` / `.windSpeed` / `.windDirection`
//    在 `WeatherSnapshot` 里已可选，故这四项**第一次真的可能缺**，
//    `isPrimaryMissing` 已相应改为真判 nil。）
//  · **`FallbackCrossCheck` = 「对照」层**：主源**有**值 → 把备源读数
//    并列显示为「对照」，并显式写明「参照主源显示、不替换主源值」。
//  →同一字段**不会**同时出两行（缺/有 互斥）。
//  🔴 `FieldFallbackResolver.merge` 本轮**一个字都没改**（全仓地基）。
//
// ── 为什么放在指标区（而不是独立卡片）────────────────────────────────────
//  · 备源补的正是「温度 / 气压 / 湿度 / 云量 / 风速」这几个量，
//    它们在主屏的**同一个位置**就是 `ContentView.metricsSection` 的指标格；
//  · 独立卡片会让用户多滚一屏去看「主屏已经有的数据的备份」；
//  · 挂在指标格**下方**而不是格子里：`MetricCell` 是 Core 的共用组件
//    （Widget 也用），改它会牵动小组件布局 —— 本轮**不动它**。
//
// ── 🔴 为什么**不显示 7timer 的档位码字段** ─────────────────────────────
// `SevenTimerMapper.swift:8-26` 有逐字段诚实性对照表：7timer 的 `rh2m` /
// `cloudcover` / `wind10m.speed` 给的是**档位码不是物理量**
//（官方 doc §2.3.1：`rh2m` −4=0%–5%、16=100%）。接了就是**假数据**。
// → 本文件**只显示 7timer 实际映射了的 3 个字段**，一个都不多接。
//
// 本仓纪律：View 整体 `@MainActor`（P-06）；禁 `try!` / `fatalError` / `as!`。
//

import Foundation
import SwiftUI

/// 兜底源数值提示行（**只在主源缺该字段时**渲染）。
@MainActor
struct FallbackSourceNote: View {

    /// 主源快照（判据：**该字段在这里是否为 nil**）。
    let snapshot: WeatherSnapshot

    /// 辅助源覆盖层（稀疏补丁；已装载的字段即「备源补上的」）。
    let overlay: FieldPatch?

    /// 逐字段来源图（用于取「这个值来自哪个源」——**不靠猜**）。
    let provenance: FieldProvenanceMap?

    /// 🔴 算**一次**的提示行（避免 `body` 里在判空与渲染两处各调一次）。
    ///
    /// ⚠️ 纯函数 + 无副作用，故结果随时可重算；这里只是**收口**，
    ///   保证「判空用的集合」与「渲染用的集合」**永远是同一份** ——
    ///   两处各算一次的话，将来一旦不对称就会出现错位渲染。
    private var items: [Line] {
        Self.lines(snapshot: snapshot, overlay: overlay, provenance: provenance)
    }

    var body: some View {
        // ⚠️ **整个 View 条件化**：无备源补上的字段 → 空（不留空槽）。
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    Text(item.text)
                        .font(.system(size: Theme.FontSize.footnote))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - 纯逻辑（可单测，不渲染）

extension FallbackSourceNote {

    /// 一行备源提示。
    struct Line: Equatable, Identifiable {

        /// 字段键（`Identifiable` 的 id；同一字段只可能有一行）。
        var field: WeatherFieldKey

        /// 渲染好的整行文案。
        var text: String

        var id: WeatherFieldKey { field }
    }

    /// 🔴 **备源补上了哪些字段** → 提示行（**本类型的唯一判据**）。
    ///
    /// ⚠️ **三条硬纪律，逐条对应本仓铁律**：
    ///   ① **只在主源缺该字段时**产出（`isPrimaryMissing` 为真）——
    ///      主源有值 → 该字段**绝不**出现在结果里（不覆盖、不并列）；
    ///   ② **来源名从 `provenance` 取**，取不到 → **整行不渲染**
    ///      （宁可不显示，也不写一个猜出来的来源名）；
    ///   ③ **只覆盖备源真实映射了的字段**（MET 6 个 / 7timer 3 个），
    ///      一个都不多接（见文件头「为什么不显示 7timer 的档位码字段」）。
    ///
    /// - Parameters:
    ///   - snapshot: 主源快照（判「缺不缺」）。
    ///   - overlay: 辅助源覆盖层（取备源值）。
    ///   - provenance: 逐字段来源图（取备源**是谁**）。
    /// - Returns: 提示行（空数组 = 无备源补上任何字段 → 整段不渲染）。
    nonisolated static func lines(snapshot: WeatherSnapshot,
                                  overlay: FieldPatch?,
                                  provenance: FieldProvenanceMap?) -> [Line] {
        guard let overlay else { return [] }

        var result: [Line] = []
        // 逐字段判定（**显式列举**，不靠字典序 —— 顺序即展示顺序，稳定的）。
        for field in Self.candidateFields {
            // ① 主源有值 → **跳过**（绝不覆盖、绝不并列显示）。
            guard isPrimaryMissing(field, snapshot: snapshot) else { continue }
            guard let value = overlay.number(field), value.isFinite else { continue }
            // ② 来源必须查得到 → 查不到就不显示（不猜）。
            guard let record = provenance?[field],
                  record.kind == .fallback,
                  let sourceName = sourceDisplayName(record.sourceID) else { continue }
            //③ 量纲 / 格式：**每个字段各自一份**（℃ / hPa / % / m/s / 度不同）。
            guard let text = displayText(field: field, value: value) else { continue }
            result.append(Line(field: field,
                               text: fieldLabel(field) + " " + text
                                    + "（备源 " + sourceName + "）"))
        }
        return result
    }

    /// 🔴 **候选字段集**：备源**真实映射了**的那些（一个不多、一个不少）。
    ///
    /// ⚠️ **刻意不含 `.solarNoon`**：`SunriseSunsetMapper` 确实写了它，
    ///   但 `DaylightCard` 是它的**既有消费者**（昼长行），不在本文件职责内 ——
    ///   两处都显示会让用户看到同一件事两遍。
    /// ⚠️ 顺序 = 展示顺序（温度 → 气压 → 湿度 → 云量 → 风），稳定可预期。
    static let candidateFields: [WeatherFieldKey] = [
        .temperature, .pressure, .humidity, .cloudCover, .windSpeed, .windDirection,
    ]

    /// 🔴 **主源该字段是否缺失**（`nil` = 缺）。
    ///
    /// ⚠️ **只问「nil 与否」，不做任何换算或比较** ——
    ///   判据是「主源**根本没有**这个值」，不是「两个源数值差得多」。
    ///   后者是「交叉校验」，由**另一个**类型 `FallbackCrossCheck` 承担
    ///   （见该文件：主源有值时也把备源读数并列显示，明确标注是对照）。
    ///
    /// 🔴 **v1.6 修订**：`.temperature` / `.humidity` / `.windSpeed` /
    ///   `.windDirection` 原为**非可选**，故此处恒 `return false` ——
    ///   备源在这四项上**永远没有可补的位**（本文件 2026-10-11 首版即如此）。
    ///   `WeatherSnapshot` 已把这四项改为可选，故这里改为**真的去判 nil**：
    ///   主源确实缺 → 备源可以补、也应该被显示出来。
    ///   （改判据常量必须回源头核对：本仓铁律「有测试 ≠ 事实正确」。）
    nonisolated static func isPrimaryMissing(_ field: WeatherFieldKey,
                                             snapshot: WeatherSnapshot) -> Bool {
        switch field {
        case .temperature:
            return snapshot.temperature == nil
        case .pressure:
            return snapshot.pressureMSL == nil
        case .humidity:
            return snapshot.humidity == nil
        case .cloudCover:
            return snapshot.cloudCover == nil
        case .windSpeed:
            return snapshot.windSpeed == nil
        case .windDirection:
            return snapshot.windDirection == nil
        default:
            // 🔴 **不是候选字段** → 一律不显示（不猜、不顺手多显示一个）。
            return false
        }
    }

    /// 字段 → 用户可读标签（**每份文案一处**，不散落在各处）。
    nonisolated static func fieldLabel(_ field: WeatherFieldKey) -> String {
        switch field {
        case .temperature: return "温度"
        case .pressure: return "气压"
        case .humidity: return "湿度"
        case .cloudCover: return "云量"
        case .windSpeed: return "风速"
        case .windDirection: return "风向"
        default: return ""
        }
    }

    /// 🔴 数值 → 文本（**量纲逐字段不同，绝不共用一套格式**）。
    ///
    /// ⚠️ 气压走 `UnitPreference`（随用户单位偏好换算），
    ///   与主屏 `ContentView.pressureText` **同一真源**；
    /// ⚠️ 风向走 `WindDirectionFormatter`（度 → 8 方位中文），
    ///   与主屏同一真源。
    /// - Returns: 文本；字段不认识 → **nil**（调用方跳过该行）。
    nonisolated static func displayText(field: WeatherFieldKey, value: Double) -> String? {
        switch field {
        case .temperature:
            return String(format: "%.1f°C", value)
        case .pressure:
            let digits = UnitPreference.pressureFractionDigits(for: UnitPreference.pressureUnit())
            let displayed = UnitPreference.displayPressure(hPa: value)
            let symbol = UnitPreference.pressureSymbol()
            return String(format: "%.\(digits)f \(symbol)", displayed)
        case .humidity:
            return String(format: "%.0f%%", value)
        case .cloudCover:
            return String(format: "%.0f%%", value)
        case .windSpeed:
            let displayed = UnitPreference.displayWindSpeed(ms: value)
            let symbol = UnitPreference.windSpeedSymbol()
            return String(format: "%.1f \(symbol)", displayed)
        case .windDirection:
            return WindDirectionFormatter.text(from: value)
        default:
            // 🔴 不认识的字段 → nil（**绝不**给一个没有单位的裸数字，
            //   那正是「把档位码当物理量」类事故的形态）。
            return nil
        }
    }

    /// 源 id → 用户可读名（**从 `SourceDirectory` 派生**，不写死字符串）。
    ///
    /// ⚠️ 查不到 → **nil**（调用方整行不渲染）——
    ///   写一个猜出来的来源名比不显示更糟。
    nonisolated static func sourceDisplayName(_ id: SourceID) -> String? {
        guard let descriptor = SourceDirectory.descriptor(for: id) else { return nil }
        // 兜底源 7timer 在目录里的名字带「（兜底）」后缀（实测见
        // `SourceDescriptor.swift:318`），本行已经明写「备源」二字，
        // 故这里**原样**用目录名，不再叠加（避免「备源 7timer!（兜底）」）。
        return descriptor.displayName
    }
}
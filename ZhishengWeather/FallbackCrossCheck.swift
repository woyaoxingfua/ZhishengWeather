//
//  FallbackCrossCheck.swift
//  ZhishengWeather（主 App target）
//
//  🔴 「多源常显交叉对照」的上屏消费者（v1.6 新增）。
//
//  ══════════════════════════════════════════════════════════════════════════
//  它补的是哪个洞（主理人裁定：「即使主源有值，也把备源的读数明确标注为
//  对照显示出来（不替换主源）」）
//  ══════════════════════════════════════════════════════════════════════════
//  · `METNorwayMapper` 写 6 个数值字段（temperature / pressure / humidity /
//    cloudCover / windSpeed / windDirection），`SevenTimerMapper` 写 3 个
//    （temperature / pressure / windDirection）。这些值**确实进了**
//    `SourceAttributionCoordinator.solarOverlay`（单测
//    `SourceAttributionCoordinatorTests:327` 已断言 `solarOverlay?.number(.temperature)`
//    非 nil），**零新增网络请求**——本文件只读已在内存里的 overlay。
//  · 但在 v1.6 之前，`WeatherSnapshot` 的 temperature / windSpeed /
//    windDirection / humidity 是**非可选**，mapper 阶段就保证了主源一定有值，
//    → 备源在这四项上**永远没有可补的位** → 已上屏的 `FallbackSourceNote`
//    在这四项上恒不渲染 → **用户永远看不到备源的读数**。
//  · v1.6 把这四项改成可选后，「主源有没有值」第一次成为可区分的状态，
//    本文件才有可能把备源读数**以对照身份**显示出来。
//
//  ── 🔴 与既有FallbackSourceNote 的分工（判据互斥，绝不重复显示）─────────
//  · `FallbackSourceNote`（「补缺」层）：主源**缺** → 显示备源值 + 来源名。
//  · 本文件（「对照」层）：主源**有**值 → 并列显示「主源值 + 备源值（来源）」。
//  → 同一字段只会落在其中一层，绝不会既被补缺又被对照。
//
//  ── 🔴 本文件**绝不**改写快照、**绝不**参与合并 ──────────────────────
//  `FieldFallbackResolver.merge` 的「主源非 nil 绝不覆盖」是全仓地基，
//  本轮**一个字都没改**那个文件。本文件是**纯展示层**：读快照 + 读 overlay，
//  输出一行字，不写回任何数据。**绝不平均**（不存在 (a+b)/2 路径）。
//
//  ── 🔴 `.none`（查过了没有）vs `.unavailable`（取不到）：两套文案 ────────
//  这两个词在本仓语义完全不同，**绝不合并成一句「失败」**：
//  · `.none`：协调器跑过了，overlay 里**确实没有**这个字段的值
//    （备源没提供该字段）—— 这是「查过了，没有」，不是故障。
//  · `.unavailable`：连overlay 都拿不到（协调器没跑 / 城市时区未知 /
//    全部辅助源失败 → `solarOverlay == nil`）—— 这是「取不到」。
//  → 二者对应**不同**的提示文案，见 `statusText`。
//
//  ── 为什么只对照这四项 ────────────────────────────────────────────────
//  候选集 = v1.6 改可选的那四项 ∩ 备源真实映射了的字段。
//  `pressure` / `cloudCover` 本来就是可选的，主源缺时已由
//  `FallbackSourceNote` 负责；把它们也拉进对照层会让同一字段在
//  「主源有值」时多出一行与用户预期无关的信息，故**本轮不接**。
//
//  本仓纪律：View 整体 `@MainActor`（P-06）；禁 `try!` / `fatalError` / `as!`；
//  纯逻辑全部收在 `nonisolated static` 里（可单测、不渲染）。
//

import Foundation
import SwiftUI

/// 多源交叉对照行（**只在备源该字段确实有值时**渲染）。
@MainActor
struct FallbackCrossCheck: View {

    /// 主源快照（取主源值；nil = 主源也缺，那属`FallbackSourceNote` 的活）。
    let snapshot: WeatherSnapshot

    /// 辅助源覆盖层（稀疏补丁；`number(_:)` 取备源读数）。
    let overlay: FieldPatch?

    /// 逐字段来源图（取「这个读数来自哪个源」——**不靠猜**）。
    let provenance: FieldProvenanceMap?

    /// 🔴 算**一次**的对照行（判空与渲染共用同一份，杜绝错位渲染）。
    private var items: [Line] {
        Self.lines(snapshot: snapshot, overlay: overlay, provenance: provenance)
    }

    /// 取数状态（决定是否显示「取不到」提示行；判据在 `statusText`）。
    private var status: CrossCheckStatus {
        Self.status(overlay: overlay)
    }

    var body: some View {
        // ⚠️ **整个 View 条件化**：没有可对照的字段 → 只在「真的取不到」时
        //   出一行如实提示；「查过了、没有」则**整段不渲染**（那不是故障，
        //   每天都会发生，给用户一句「失败」是噪声，也是说谎）。
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    Text(item.text)
                        .font(.system(size: Theme.FontSize.footnote))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if status == .unavailable {
            Text(Self.statusText(.unavailable))
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 纯逻辑（可单测，不渲染）

extension FallbackCrossCheck {

    /// 🔴 取数状态。**两个 case 语义严格不同，绝不合并**（见文件头）。
    enum CrossCheckStatus: Equatable, Sendable {
        /// 协调器跑过了，备源**确实没有**提供任何可对照字段（不是故障）。
        case none
        /// 连 overlay 都取不到（协调器没跑 / 时区未知 / 全部辅助源失败）。
        case unavailable
    }

    /// 一行交叉对照。
    struct Line: Equatable, Identifiable {

        /// 字段键（`Identifiable` 的 id；同一字段只可能有一行）。
        var field: WeatherFieldKey

        /// 渲染好的整行文案。
        var text: String

        var id: WeatherFieldKey { field }
    }

    /// 🔴 交叉对照行（**本类型的唯一判据**）。
    ///
    /// ⚠️ **四条硬纪律，逐条对应本仓铁律**：
    ///   ① **主源有值 + 备源有值** 才成行 —— 只在**两者都在**时对照。
    ///      主源缺 → 交给 `FallbackSourceNote`（补缺层），本层不出行；
    ///      备源缺 → 本行**不渲染**（无对照可言，绝不编一个数出来）。
    ///   ② **来源名从 `provenance` 取**，取不到 → **整行不渲染**
    ///      （宁可不显示，也不写一个猜出来的来源名）。
    ///   ③ **文案必须让用户看出「这是对照、不是替换」** ——
    ///      固定含「对照」二字与「以…为准」的明示句，见 `assembleText`。
    ///   ④ **绝不改写快照、绝不平均** —— 纯展示，主源值原样透传。
    ///
    /// - Parameters:
    ///   - snapshot: 主源快照（取主源值）。
    ///   - overlay: 辅助源覆盖层（取备源值）。
    ///   - provenance: 逐字段来源图（取备源**是谁**）。
    /// - Returns: 对照行（空数组 = 无可对照字段）。
    nonisolated static func lines(snapshot: WeatherSnapshot,
                                  overlay: FieldPatch?,
                                  provenance: FieldProvenanceMap?) -> [Line] {
        guard let overlay else { return [] }

        var result: [Line] = []
        // 逐字段判定（**显式列举**，不靠字典序 —— 顺序即展示顺序，稳定的）。
        for field in Self.crossCheckFields {
            // ① 主源**有**值才对照（缺 → 归补缺层，两层互斥）。
            guard let primaryValue = primaryValue(field, snapshot: snapshot),
                  primaryValue.isFinite else { continue }
            // ① 备源**有**值才成行（备源也没有 → 无对照可言，整行不渲染）。
            guard let fallbackValue = overlay.number(field), fallbackValue.isFinite else { continue }
            // ② 来源必须查得到 → 查不到就不显示（不猜）。
            guard let record = provenance?[field],
                  record.kind == .fallback,
                  let sourceName = FallbackSourceNote.sourceDisplayName(record.sourceID) else { continue }
            // ③ 量纲/ 格式：**复用补缺层的同一份格式化器**（单一真源，
            //    绝不为了「对照」再写一套格式 —— 两套格式必然漂移）。
            guard let primaryText = FallbackSourceNote.displayText(field: field, value: primaryValue),
                  let fallbackText = FallbackSourceNote.displayText(field: field, value: fallbackValue)
            else { continue }
            result.append(Line(field: field,
                                text: assembleText(label: FallbackSourceNote.fieldLabel(field),
                                                   primaryText: primaryText,
                                                   fallbackText: fallbackText,
                                                   sourceName: sourceName)))
        }
        return result
    }

    /// 🔴 **候选字段集**：v1.6 改可选的那四项，且备源真实映射了它们。
    ///
    /// ⚠️ **刻意不含 `.pressure` / `.cloudCover`**：这两项本来就是可选的，
    ///   主源缺时已由 `FallbackSourceNote` 负责；在「主源有值」时把它们也
    ///   拉进对照层会给用户多出一行与主屏预期无关的信息。
    /// ⚠️ 顺序 = 展示顺序（温度 → 湿度 → 风速 → 风向），稳定可预期。
    nonisolated static let crossCheckFields: [WeatherFieldKey] = [
        .temperature, .humidity, .windSpeed, .windDirection,
    ]

    /// 主源该字段的值（`nil` = 主源也缺 → 本层不出行，归补缺层）。
    ///
    /// ⚠️ 湿度在快照里是 `Int?`、在 overlay 里是 `Double`（`.number`）——
    ///   这里统一转成 `Double` 交给共用的格式化器，避免量纲在两处各判一次。
    nonisolated static func primaryValue(_ field: WeatherFieldKey,
                                         snapshot: WeatherSnapshot) -> Double? {
        switch field {
        case .temperature:
            return snapshot.temperature
        case .humidity:
            return snapshot.humidity.map(Double.init)
        case .windSpeed:
            return snapshot.windSpeed
        case .windDirection:
            return snapshot.windDirection
        default:
            // 🔴 非候选字段 → nil（不猜、不顺手多显示一个）。
            return nil
        }
    }

    /// 🔴 组装整行文案（**唯一真源**，视图与单测都走这里）。
    ///
    /// ⚠️ 文案必须同时说清三件事，缺一件用户就会误读：
    ///   ① 这是**对照**（"对照" 二字）；② 备源**是谁**（来源名）；
    ///   ③ **以主源为准**（末句明示不替换主源值）。
    /// 形如：`温度 21.4°C · 对照 19.8°C（MET Norway）· 以主源为准，仅供参照`
    nonisolated static func assembleText(label: String,
                                         primaryText: String,
                                         fallbackText: String,
                                         sourceName: String) -> String {
        "\(label) \(primaryText) · 对照 \(fallbackText)（\(sourceName)）· 以主源为准，仅供参照"
    }

    /// overlay 是否可用来做对照。
    ///
    /// - Parameter overlay: 辅助源覆盖层（`nil` = 取不到，不是「没有」）。
    nonisolated static func status(overlay: FieldPatch?) -> CrossCheckStatus {
        // 🔴 `overlay == nil` 的成因（协调器没跑 / 城市时区未知 / 辅助源全失败）
        //   与「overlay 存在但没这些字段」是**两回事**，绝不合并成一句「失败」。
        overlay == nil ? .unavailable : .none
    }

    /// 取数状态 → 用户可读文案（**两套，绝不合并**）。
    ///
    /// - `.none`：查过了，备源没提供这几个字段 → **本层不显示**
    ///   （`body` 里对 `.none` 不渲染任何东西：这不是故障，天天如此）。
    /// - `.unavailable`：取不到 → 显示如实提示，且**说清下一步**。
    nonisolated static func statusText(_ status: CrossCheckStatus) -> String {
        switch status {
        case .none:
            // 保留分支以备将来需要显式展示；当前 `body` 不渲染它
            //（"查过了没有"不是故障，显示它只会制造噪声）。
            return "已核对备用源，这几项它都没有提供"
        case .unavailable:
            return "备用源对照暂不可用（本次未取到备用源数据）"
        }
    }
}
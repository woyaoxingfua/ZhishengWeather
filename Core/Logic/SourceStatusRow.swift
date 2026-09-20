//
//  SourceStatusRow.swift
//  Core / Logic  [App + Widget 共用]
//
//  设置页「多源管理」的展示行数据（SourceStatusRow）+ 静态源目录（SourceCatalog）。
//
//  ── T10 变更（ARCH-T10 §3.4 / §3.5）────────────────────────────────────────
//  `SourceCatalog.all` 由 `SourceDirectory.all` **派生**（原先是一份手维护数组，
//  漏加一项 → `isAuxiliary` 假 → 自动摘除**哑火** + 设置页**隐身**，
//  且本仓库真的漏了 `openMeteoAirQuality`）。
//  ⚠️ **不要再手工往 `SourceCatalog.all` 里加条目** —— 加源请改
//  `Core/Logic/SourceDescriptor.swift` 的 `SourceDirectory.all`（唯一手工点），
//  目录条目与摘除开关会一起跟着变。
//  守卫（锚性质）：`SourceDirectoryCoverageTests` 断言
//  `Set(SourceID.allCases) == Set(SourceCatalog.all.map(\.id))`。
//
//  说明：运行期能力链由 FieldSourceRegistry 负责；此处 SourceCatalog 仅为
//  「设置页展示」提供稳定的源清单与角色（主源 / 辅助源），二者职责分离，
//  不引入第二份源真源。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 源在「多源管理」中的状态。
enum SourceStatusState: Equatable, Sendable {
    case primaryActive       // 在用（主源）
    case standby             // 备用（辅助源，按需启用）
    case excluded(ExclusionReason)  // 已摘除（含手动停用 / EV-n）
    case notConfigured       // 未配置
}

/// 源的展示角色。
enum SourceRole: Sendable {
    case primary
    case auxiliary
}

/// 设置页「多源管理」的单行数据（Identifiable by SourceID）。
struct SourceStatusRow: Identifiable, Equatable, Sendable {
    var id: SourceID
    var displayName: String
    var state: SourceStatusState
    var lastSuccessAt: Date?
    var todayUsage: Int
}

/// 全部已配置数据源的静态目录（展示用，**派生**自 `SourceDirectory`）。
enum SourceCatalog {

    /// 目录项。
    struct Item: Sendable {
        let id: SourceID
        let displayName: String
        let role: SourceRole
        /// 该源是否参与自动摘除（展示层据此决定是否给「手动停用」入口）。
        let participatesInAutoExclusion: Bool
    }

    /// 已配置的源。**派生**自 `SourceDirectory.all` —— 新增源请改那里。
    static let all: [Item] = SourceDirectory.all.map { descriptor in
        Item(id: descriptor.id,
             displayName: descriptor.displayName,
             role: descriptor.role,
             participatesInAutoExclusion: descriptor.participatesInAutoExclusion)
    }
}

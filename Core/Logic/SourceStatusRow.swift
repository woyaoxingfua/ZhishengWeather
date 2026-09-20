//
//  SourceStatusRow.swift
//  Core / Logic  [App + Widget 共用]
//
//  设置页「多源管理」的展示行数据（SourceStatusRow）+ 静态源目录（SourceCatalog）。
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

/// 全部已配置数据源的静态目录（展示用）。
enum SourceCatalog {

    /// 目录项。
    struct Item: Sendable {
        let id: SourceID
        let displayName: String
        let role: SourceRole
    }

    /// 已配置的源（主源 + 辅助源）。新增源在此追加一行。
    static let all: [Item] = [
        Item(id: .openMeteoForecast, displayName: "Open-Meteo", role: .primary),
        Item(id: .sunriseSunset, displayName: "Sunrise-Sunset.org", role: .auxiliary)
    ]
}

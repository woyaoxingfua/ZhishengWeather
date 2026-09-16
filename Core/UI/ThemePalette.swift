//
//  ThemePalette.swift
//  Core / UI  [App + Widget 共用]
//
//  配色值类型：把 7 个语义色聚合成一个可**整包替换**的值对象，供 Theme 解析。
//  仅使用 SwiftUI（无 UIKit），以保证可被 Widget target 编译。
//
//  Commit 1（零视觉变化）：本文件只内置「深色」一套配色，其 7 个颜色是
//  重构前 Theme 既有颜色的**逐字复制**；Theme.activePalette 默认取 `.dark`，
//  故 Theme.background 等 token 的取值与重构前逐位一致。
//

import SwiftUI

/// 一套完整的界面配色（7 个语义色）。
///
/// 为什么做成值类型而非散落的静态常量：外观切换需要在运行时**整包**替换一支
/// 配色。值类型 + 查表（`ThemePalette.palette(for:)`）让「当前配色」只有一个
/// 真源，避免 7 个 token 各自解析、各自漂移。
struct ThemePalette {

    /// 页面背景。
    let background: Color
    /// 卡片 / 单元格底色。
    let surface: Color
    /// 主强调色（仅用于点亮数据，不铺大面积色块）。
    let accent: Color
    /// 次级强调色（次级语义，如 UV / 低温）。
    let accentSecondary: Color
    /// 主文字。
    let primaryText: Color
    /// 次级文字。
    let secondaryText: Color
    /// 分隔线 / 弱化描边。
    let divider: Color
}

extension ThemePalette {

    /// 深色配色（**重构前 Theme 的既有颜色，逐字保留**）。
    ///
    /// 这是 Commit 1「零视觉变化」的回归基线：不得改写这 7 组分量。
    static let dark = ThemePalette(
        background: Color(red: 0.043, green: 0.059, blue: 0.051),
        surface: Color(red: 0.086, green: 0.114, blue: 0.098),
        accent: Color(red: 0.353, green: 0.976, blue: 0.549),
        accentSecondary: Color(red: 0.251, green: 0.851, blue: 0.925),
        primaryText: Color(red: 0.902, green: 0.980, blue: 0.925),
        secondaryText: Color(red: 0.549, green: 0.678, blue: 0.604),
        divider: Color(red: 0.180, green: 0.255, blue: 0.208)
    )
}

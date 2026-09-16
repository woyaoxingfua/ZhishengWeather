//
//  Theme.swift
//  Core / UI  [App + Widget 共用]
//
//  全局视觉常量：配色经「活动配色」ThemePalette 解析，字号与圆角为固定常量。
//  仅使用 SwiftUI（无 UIKit），以保证可被 Widget target 编译。
//
//  本文件只做「配色抽层」：7 个语义色搬进 ThemePalette，活动配色默认 =
//  既有深色配色，故 Theme.background 等 token 的取值与重构前**逐位一致**
//  （零视觉变化，全部现有调用点零改动）。
//

import SwiftUI

/// 全局视觉常量。
enum Theme {

    // MARK: - 配色

    /// 当前活动配色。由根视图（App / Widget）在渲染前按需切换；
    /// 默认取深色，保证「未显式设置」时与重构前表现一致。
    static var activePalette: ThemePalette = .dark

    /// 页面背景。
    static var background: Color { activePalette.background }
    /// 卡片 / 单元格底色。
    static var surface: Color { activePalette.surface }
    /// 主强调色（仅用于点亮数据，不铺大面积色块）。
    static var accent: Color { activePalette.accent }
    /// 次级强调色（次级语义，如 UV / 低温）。
    static var accentSecondary: Color { activePalette.accentSecondary }
    /// 主文字。
    static var primaryText: Color { activePalette.primaryText }
    /// 次级文字。
    static var secondaryText: Color { activePalette.secondaryText }
    /// 分隔线 / 弱化描边。
    static var divider: Color { activePalette.divider }

    // MARK: - 字号

    /// 字号常量。
    enum FontSize {
        /// 超大温度。
        static let temperature: CGFloat = 76
        /// 现象文案。
        static let condition: CGFloat = 20
        /// 城市名。
        static let city: CGFloat = 17
        /// 区块标题。
        static let sectionTitle: CGFloat = 15
        /// 指标数值。
        static let metric: CGFloat = 14
        /// 说明文字。
        static let caption: CGFloat = 12
        /// 极弱文字（页脚）。
        static let footnote: CGFloat = 11
    }

    // MARK: - 圆角

    /// 卡片圆角。
    static let cornerRadius: CGFloat = 12
}

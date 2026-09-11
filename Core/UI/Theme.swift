//
//  Theme.swift
//  Core / UI  [App + Widget 共用]
//
//  深色磷光终端风配色与字号常量。
//  仅使用 SwiftUI（无 UIKit），以保证可被 Widget target 编译。
//

import SwiftUI

/// 全局视觉常量。
enum Theme {

    // MARK: - 配色

    /// 页面背景（近黑，微偏绿）。
    static let background = Color(red: 0.043, green: 0.059, blue: 0.051)
    /// 卡片 / 单元格底色。
    static let surface = Color(red: 0.086, green: 0.114, blue: 0.098)
    /// 主强调色：荧光绿。
    static let accent = Color(red: 0.353, green: 0.976, blue: 0.549)
    /// 次级强调色：青色。
    static let accentSecondary = Color(red: 0.251, green: 0.851, blue: 0.925)
    /// 主文字。
    static let primaryText = Color(red: 0.902, green: 0.980, blue: 0.925)
    /// 次级文字。
    static let secondaryText = Color(red: 0.549, green: 0.678, blue: 0.604)
    /// 分隔线 / 弱化描边。
    static let divider = Color(red: 0.180, green: 0.255, blue: 0.208)

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

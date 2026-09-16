//
//  ThemePalette.swift
//  Core / UI  [App + Widget 共用]
//
//  配色值类型 + 配色解析**纯函数**。
//  仅使用 SwiftUI（无 UIKit），以保证可被 Widget target 编译。
//
//  · ThemePalette   ：一套 7 色配色（运行时可整包替换）。
//  · ThemePaletteID ：配色标识（解析结果）。
//  · resolve(...)   ：(外观档位, 系统深浅) → 配色标识（纯函数，分支只在这一处）。
//
//  三支配色：
//    · legacyDark —— v0.1.0 深色配色基线（重构零视觉变化的回归守卫断言用；
//                    业务不再引用，仅测试断言其分量与重构前逐位一致）。
//    · dark       —— 深色 · 打磨磷光（中性近黑 + 薄荷绿数据色）。
//    · light      —— 浅色 · 清冷翡翠（冷灰纸 + 翡冷翠数据色）。
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

/// 配色标识（解析结果）。
///
/// 绑定「解析」与「查表」的中间类型：解析只需产出标识，视图层再据此查表，
/// 避免在 body 里散落 `if/switch` 条件。
enum ThemePaletteID: Hashable {
    /// 深色。
    case dark
    /// 浅色。
    case light
}

extension ThemePalette {

    // MARK: - 三支配色

    /// v0.1.0 深色配色基线（**重构前 Theme 的既有颜色，逐字保留**）。
    ///
    /// 用途：回归测试断言「配色抽层忠实复刻既有颜色」（零视觉变化的证据）。
    /// 业务代码不再引用它 —— 生产深色已升级为 `.dark`（打磨磷光）。
    static let legacyDark = ThemePalette(
        background: Color(red: 0.043, green: 0.059, blue: 0.051),
        surface: Color(red: 0.086, green: 0.114, blue: 0.098),
        accent: Color(red: 0.353, green: 0.976, blue: 0.549),
        accentSecondary: Color(red: 0.251, green: 0.851, blue: 0.925),
        primaryText: Color(red: 0.902, green: 0.980, blue: 0.925),
        secondaryText: Color(red: 0.549, green: 0.678, blue: 0.604),
        divider: Color(red: 0.180, green: 0.255, blue: 0.208)
    )

    /// 深色 · 打磨磷光：中性近黑底 + 薄荷绿数据色（去绿雾、降饱和、拉开层级）。
    static let dark = ThemePalette(
        background: Color(red: 0.0392157, green: 0.0431373, blue: 0.0470588),    // #0A0B0C
        surface: Color(red: 0.0901961, green: 0.1019608, blue: 0.1137255),       // #171A1D
        accent: Color(red: 0.2705882, green: 0.8078431, blue: 0.4862745),        // #45CE7C
        accentSecondary: Color(red: 0.3725490, green: 0.7215686, blue: 0.8392157), // #5FB8D6
        primaryText: Color(red: 0.9294118, green: 0.9372549, blue: 0.9490196),   // #EDEFF2
        secondaryText: Color(red: 0.5450980, green: 0.5764706, blue: 0.6078431), // #8B939B
        divider: Color(red: 0.1372549, green: 0.1568627, blue: 0.1725490)        // #23282C
    )

    /// 浅色 · 清冷翡翠：冷灰纸底 + 翡冷翠数据色。
    static let light = ThemePalette(
        background: Color(red: 0.9490196, green: 0.9607843, blue: 0.9529412),   // #F2F5F3
        surface: Color(red: 1.0, green: 1.0, blue: 1.0),                         // #FFFFFF
        accent: Color(red: 0.0588235, green: 0.4313725, blue: 0.3372549),        // #0F6E56
        accentSecondary: Color(red: 0.1137255, green: 0.6196078, blue: 0.4588235), // #1D9E75
        primaryText: Color(red: 0.0862745, green: 0.1254902, blue: 0.1058824),   // #16201B
        secondaryText: Color(red: 0.3607843, green: 0.4196078, blue: 0.3882353), // #5C6B63
        divider: Color(red: 0.8862745, green: 0.9098039, blue: 0.8941176)        // #E2E8E4
    )

    // MARK: - 解析（纯函数）

    /// 由标识取配色（纯查表）。
    ///
    /// - Parameter id: 配色标识。
    /// - Returns: 对应配色。
    static func palette(for id: ThemePaletteID) -> ThemePalette {
        switch id {
        case .dark: return .dark
        case .light: return .light
        }
    }

    /// **纯函数**：外观档位 + 系统深浅 → 配色标识。
    ///
    /// 语义：显式档位（dark / light）忽略系统深浅；`system` 档位取系统深浅。
    /// 全部条件分支集中在此，视图层只做「查表 + 应用」，不在 body 内散落判断。
    ///
    /// - Parameters:
    ///   - appearance: 外观档位。
    ///   - systemScheme: 当前系统深浅。
    /// - Returns: 应生效的配色标识。
    static func resolve(appearance: AppearanceSetting,
                        systemScheme: ColorScheme) -> ThemePaletteID {
        switch appearance {
        case .dark: return .dark
        case .light: return .light
        case .system: return systemScheme == .dark ? .dark : .light
        }
    }
}

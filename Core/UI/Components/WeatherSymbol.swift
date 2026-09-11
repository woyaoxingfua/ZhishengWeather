//
//  WeatherSymbol.swift
//  Core / UI / Components  [App + Widget 共用]
//
//  依据天气码 + 昼夜渲染 SF Symbol 的通用小视图。
//

import SwiftUI

/// 天气图标视图。
struct WeatherSymbol: View {

    /// WMO 天气码。
    let code: Int
    /// 是否白天（决定用日间还是夜间符号）。
    let isDay: Bool
    /// 字号（pt）。
    var size: CGFloat = 24
    /// 颜色。
    var color: Color = Theme.accent

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: size, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .accessibilityLabel(WMOCodeMapper.description(for: code))
    }

    /// 未知码（含空态传入的 -1）由 WMOCodeMapper 兜底为问号符号。
    private var symbolName: String {
        WMOCodeMapper.symbolName(for: code, isDay: isDay)
    }
}

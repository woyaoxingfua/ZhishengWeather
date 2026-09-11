//
//  MetricCell.swift
//  Core / UI / Components  [App + Widget 共用]
//
//  指标格：图标 + 数值 + 单位/文字。主屏 2 列网格使用。
//

import SwiftUI

/// 单个指标单元格。
struct MetricCell: View {

    /// SF Symbol 名。
    let icon: String
    /// 主数值（含单位或文字，如「3.2 m/s 东南」）。
    let value: String
    /// 说明文案（如「风速」）。
    let caption: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accentSecondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: Theme.FontSize.metric, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(caption)
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(Theme.divider, lineWidth: 0.5)
        )
    }
}

//
//  LifeIndexSection.swift
//  ZhishengWeather（主 App target）
//
//  主屏生活指数区块（A2-3 UI 落点，ARCH-A2P1 §1.1④）：
//  插入于逐日区块之下、月相区之上。
//  ⚠️ AC-A2-10：区块标题**必须**标注"本地估算·仅供参考"，
//  不得出现"生活指数""官方"等暗示词（grep 纪律 R-A2P1-1）。
//  文案由本层组装（"防晒：注意"），引擎只输出结构化结果。
//

import SwiftUI

/// 主屏生活指数区块（本地估算）。
@MainActor
struct LifeIndexSection: View {

    let items: [LifeIndexItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("生活参考")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)

            Text("本地估算 · 仅供参考")
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.secondaryText.opacity(0.7))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.kind) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.kind.displayName)
                            .font(.system(size: Theme.FontSize.metric, weight: .medium))
                            .foregroundStyle(Theme.primaryText)
                        Spacer(minLength: 8)
                        Text(levelText(for: item))
                            .font(.system(size: Theme.FontSize.caption, weight: .medium))
                            .foregroundStyle(color(for: item.level))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Private

    /// 行文案："防晒：注意（UV 8）" —— kind + level + 可选补充值。
    private func levelText(for item: LifeIndexItem) -> String {
        var text = item.level.displayName
        if let value = item.value {
            text += " · \(value)"
        }
        return text
    }

    /// 等级语义色（适宜绿 / 中性灰 / 注意橙 / 不宜红；与空气卡色系区分度足够）。
    private func color(for level: LifeIndexLevel) -> Color {
        switch level {
        case .recommended: return Color(red: 0.24, green: 0.72, blue: 0.45)
        case .neutral: return Theme.secondaryText
        case .caution: return Color(red: 0.95, green: 0.56, blue: 0.20)
        case .avoid: return Color(red: 0.90, green: 0.30, blue: 0.24)
        }
    }
}

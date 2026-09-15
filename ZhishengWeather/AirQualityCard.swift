//
//  AirQualityCard.swift
//  ZhishengWeather（主 App target）
//
//  主屏空气质量卡（A2-1，ARCH-A2 §1.1 UI 落点）：
//  插入于指标格（③）之下、逐小时（④）之上。
//  `viewModel.airQuality == nil` → 整卡不渲染（AC-A2-3 缺项与 AC-A2-4
//  失败统一收敛为"不渲染"，ARCH-A2 §1.1）。
//
//  配色：六档语义色（非 Theme 渐变），确保深浅底可读 + 色盲可辨
//  （同时以文字等级名区分，不单靠颜色传达）。
//

import SwiftUI

/// 主屏空气质量卡。
@MainActor
struct AirQualityCard: View {

    let airQuality: AirQuality

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 标题行：等级名 + 着色圆点 + AQI 数值。
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(Self.color(for: level))
                    .frame(width: 10, height: 10)
                Text("空气质量")
                    .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 8)
                Text(aqiText)
                    .font(.system(size: Theme.FontSize.metric, weight: .semibold))
                    .foregroundStyle(Self.color(for: level))
                Text(level.displayName)
                    .font(.system(size: Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Self.color(for: level))
            }

            // 主导污染物（D-A2-1 简化权重；nil 隐藏该段）。
            if let dominant = airQuality.dominantPollutant {
                Text("主要污染物：\(dominant)")
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            }

            // 六项分测横向格（缺项 --）。
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                MetricCell(label: "PM2.5", value: concentration(airQuality.pm25, unit: "μg/m³"))
                MetricCell(label: "PM10", value: concentration(airQuality.pm10, unit: "μg/m³"))
                MetricCell(label: "O₃", value: concentration(airQuality.ozone, unit: "μg/m³"))
                MetricCell(label: "NO₂", value: concentration(airQuality.nitrogenDioxide, unit: "μg/m³"))
                MetricCell(label: "SO₂", value: concentration(airQuality.sulphurDioxide, unit: "μg/m³"))
                MetricCell(label: "CO", value: concentration(airQuality.carbonMonoxide, unit: "μg/m³"))
            }

            // 欧标 AQI 辅助展示（不参与着色，Q2 裁定）。
            if let eu = airQuality.europeanAqi {
                Text("欧洲标准 AQI：\(eu)")
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Private

    private var level: AqiLevel { airQuality.level }

    /// AQI 大字：nil → "--"（绝不用 0 冒充，AC-A2-3）。
    private var aqiText: String {
        guard let aqi = airQuality.usAqi else { return "--" }
        return "\(aqi)"
    }

    /// 浓度值：1 位小数；nil → "--"。
    private func concentration(_ value: Double?, unit: String) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f %@", value, unit)
    }

    /// 六档语义色（EPA AQI 惯例色系；色盲可辨由等级文字兜底传达）。
    static func color(for level: AqiLevel) -> Color {
        switch level {
        case .good: return Color(red: 0.24, green: 0.72, blue: 0.45)   // 绿
        case .moderate: return Color(red: 0.95, green: 0.78, blue: 0.24) // 黄
        case .light: return Color(red: 0.95, green: 0.56, blue: 0.20)  // 橙
        case .medium: return Color(red: 0.90, green: 0.30, blue: 0.24) // 红
        case .heavy: return Color(red: 0.66, green: 0.31, blue: 0.66)  // 紫
        case .severe: return Color(red: 0.58, green: 0.16, blue: 0.24) // 栗
        case .unknown: return Theme.secondaryText                      // 未知 = 中性灰
        }
    }
}

//
//  MediumWeatherView.swift
//  ZhishengWeatherWidget（Widget target）
//
//  Medium（约 338×155）——**独立布局**，不是 Small 的拉伸：
//
//    ┌───────────────────────────────────────────────┐
//    │ 北京                    更新于 14:05           │  ← 头部
//    │ ┌──────────────┐ │ ┌───────────────────────┐  │
//    │ │ ☁️ 23°       │ │ │  ↑25°  ↓15°           │  │  ← 左：当前天气横排
//    │ │ 多云 · 体感21°│ │ │  湿度 58%  3.2 m/s 东南│  │     右：2 列指标网格
//    │ └──────────────┘ │ └───────────────────────┘  │
//    └───────────────────────────────────────────────┘
//
//  刻意不用 HourlyStrip：Medium 宽度只有 ~338pt，横向滚动区在小组件里
//  手势体验极差（且 iOS 16 上滚动组件在 widget 内易触发渲染问题）。
//  改为「左 34% 当前天气 + 右 2×2 指标网格」，信息密度更高且完全静态。
//
//  背景经 `widgetBackground(_:)` 双写（iOS 16 / 17 兼容）。
//

import SwiftUI
import WidgetKit

struct MediumWeatherView: View {

    let entry: WeatherEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .top, spacing: 12) {
                currentColumn
                    .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(Theme.divider)
                    .frame(width: 0.5)
                    .padding(.vertical, 2)

                metricsColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetBackground { Theme.background }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(cityName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)

            if isFallbackLocation {
                Text("默认城市")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text(updateText)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
    }

    // MARK: - 左栏：当前天气（图标 + 温度 + 现象 + 体感，横排）

    private var currentColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                WeatherSymbol(code: weatherCode, isDay: isDay, size: 24)

                Text(temperatureText)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }

            Text(conditionText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)

            Text(apparentText)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    // MARK: - 右栏：2 列指标网格（体感 / 最高 / 最低 / 湿度 / 风速 / 风向）

    @ViewBuilder
    private var metricsColumn: some View {
        let metrics = WeatherSnapshot.widgetMetrics(from: snapshot)
        if metrics.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("暂无数据")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Text("打开主 App 取数后自动显示")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        } else {
            // 宽度受限，只放前 4 项（体感 / 今日最高 / 今日最低 / 湿度），
            // 风速与风向挪到 Large 的完整网格，避免 Medium 里挤压成 3 行。
            MetricGridLayout(metrics: Array(metrics.prefix(4)),
                             columns: 2,
                             spacing: 6)
        }
    }

    // MARK: - 取值（空态安全兜底）

    private var snapshot: WeatherSnapshot? { entry.payload?.snapshot }

    private var cityName: String {
        // F-C：实例目标城市优先（固定城市无匹配快照时也显示所配城市名），
        // 回退快照 location（placeholder 预览路径）。
        entry.displayCityName ?? "—"
    }

    private var isFallbackLocation: Bool {
        snapshot?.location.isFallback == true
    }

    private var temperatureText: String {
        guard let snapshot else { return "--°" }
        return "\(Int(snapshot.temperature.rounded()))°"
    }

    private var conditionText: String {
        guard let snapshot else { return "暂无数据" }
        return WMOCodeMapper.description(for: snapshot.weatherCode)
    }

    private var apparentText: String {
        guard let snapshot else { return "体感 --°" }
        return "体感 \(snapshot.apparentTemperatureText)"
    }

    private var updateText: String {
        guard let payload = entry.payload else { return "" }
        return "更新于 \(WidgetTimeFormatter.hourMinute.string(from: payload.updatedAt))"
    }

    private var weatherCode: Int {
        snapshot?.weatherCode ?? -1
    }

    private var isDay: Bool {
        snapshot?.isDay ?? true
    }
}

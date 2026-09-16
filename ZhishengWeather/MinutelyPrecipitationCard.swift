//
//  MinutelyPrecipitationCard.swift
//  ZhishengWeather（主 App target）
//
//  B1-2 短时降水卡：未来约 2 小时的 15 分钟粒度降水柱状序列 + 开始/停止时序 + 峰值。
//
//  纪律：
//  - **粒度诚实**（AC-B1-7）：文案显式标注「15 分钟粒度 · 插值数据」，**禁止**
//    任何"逐分钟 / 雷达临近 / nowcast"措辞；不夸大精度。
//  - **干窗 / 无数据整卡隐藏**（AC-B1-8/B1-9）：隐藏判定由调用方经
//    `MinutelyPrecipitationEngine.hasPrecipitation` 完成，本视图假定调用时确有降水，
//    但仍在 `body` 内做一次防御性校验（干窗 → EmptyView），避免误用。
//  - 时刻按**选中城市时区**渲染（D-4 一致，复用 `WeatherTimeFormatter` 的格式器缓存）。
//  - 无新网络请求：数据来自既有单次 forecast 请求（B1-2）。
//

import SwiftUI

/// 短时降水卡（@MainActor：辅助成员需主 actor 隔离才能合法调用 `WeatherTimeFormatter`）。
@MainActor
struct MinutelyPrecipitationCard: View {

    /// 短时降水序列（已按"当前 15 分钟窗起 ≤ 2 小时"截窗）。
    let points: [MinutelyPrecipitationPoint]
    /// 时刻渲染时区（D-4）。默认设备时区；由 ContentView 透传 `viewModel.selectedTimeZone`。
    var timeZone: TimeZone = .current

    /// 柱状区高度（pt）。
    private let barAreaHeight: CGFloat = 40

    @ViewBuilder
    var body: some View {
        // 防御性：干窗 → 整卡不渲染（正常路径已由调用方拦截）。
        if MinutelyPrecipitationEngine.hasPrecipitation(points) {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            bars
            axis
            footer
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(Theme.divider, lineWidth: 0.5)
        )
    }

    // MARK: - 标题（粒度诚实标注）

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "cloud.rain.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accentSecondary)
                Text("短时降水")
                    .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
            }
            // AC-B1-7：显式标注粒度与（中国等非原生覆盖区的）插值来源。
            Text("未来 2 小时 · 15 分钟粒度 · 插值数据")
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    // MARK: - 柱状序列

    private var bars: some View {
        let peak = barScalePeak
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(points) { point in
                bar(for: point, peak: peak)
            }
        }
        .frame(height: barAreaHeight, alignment: .bottom)
    }

    /// 单柱：高度按峰值归一到 [0, barAreaHeight]；有降水至少 6pt 保证可见，干窗留 2pt 基线。
    private func bar(for point: MinutelyPrecipitationPoint, peak: Double) -> some View {
        let isWet = point.precipitation > MinutelyPrecipitationEngine.precipitationThreshold
        let ratio = min(max(point.precipitation / peak, 0), 1)
        let height = isWet ? max(barAreaHeight * CGFloat(ratio), 6) : 2
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isWet ? Theme.accentSecondary : Theme.divider)
                .frame(height: height)
        }
        .frame(maxWidth: .infinity)
        .frame(height: barAreaHeight, alignment: .bottom)
    }

    /// 归一化基准峰值（下限取阈值，避免除零 / 比例爆炸）。
    private var barScalePeak: Double {
        max(MinutelyPrecipitationEngine.peakPrecipitation(points) ?? 0,
            MinutelyPrecipitationEngine.precipitationThreshold)
    }

    // MARK: - 时间刻度（每 30 分钟一个，即隔点标注）

    private var axis: some View {
        HStack(spacing: 6) {
            ForEach(Array(points.enumerated()), id: \.element.id) { item in
                Text(axisLabel(index: item.offset, point: item.element))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func axisLabel(index: Int, point: MinutelyPrecipitationPoint) -> String {
        guard index % 2 == 0 else { return "" }
        if index == 0 { return "现在" }
        return timeText(point.time)
    }

    // MARK: - 页脚（开始/停止时序 + 峰值）

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let timingText {
                Text(timingText)
                    .font(.system(size: Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            if let peak = MinutelyPrecipitationEngine.peakPrecipitation(points),
               peak > MinutelyPrecipitationEngine.precipitationThreshold {
                Text("峰值约 \(String(format: "%.1f", peak)) mm/15min")
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    /// 「正在下雨，约 HH:mm 前后转小或停止」等；无法派生 → nil（该行隐藏）。
    private var timingText: String? {
        guard let timing = MinutelyPrecipitationEngine.timing(points) else { return nil }
        if timing.isRainingNow {
            if let stop = timing.stop {
                return "正在下雨，约 \(timeText(stop)) 前后转小或停止"
            }
            return "正在下雨，未来 2 小时持续"
        }
        guard let start = timing.start else { return nil }
        if let stop = timing.stop {
            return "约 \(timeText(start)) 开始，\(timeText(stop)) 前后停止"
        }
        return "约 \(timeText(start)) 开始，持续到窗口末"
    }

    /// 「HH:mm」——按选中城市时区渲染（`WeatherTimeFormatter` 内缓存格式器，不逐次新建）。
    private func timeText(_ date: Date) -> String {
        WeatherTimeFormatter.string(from: date, format: "HH:mm", timeZone: timeZone)
    }
}

//
//  HourlyWindChart.swift
//  ZhishengWeather（主 App target）  [D-C2]
//
//  风力可视化：未来约 24 小时的**平均风速**与**阵风**逐时并列。
//  数据取 `snapshot.hourly[].windSpeed`（m/s）与 `.windGusts`（m/s）——
//  **零新增网络请求**（P2 第 1 批已把这两个字段接进载荷）。
//
//  AC-C6（阵风与平均风速**视觉可区分**）：同一列里**两根柱 —— 实心 = 平均风速、
//  空心（描边）= 阵风**，空心高出实心的部分就是"阵风比平均大多少"。
//  两序列**共用同一把标尺**（窗口内两序列峰值为基准），故两根柱的高度可以直接比；
//  这一点与 `HourlyPrecipitationChart` 的"两把独立标尺"相反，是刻意的：
//  风速与阵风**同为 m/s**，只有同尺才谈得上比较。
//
//  ⚠️ **AC-C4（逐时风向）不做，且不许假装能做**（诚实红线）：
//  本项目的请求面（`OpenMeteoEndpoint.hourlyFields`）只含
//  `wind_speed_10m` / `wind_gusts_10m` / `apparent_temperature` /
//  `precipitation` / `temperature_2m` / `weather_code` / `precipitation_probability`，
//  **没有 `wind_direction_10m`** —— 逐时风向在数据面上**不存在**。
//  故本卡：
//    · **不画**逐时风向箭头/8 方位图标（画出来的每一点都会是编造的时间序列）；
//    · **不拿** `WeatherSnapshot.windDirection`（实况**单个当前值**）冒充逐时序列；
//    · 在页脚**如实告知**该字段暂未提供，而不是留白让人误以为"风向就是没有"。
//  要真正满足 AC-C4，必须先扩请求面（`hourly=wind_direction_10m`，属 Core/数据面任务），
//  本轮不动请求面，故 AC-C4 记为本卡未覆盖项。
//
//  单位（AC-C5）：风速/阵风渲染一律走**既有** `UnitPreference.displayWindSpeed(ms:)`
//  + `windSpeedSymbol()`（设置页写入 / 共享容器读取的单一真源），本文件不自建第二套
//  单位逻辑、不出现 "m/s" 字面量。
//
//  诚实纪律：`windSpeed` / `windGusts` 为 nil 的点**不画柱**（不是画 0）；
//  已知的 0.0 m/s 画 2pt 基线刻度（有数据、无风）。全 nil → **整块隐藏，不留空槽**。
//
//  @MainActor：与项目内其他 View 一致（SwiftUI 仅对 body 推断主 actor；且本卡时间
//  渲染经 @MainActor 的 `WeatherTimeFormatter`）。
//

import SwiftUI

/// 逐时风力图（实心＝平均风速 / 空心＝阵风）。
@MainActor
struct HourlyWindChart: View {

    /// 逐小时点（已按 now 起截取，≤ 24 条；与 `snapshot.hourly` 同源）。
    let points: [HourlyPoint]
    /// 时间渲染时区（D-4：选中城市时区；缺省设备时区）。
    var timeZone: TimeZone = .current

    /// 同列两根柱各自的宽度占列宽的比例（上限 0.4：同列两柱之间、相邻列之间都留白）。
    private static let multiBarWidthRatio: CGFloat = 0.38
    /// 同列两根柱的间距（pt）。
    private static let multiBarSpacing: CGFloat = 1.2
    /// 归一化基准下限（m/s）：微风时若按窗口峰值归一，柱高比例会失真。
    private static let minimumScalePeak: Double = 1
    /// 无风（0.0 m/s）的基线刻度高度（pt）——与之相对，nil **不画柱**。
    private static let calmBaselineHeight: CGFloat = 2

    @ViewBuilder
    var body: some View {
        // 无任何可用值 → 整块不渲染（不留空槽）。
        if Self.isDataInsufficient(points) {
            EmptyView()
        } else {
            card
        }
    }

    // MARK: - 卡片骨架

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            plot
            HourlySeriesAxisRow(labels: axisLabels)
            footer
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(Theme.divider, lineWidth: 0.5)
        )
    }

    /// 标题（右上角标注当前单位）+ 图例（AC-C6 的可辨识性由**填充方式 + 图例**共同保证）。
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "wind")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
                Text("风力")
                    .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 8)
                // 单位符号来自既有 UnitPreference（AC-C5），随设置页切换。
                Text("单位 \(UnitPreference.windSpeedSymbol())")
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.secondaryText)
            }
            Text("未来 \(points.count) 小时 · 实心＝平均风速 · 空心＝阵风（同标尺）")
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    // MARK: - 绘图区

    private var plot: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = HourlySeriesChartLayout.plotHeight
            ZStack {
                plotBackground
                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    column(index: index, point: point, width: width, height: height)
                }
            }
            .frame(width: width, height: height)
        }
        .frame(height: HourlySeriesChartLayout.plotHeight)
    }

    /// 绘图区底槽（给出"零线"的视觉基准）。
    private var plotBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Theme.divider.opacity(0.12))
    }

    /// 单列：左实心（平均风速）+ 右空心（阵风），底部对齐、整列居中于柱心。
    private func column(index: Int, point: HourlyPoint, width: CGFloat, height: CGFloat) -> some View {
        let barWidth = self.barWidth(width: width)
        return HStack(alignment: .bottom, spacing: Self.multiBarSpacing) {
            speedBar(value: point.windSpeed, barWidth: barWidth, height: height)
            gustBar(value: point.windGusts, barWidth: barWidth, height: height)
        }
        .frame(height: height, alignment: .bottom)
        .position(x: HourlySeriesChartLayout.columnCenterX(index: index,
                                                          count: points.count,
                                                          width: width),
                  y: height / 2)
    }

    /// 平均风速柱（实心）。
    @ViewBuilder
    private func speedBar(value: Double?, barWidth: CGFloat, height: CGFloat) -> some View {
        if let metersPerSecond = value {
            Capsule()
                .fill(Theme.accent)
                .frame(width: barWidth,
                       height: barHeight(metersPerSecond: metersPerSecond, plotHeight: height))
        }
    }

    /// 阵风柱（空心描边）。
    @ViewBuilder
    private func gustBar(value: Double?, barWidth: CGFloat, height: CGFloat) -> some View {
        if let metersPerSecond = value {
            Capsule()
                .stroke(Theme.accentSecondary, lineWidth: 1)
                .frame(width: barWidth,
                       height: barHeight(metersPerSecond: metersPerSecond, plotHeight: height))
        }
    }

    // MARK: - 页脚（峰值读数 + 未覆盖项如实说明）

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let peak = peakValue(\.windSpeed) {
                Text("峰值 平均风速 \(valueText(peak.metersPerSecond))（\(hourText(peak.time))）")
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.secondaryText)
            }
            if let peak = peakValue(\.windGusts) {
                Text("峰值 阵风 \(valueText(peak.metersPerSecond))（\(hourText(peak.time))）")
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.secondaryText)
            }
            // AC-C4 未覆盖：逐时风向在本项目的请求面里不存在（见文件头）。
            // 这里**如实说"暂未提供"**，不画箭头、不用实况单值冒充时间序列。
            Text("逐时风向暂未提供")
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    // MARK: - 派生（纯计算，无副作用）

    /// 轴标签：首格「现在」+ 每 6 小时一格（与降水图共用同一派生，口径一致）。
    private var axisLabels: [String] {
        HourlySeriesAxis.labels(times: points.map(\.time), timeZone: timeZone)
    }

    /// 两根柱各自的宽度（列宽的 `multiBarWidthRatio`，下限 1.5pt 保证描边可见）。
    private func barWidth(width: CGFloat) -> CGFloat {
        let columnWidth = HourlySeriesChartLayout.columnWidth(count: points.count, width: width)
        return max(1.5, columnWidth * Self.multiBarWidthRatio)
    }

    /// 柱高：两序列**共用**的归一化基准（窗口内两序列最大值，下限 1 m/s）。
    /// - 0.0 m/s：2pt 基线刻度（有数据、无风）；
    /// - nil：**不进入本函数**（调用点不画柱）→ nil 与 0.0 在屏上可区分。
    private func barHeight(metersPerSecond: Double, plotHeight: CGFloat) -> CGFloat {
        guard metersPerSecond > 0 else { return Self.calmBaselineHeight }
        let ratio = min(max(metersPerSecond / Self.scalePeak(points), 0), 1)
        return max(plotHeight * CGFloat(ratio), 3)
    }

    /// 峰值读数（指定字段的最大值与所在时刻）；该字段全 nil → nil。
    private func peakValue(_ field: KeyPath<HourlyPoint, Double?>) -> (metersPerSecond: Double, time: Date)? {
        let values = points.compactMap { point -> (metersPerSecond: Double, time: Date)? in
            guard let metersPerSecond = point[keyPath: field] else { return nil }
            return (metersPerSecond, point.time)
        }
        return values.max { $0.metersPerSecond < $1.metersPerSecond }
    }

    /// 数值 + 单位符号：走**既有** `UnitPreference` 换算路径（AC-C5），
    /// 与主屏指标格的「风速 / 阵风」两格同源，单位切换时两者同步。
    private func valueText(_ metersPerSecond: Double) -> String {
        let value = UnitPreference.displayWindSpeed(ms: metersPerSecond)
        return "\(String(format: "%.1f", value)) \(UnitPreference.windSpeedSymbol())"
    }

    // MARK: - 纯函数（可静态推演）

    /// 整块隐藏判据：`hourly` 为空，或窗口内**风速与阵风全为 nil**（无任何可用值）。
    /// 任一项有值即渲染（只画有值的那一项，另一项留空 —— 不补 0）。
    static func isDataInsufficient(_ points: [HourlyPoint]) -> Bool {
        guard !points.isEmpty else { return true }
        return !points.contains { $0.windSpeed != nil || $0.windGusts != nil }
    }

    /// 两序列共用的归一化基准：窗口内 `windSpeed` / `windGusts` 的最大值，
    /// 下限 `minimumScalePeak`（避免微风窗口里柱高比例失真）。
    static func scalePeak(_ points: [HourlyPoint]) -> Double {
        let values: [Double] = points.flatMap { point in
            [point.windSpeed, point.windGusts].compactMap { $0 }
        }
        return max(values.max() ?? 0, minimumScalePeak)
    }

    // MARK: - 时间文案

    /// 「H时」——按选中城市时区渲染（`WeatherTimeFormatter` 内缓存格式器）。
    private func hourText(_ date: Date) -> String {
        WeatherTimeFormatter.string(from: date, format: "H时", timeZone: timeZone)
    }
}

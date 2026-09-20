//
//  HourlyPrecipitationChart.swift
//  ZhishengWeather（主 App target）  [D-C1]
//
//  逐时降水图：未来约 24 小时里，**降水量（柱，mm）** 与 **降水概率（折线+点，%）**
//  同图并列。数据取 `snapshot.hourly[].precipitation`（mm）与
//  `.precipitationProbability`（%），**零新增网络请求**。
//
//  为什么是"柱 + 折线"而不是一根柱（AC-C1）：
// 毫米与百分比是**两种量纲**，叠成一根柱只能是骗人（柱高既代表 mm 又代表 %，
//  读者无从分辨读的是哪一把尺）。故本图用**两把各自明示的独立标尺**：
//   - 柱（实心，accentSecondary）：降水量 mm，**窗口内峰值归一**；
//   - 折线 + 点（accent）：降水概率 %，**固定 0…100% 标尺**（不归一，故"50% 恒在半高"）。
//  两把尺的读数分别由页脚的「峰值 X.X mm」「最高降水概率 X%」两个**带时刻的数值**锚定，
//  不靠读者猜刻度。
//
//  绘制方式（**不用 Swift Charts**，理由如下，属对 ARCH §2 的一处显式偏离）：
//   - Swift Charts **不支持逐 mark 的 Y 轴刻度**：mm 柱与 % 折线要各自成立，只能把两
//     序列都归一化到同一 [0,1] 域再把 Y 轴藏掉——那正好把"两把明示的尺"变成"两把
//     隐含的尺"，与 AC-C1 的意图相反；
//   - 本仓已有同款手绘范式（`MinutelyPrecipitationCard` 的柱状序列、
//     `EnsembleUncertaintyCard` 的"两把独立标尺并列"），沿用同一画法可保持主屏视觉一致；
//   - 本机（Windows）**无法编译**，手绘只用 SwiftUI 基础 API，编译风险低于 Charts 组合 API。
//  故：只依赖 SwiftUI 基础 API（不引 Charts 框架），全程系统框架、零三方依赖。
//
//  诚实纪律：
//   - **nil ≠ 0**：`precipitation == nil`（服务端未返回 / 元素 null / 旧缓存无键）
//     **不画柱**；`0.0`（有数据、没下雨）画 2pt 基线刻度 —— 两者在屏上可区分。
//     `precipitationProbability` 同理：nil 处**折线断开**，绝不跨缺口连线。
//   - AC-C2 全窗口无降水 → 显示**完整晴窗**（整块底色 + 如实文案），不是空白、不是隐藏；
//   - AC-C3 数据不足 → **整块隐藏，不留空槽**（判据见 `isDataInsufficient`）。
//   - 判定阈值**复用** Core 既有的 `MinutelyPrecipitationEngine.precipitationThreshold`，
//     不新起第二个"算不算下雨"的数字（同一口径只有一处真源）。
//
//  @MainActor：与项目内其他 View 一致（SwiftUI 仅对 body 推断主 actor；且本卡时间
//  渲染经 @MainActor 的 `WeatherTimeFormatter`）。
//

import SwiftUI

/// 逐时降水图（柱＝mm / 折线＝%）。
@MainActor
struct HourlyPrecipitationChart: View {

    /// 逐小时点（已按 now 起截取，≤ 24 条；与 `snapshot.hourly` 同源）。
    let points: [HourlyPoint]
    /// 时间渲染时区（D-4：选中城市时区；缺省设备时区）。
    var timeZone: TimeZone = .current

    /// 降水判定阈值（mm/h）——**复用**既有常量，不另起数字。
    private static var precipitationThreshold: Double {
        MinutelyPrecipitationEngine.precipitationThreshold
    }

    @ViewBuilder
    var body: some View {
        // AC-C3：数据不足 → 整块不渲染（不留空槽）。
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

    /// 标题 + 图例（图例逐字写明两把尺的量纲，AC-C1 的"可分辨"由**编码 + 图例**共同保证）。
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "cloud.rain.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accentSecondary)
                Text("逐时降水")
                    .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
            }
            Text("未来 \(points.count) 小时 · 柱＝降水量（mm）· 折线＝降水概率（%）")
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    // MARK: - 绘图区

    /// 绘图区：底槽 + （干窗时）晴窗底色 + 柱 + 概率折线/点。
    /// 所有子层共用同一套列几何（`HourlySeriesChartLayout`），故柱心与折线顶点严格对齐。
    private var plot: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = HourlySeriesChartLayout.plotHeight
            ZStack {
                plotBackground
                if isDryWindow {
                    dryWindowBand(width: width, height: height)
                }
                precipitationBars(width: width, height: height)
                probabilityPolyline(width: width, height: height)
                probabilityDots(width: width, height: height)
                if isDryWindow {
                    dryWindowLabel
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

    /// 降水量柱层：**仅对有值的点**画柱（nil 不画；0.0 画基线刻度，见 `barHeight`）。
    @ViewBuilder
    private func precipitationBars(width: CGFloat, height: CGFloat) -> some View {
        ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
            if let millimeters = point.precipitation {
                bar(index: index,
                    millimeters: millimeters,
                    width: width,
                    height: height)
            }
        }
    }

    /// 单根柱：实心圆角矩形，底部对齐（柱底贴在零线）。
    private func bar(index: Int, millimeters: Double, width: CGFloat, height: CGFloat) -> some View {
        let barHeight = Self.barHeight(millimeters: millimeters,
                                      plotHeight: height,
                                      peak: barScalePeak)
        let isWet = millimeters > Self.precipitationThreshold
        return RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(isWet ? Theme.accentSecondary : Theme.divider)
            .frame(width: HourlySeriesChartLayout.barWidth(count: points.count, width: width),
                   height: barHeight)
            .position(x: HourlySeriesChartLayout.columnCenterX(index: index,
                                                              count: points.count,
                                                              width: width),
                      y: height - barHeight / 2)
    }

    /// 概率折线层（描边 + 圆头圆角）。
    private func probabilityPolyline(width: CGFloat, height: CGFloat) -> some View {
        probabilityPath(width: width, height: height)
            .stroke(Theme.accent,
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    /// 概率折线路径：**nil 处断开**（绝不跨缺口连线；与 AQI 曲线同款诚实纪律）。
    private func probabilityPath(width: CGFloat, height: CGFloat) -> Path {
        var path = Path()
        var hasPreviousPoint = false
        for (index, point) in points.enumerated() {
            guard let probability = point.precipitationProbability else {
                hasPreviousPoint = false
                continue
            }
            let x = HourlySeriesChartLayout.columnCenterX(index: index,
                                                          count: points.count,
                                                          width: width)
            let y = Self.probabilityY(percent: probability, plotHeight: height)
            if hasPreviousPoint {
                path.addLine(to: CGPoint(x: x, y: y))
            } else {
                path.move(to: CGPoint(x: x, y: y))
            }
            hasPreviousPoint = true
        }
        return path
    }

    /// 概率折线上的顶点（让"有值的点"独立可辨，也使断口一眼可见）。
    @ViewBuilder
    private func probabilityDots(width: CGFloat, height: CGFloat) -> some View {
        ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
            if let probability = point.precipitationProbability {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 3, height: 3)
                    .position(x: HourlySeriesChartLayout.columnCenterX(index: index,
                                                                      count: points.count,
                                                                      width: width),
                              y: Self.probabilityY(percent: probability, plotHeight: height))
            }
        }
    }

    /// 晴窗底色（AC-C2）：整块铺满绘图区，"无降水"是**画出来的完整晴窗**，不是空白。
    private func dryWindowBand(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Theme.accent.opacity(0.10))
            .frame(width: width, height: height)
    }

    /// 晴窗文案（AC-C2 要求的明确标注）。
    ///
    /// 小时数取**有降水数据的时数**（`validPrecipitationCount`）而非固定 24：
    /// 服务端截断 / 旧缓存可能给出不足 24 条，那时说"24 小时"就是编造覆盖面。
    /// 数据齐（24 条有值）时本行逐字渲染为「未来 24 小时无明显降水」。
    private var dryWindowLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 12))
            Text("未来 \(validPrecipitationCount) 小时无明显降水")
                .font(.system(size: Theme.FontSize.caption, weight: .medium))
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Theme.surface.opacity(0.85), in: Capsule())
    }

    // MARK: - 页脚（两把标尺的数值锚点）

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let peak = peakPrecipitation {
                // mm 文案走既有换算责任层 `PrecipitationFormatter`（单位由它锁定 mm）。
                Text("峰值 \(PrecipitationFormatter.text(fromMillimeters: peak.millimeters))（\(hourText(peak.time))）")
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.secondaryText)
            }
            if let maximum = maxProbability {
                Text("最高降水概率 \(Int(maximum.percent.rounded()))%（\(hourText(maximum.time))）")
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    // MARK: - 派生（纯计算，无副作用）

    /// 轴标签：首格「现在」+ 每 6 小时一格（共用 `HourlySeriesAxis`，与风力图同口径）。
    private var axisLabels: [String] {
        HourlySeriesAxis.labels(times: points.map(\.time), timeZone: timeZone)
    }

    /// 有降水数据的时数（`precipitation` 非 nil 的点数；0.0 也算"有数据"）。
    private var validPrecipitationCount: Int {
        points.compactMap(\.precipitation).count
    }

    /// 窗口内峰值降水量及其时刻：只统计**超过阈值**的点（全 0.0 → nil）。
    private var peakPrecipitation: (millimeters: Double, time: Date)? {
        let wet = points.compactMap { point -> (millimeters: Double, time: Date)? in
            guard let millimeters = point.precipitation,
                  millimeters > Self.precipitationThreshold else { return nil }
            return (millimeters, point.time)
        }
        return wet.max { $0.millimeters < $1.millimeters }
    }

    /// 窗口内最高降水概率及其时刻（nil 不参与）。
    private var maxProbability: (percent: Double, time: Date)? {
        let values = points.compactMap { point -> (percent: Double, time: Date)? in
            guard let probability = point.precipitationProbability else { return nil }
            return (probability, point.time)
        }
        return values.max { $0.percent < $1.percent }
    }

    /// 干窗（AC-C2）：窗口内没有任何超过阈值的降水。
    /// 全部有效值都是 0.0 也算干窗（0.0 = 有数据且没下雨，如实体现在"晴窗 + 文案"上）。
    private var isDryWindow: Bool {
        peakPrecipitation == nil
    }

    /// 柱高归一化基准（下限取阈值，避免除零与比例爆炸）。
    private var barScalePeak: Double {
        max(peakPrecipitation?.millimeters ?? 0, Self.precipitationThreshold)
    }

    // MARK: - 纯函数（可静态推演）

    /// 整块隐藏判据（AC-C3 + ARCH §2「有效点不足」）。
    ///
    /// - `hourly` 为空 → 隐藏；
    /// - 所有 `precipitation` 都是 nil（有概率也**不**顶替降水量：那不是这张图承诺的量）→ 隐藏；
    /// - 有值点 < 4 → 不足成图 → 隐藏；
    ///   **例外**：稀疏窗口里**确有降水**（某点 > 阈值）时仍显示 —— 把真实降水藏起来
    ///   比"图太短"更严重（隐藏的是数据，不是排版）。
    static func isDataInsufficient(_ points: [HourlyPoint]) -> Bool {
        guard !points.isEmpty else { return true }
        let valid = points.compactMap(\.precipitation)
        guard !valid.isEmpty else { return true }
        if valid.count < 4, !valid.contains(where: { $0 > precipitationThreshold }) {
            return true
        }
        return false
    }

    /// 柱高：mm 按窗口峰值归一化到绘图区高度。
    /// - 超过阈值：至少 3pt（保证"下了"看得见）；
    /// - 已知 0.0：2pt 基线刻度（有数据、没下雨）；
    /// - **nil 不进入本函数**（调用点不画柱）→ nil 与 0.0 在屏上可区分。
    static func barHeight(millimeters: Double, plotHeight: CGFloat, peak: Double) -> CGFloat {
        guard millimeters > precipitationThreshold else { return 2 }
        guard peak > 0 else { return 3 }
        let ratio = min(max(millimeters / peak, 0), 1)
        return max(plotHeight * CGFloat(ratio), 3)
    }

    /// 概率 → y 坐标（**固定 0…100% 标尺**，与柱的"窗口峰值归一"是两把独立的尺）。
    static func probabilityY(percent: Double, plotHeight: CGFloat) -> CGFloat {
        let clamped = min(max(percent, 0), 100)
        return plotHeight * (1 - CGFloat(clamped) / 100)
    }

    // MARK: - 时间文案

    /// 「H时」——按选中城市时区渲染（`WeatherTimeFormatter` 内缓存格式器）。
    private func hourText(_ date: Date) -> String {
        WeatherTimeFormatter.string(from: date, format: "H时", timeZone: timeZone)
    }
}

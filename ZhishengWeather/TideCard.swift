//
//  TideCard.swift
//  ZhishengWeather（主 App target）
//
//  未来 24 小时**天文潮**曲线卡（数据源：Open-Meteo Marine `minutely_15`，
//  `sea_level_height_msl − invert_barometer_height`，详见 `TideConditions` 文件头）。
//
//  ═══════════════════════════════════════════════════════════════════════
//  ⚠️ 本卡的**语义标注**是硬要求，不是可选润色
//  ═══════════════════════════════════════════════════════════════════════
//  设计稿曾说这个量是"天文潮（不含气压/风暴增水）"，**实测+ 官方文档不支持**：
//  `sea_level_height_msl` 逐字定义是"ocean tides + **the inverted barometer
//  effect** + sea surface height + global mean steric variation + global mean
//  mass volume variation"，基准面是 **global mean sea level, not the lowest
//  astronomical tide**。故本卡：
//
//   ① 标题写「**天文潮**」，**不**写「潮高 / 当前水位」（后者会被读成实测水位）；
//   ② 曲线画的是**扣掉倒压效应后**的分量（`TideForecast.astronomical`），
//      页脚**明写**这是"已扣除气压效应"的天文潮分量；
//   ③ 页脚标注基准面为**全球平均海平面（MSL）**，并写明
//      **不可与官方潮汐表（LAT 基准）直接比对**、**不可用于航海**
//      （文档逐字 "not suitable for coastal navigation"）。
//
//  ── 为什么曲线取 15 分钟粒度 ───────────────────────────────────────────
//  潮是周期约 12.4h 的**半日潮**，高潮/低潮**极值时刻**是这张卡的核心信息。
//  实测 `minutely_15` 给 672 点（96 点/天），极值时刻可收敛到 ±15 分钟；
//  `hourly`（24 点/天）只能定到 ±1 小时。故取 15 分钟。
//
//  ── 绘制方式（复用既有范式，**不引 Swift Charts**）────────────────────
//  沿用 `AirQualityPollutantCard` 的手绘几何（`TideCurveLayout` 纯几何 +
//  视图只描点连线）与 `HourlySeriesAxisRow` 等宽时间轴，理由与那张卡相同：
//  本机Windows 无法编译，手绘只用 SwiftUI 基础 API，编译风险最低。
//
//  ── 空态纪律 ─────────────────────────────────────────────────────────
//  · **内陆城市整卡不渲染**（`displayedTide` 返回 nil → 本卡不进 ViewBuilder），
//    **不是**渲染"暂无潮汐"—— 那会让内陆用户以为数据缺失；
//  · 窗内有效点不足 → 同样整卡不渲染（`EmptyView`，不留空槽）。
//
//  @MainActor：与项目内其他 View 一致（SwiftUI 仅对 body 推断主 actor；
//  且本卡时刻渲染经 @MainActor 的 `WeatherTimeFormatter`）。
//

import Foundation
import SwiftUI

// MARK: - 纯几何（不依赖视图，可单测）

/// 潮汐曲线的绘制几何（一条折线 + 若干点+ 极值标记位置）。
///
/// ⚠️ 纵轴**双向**（含负值）且**必须含 0 线**：实测天文潮分量范围
///   大连 **-0.53…+1.40 m**、厦门 **-2.32…+3.25 m** —— 负值是常态
///   （半日潮每天两次越过平均海平面），所以纵轴**不能**像既有污染物图那样
///   取 `[0, peak]`：那会把半张曲线画到画布外。
///   故这里取 `[min(0, 实际最小), max(0, 实际最大)]`—— **0 恒在域内**。
struct TideCurveLayout {

    /// 一段折线（两端都有值）。
    struct Segment: Identifiable {
        let id: Int
        let start: CGPoint
        let end: CGPoint
    }

    /// 一个有值点。
    struct Dot: Identifiable {
        let id: Int
        let position: CGPoint
    }

    /// 要绘制的折线段（缺口处无段 —— 绝不跨缺口连线）。
    var segments: [Segment] = []
    /// 要绘制的有值点。
    var dots: [Dot] = []
    /// 纵轴下限（≤ 0，恒含 0）。
    var lowerBound: Double = 0
    /// 纵轴上限（≥ 0，恒含 0）。
    var upperBound: Double = 0
    /// 是否**至少有一个可画点**（全 nil → 调用方整卡隐藏）。
    var hasDrawableValue: Bool = false

    /// 曲线区上下留白（避免点/线在纵轴两端被裁掉半线宽）。
    static let verticalInset: CGFloat = 3

    /// - Parameters:
    ///   - values: 逐点天文潮分量（nil = 该点缺测）。
    ///   - size: 绘制区尺寸。
    init(values: [Double?], size: CGSize) {
        let drawable = values.compactMap { $0 }
        hasDrawableValue = !drawable.isEmpty
        guard hasDrawableValue, size.width > 0, size.height > 0 else { return }

        // ⚠️ 纵轴**双向且恒含 0**（负潮高是常态，见类型注释）。
        let lowest = drawable.min() ?? 0
        let highest = drawable.max() ?? 0
        var low = min(0, lowest)
        var high = max(0, highest)
        // 全平（最低 == 最高 == 0）时给一个最小可视域，避免除零与"贴边不可见"。
        if high - low < 0.01 {
            low = -0.05
            high = 0.05
        }
        lowerBound = low
        upperBound = high

        let count = values.count
        let stepX = size.width / CGFloat(count)
        let inset = Self.verticalInset
        let plotHeight = max(size.height - inset * 2, 1)
        let span = high - low
        func position(index: Int, value: Double) -> CGPoint {
            // 双保险钳到域内：纵使上游漏了净化，也不让异常值把曲线顶出画布。
            let clamped = min(max(value, low), high)
            let ratio = (clamped - low) / span
            return CGPoint(x: (CGFloat(index) + 0.5) * stepX,
                           y: inset + plotHeight * (1 - CGFloat(ratio)))
        }

        for index in 0..<count {
            guard let value = values[index] else { continue }
            dots.append(Dot(id: index, position: position(index: index, value: value)))
            // 只有下一个点也有值才成段 —— 缺测处断开（同AirQualityPollutantCard）。
            guard index + 1 < count, let next = values[index + 1] else { continue }
            segments.append(Segment(id: index,
                                    start: position(index: index, value: value),
                                    end: position(index: index + 1, value: next)))
        }
    }
}

// MARK: - 潮汐卡

/// 未来 24 小时天文潮曲线卡（含高潮/低潮极值标注）。
@MainActor
struct TideCard: View {

    /// 未来 24 小时窗口内的潮汐点（已由 `displayedTide` 截取）。
    let points: [TidePoint]

    /// 时间渲染时区（D-4：选中城市时区；缺省设备时区）。
    var timeZone: TimeZone = .current

    /// 曲线区高度（pt）。
    private let plotHeight: CGFloat = 64

    /// 窗内有效点数量下限（低于此值 → 整卡不渲染，不留空槽）。
    ///
    /// ⚠️ 阈值 **8** 个（15 分钟粒度 = 2 小时）：低于它曲线已无"潮汐"形状可言
    ///   （连一次完整的涨落都看不出），画出来只会误导。
    private static let minimumPoints = 8

    /// 时间轴标注间隔（点数）。24 × 15 分钟 = 6 小时。
    private static let axisLabelStep = 24

    /// 窗内天文潮分量序列（nil 保留 —— 缺口必须能被曲线看见）。
    private var values: [Double?] { points.map(\.astronomical) }

    /// 窗内时刻序列。
    private var times: [Date] { points.map(\.time) }

    /// 窗内极值（高低潮）。
    private var extremum: (high: [TideExtremum], low: [TideExtremum]) {
        TideForecast.extrema(in: points)
    }

    var body: some View {
        // 数据不足 → 整块不渲染（不留空槽），同 `HourlyPrecipitationChart` 纪律。
        if values.compactMap({ $0 }).count >= Self.minimumPoints {
            card
        } else {
            EmptyView()
        }
    }

    // MARK: - 卡片骨架

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            plot
            HourlySeriesAxisRow(labels: axisLabels)
            extremumFooter
            semanticsFooter
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(Theme.divider, lineWidth: 0.5)
        )
    }

    /// 标题：写「天文潮」，**不**写「潮高 / 水位」（语义边界，见文件头）。
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "water.waves")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
                Text("24 小时天文潮")
                    .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 8)
                Text("米（m）")
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    /// 曲线（几何全部由 `TideCurveLayout` 给出，视图只负责描点连线）。
    private var plot: some View {
        GeometryReader { geometry in
            let layout = TideCurveLayout(values: values, size: geometry.size)
            ZStack(alignment: .topLeading) {
                // 0 线（全球平均海平面基准）—— 实测负潮高是常态，故这条线常在中部。
                if layout.upperBound > 0 || layout.lowerBound < 0 {
                    zeroLine(in: geometry.size, upper: layout.upperBound, lower: layout.lowerBound)
                }
                ForEach(layout.segments) { segment in
                    Path { path in
                        path.move(to: segment.start)
                        path.addLine(to: segment.end)
                    }
                    .stroke(Theme.accent,
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                }
                ForEach(layout.dots) { dot in
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 2, height: 2)
                        .position(dot.position)
                }
            }
            .frame(width: geometry.size.width,
                   height: geometry.size.height,
                   alignment: .topLeading)
        }
        .frame(height: plotHeight)
    }

    /// 0 基准线（虚线、弱化）。
    ///
    /// ⚠️ 纵向位置**必须复用 `TideCurveLayout` 的同一套内边距与高度公式**
    ///   （`verticalInset` + `plotHeight`），否则这条 0 线与曲线对不上——
    ///   0 线画错位置会把"负潮高在 0 线下方"这个基本事实讲反。
    private func zeroLine(in size: CGSize, upper: Double, lower: Double) -> some View {
        let span = upper - lower
        guard span > 0, size.height > 0 else { return AnyView(EmptyView()) }
        let ratio = (0 - lower) / span
        let usable = size.height - TideCurveLayout.verticalInset * 2
        let y = TideCurveLayout.verticalInset + usable * (1 - CGFloat(ratio))
        return AnyView(
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            .stroke(Theme.divider,
                    style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
        )
    }

    /// 时间轴：复用既有 `HourlySeriesAxisRow`（等宽单元格 + 居中标签）。
    ///
    /// ⚠️ 标注间隔用 **24**（= 6 小时）而不是既有逐时图的 6：
    ///   15 分钟粒度下每6 格只有 1.5 小时，会标出 16 个时刻挤成一团。
    /// ⚠️ **不能取 96**：窗内正好 96 点，而半开窗 `[now, now+24h)` 的下标
    ///   只到 95 —— `index % 96 == 0` 仅index 0 成立，整条轴**只剩「现在」**
    ///   一个标签、其余 95 格全空（实测复核：该step 下非空标签数 = 1）。
    ///   24 → 恰好落在下标 0/24/48/72，得到「现在 / 6时 / 12时 / 18时」四个标签。
    private var axisLabels: [String] {
        let step = max(1, Self.axisLabelStep)
        var result: [String] = []
        result.reserveCapacity(times.count)
        for (index, time) in times.enumerated() {
            if index % step != 0 {
                result.append("")
            } else if index == 0 {
                result.append("现在")
            } else {
                // 走真实时刻格式化（不写死"+6h"）——窗若不是从整点起算，
                // 写死偏移会把时刻标错。
                result.append(WeatherTimeFormatter.string(from: time,
                                                         format: "H",
                                                         timeZone: timeZone))
            }
        }
        return result
    }

    /// 极值行：窗内**下一个**高潮与低潮（时刻 + 潮高）。
    private var extremumFooter: some View {
        HStack(spacing: 14) {
            extremumChip(title: "高潮",
                         extremum: extremum.high.first,
                         color: Theme.accent)
            extremumChip(title: "低潮",
                         extremum: extremum.low.first,
                         color: Theme.accentSecondary)
            Spacer(minLength: 0)
        }
    }

    /// 单个极值片（时刻 + 数值）。
    ///
    /// ⚠️ 窗内**没有**极值时显示「暂无」而不是 `--`：本窗数据是真实存在的，
    ///   只是这一窗恰好没出现局部极值（可能整窗单调），那不是缺测。
    private func extremumChip(title: String,
                              extremum: TideExtremum?,
                              color: Color) -> some View {
        let timeText = extremum.map {
            WeatherTimeFormatter.string(from: $0.time, format: "HH:mm", timeZone: timeZone)
        } ?? "暂无"
        let valueText = Self.heightText(extremum?.height)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(title)
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.secondaryText)
            }
            Text("\(timeText) · \(valueText)")
                .font(.system(size: Theme.FontSize.footnote, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
        }
    }

    /// 语义边界页脚（**硬要求**，理由见文件头）。
    ///
    /// 三句话各自对应一条不可省的边界：基准面 / 已扣除气压 / 不可航海。
    /// ⚠️ 用 `Text` + 换行而非拼接字符串：单表达式多段`+` 拼接易触发
    ///   Swift 类型检查超时（本仓血泪史之一）。
    private var semanticsFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("天文潮 = 海平面高度已扣除气压效应；基准面为全球平均海平面（非最低天文潮位），不可与官方潮汐表直接比对。")
                .font(.system(size: 9))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("数值为模式预报结果，非验潮站实测；近岸精度有限，不可用于航海。")
                .font(.system(size: 9))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 潮高文案（米，2 位小数）。nil → `--`（**不补 0**：缺测不是零潮）。
    private static func heightText(_ height: Double?) -> String {
        guard let height else { return "--" }
        return String(format: "%.2f m", height)
    }
}
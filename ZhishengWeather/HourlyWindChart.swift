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
//  ⚠️ **AC-C4（逐时风向）—— 已接入（P2 第二批 · AC-B17b）**：
//  上一版此处的说明是"请求面没有 `wind_direction_10m`，故不做、只如实占位"。
//  该缺口已补齐：`OpenMeteoEndpoint.hourlyFields` 追加了 `wind_direction_10m`
//  （**同一 query、不新增 URL，配额仍 ×1**），实测探针 72 条 / **0 个 null** / 6~360°。
//  本卡现在：
//    · 绘图区下方一行**逐时箭头**（`directionRow`），按「风的**去向**」旋转（`+180°`）；
//    · 页脚给出读图图例与**峰值风速那一小时**的 8 方位 + 角度值；
//    · `windDirection == nil` 的小时**该格留空**，**不影响**其风速柱（AC-C4b）；
//    · **仍然严禁**用 `snapshot.windDirection`（实况单值）填充逐时点（AC-C4c 红线）——
//      那等于拿一个时刻的值冒充整条时间序列。
//
//  ⚠️ 每列**只画箭头、不写中文**：24 列时每列可用宽度仅约 13pt，而「西南」两字在
//  9pt 下需约 18pt，逐列写中文必然与邻列压字。8 方位文字与角度值改由页脚承载。
//
//  单位（AC-C5）：风速/阵风渲染一律走**既有** `UnitPreference.displayWindSpeed(ms:)`
//  + `windSpeedSymbol()`（设置页写入 / 共享容器读取的单一真源），本文件不自建第二套
//  单位逻辑、不出现 "m/s" 字面量。（风向是**角度**，与 `wind_speed_unit` 无关，
//  **不参与**任何单位换算 —— 这也是它没有换算风险的原因。）
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
            directionRow
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

    // MARK: - 逐时风向行（P2 · AC-B17b / AC-C4）

    /// 风向行高度。
    private static let directionRowHeight: CGFloat = 20

    /// 逐时风向箭头行。
    ///
    /// **为什么单独成行、不叠加在柱上**：24 列时每列仅约 13pt，且柱高不一，
    /// 把箭头叠上去必然互相遮挡、也压住柱子。放在绘图区下方既不动已调好的柱几何，
    /// 也保证可读。
    ///
    /// **为什么每列只画箭头、不写 8 方位中文**：每列可用宽度约 13pt，
    /// 而「西南」两字在 9pt 字号下约需 18pt —— 逐列写中文必然与邻列压字。
    /// 故 8 方位文字与角度数值放到页脚（指向**峰值风速那一小时**，如实标注时段），
    /// 满足 AC-C4 的「8 方位 + 角度数值」，同时不牺牲可读性。
    ///
    /// 纪律：
    /// - 箭头按「风的**去向**」旋转（气象风向是「风**来向**」，故 `+180°` 才是箭头指向）；
    ///   页脚图例逐字写明这一约定，避免读图歧义。
    /// - `windDirection == nil` 的小时 → **该格留空**（AC-C4b：绝不补 0°/北、绝不插值），
    ///   且**不影响**该小时的风速柱。
    /// - **绝不**用 `snapshot.windDirection`（实况单值）兜底（AC-C4c 红线）。
    @ViewBuilder
    private var directionRow: some View {
        if points.contains(where: { $0.windDirection != nil }) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                        if let degrees = point.windDirection {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.accentSecondary)
                                .rotationEffect(.degrees(degrees + 180))
                                .position(x: HourlySeriesChartLayout.columnCenterX(index: index,
                                                                                  count: points.count,
                                                                                  width: width),
                                          y: Self.directionRowHeight / 2)
                        }
                    }
                }
                .frame(width: width, height: Self.directionRowHeight)
            }
            .frame(height: Self.directionRowHeight)
            .accessibilityLabel("逐时风向")
        }
    }

    /// 峰值风速那一小时的风向文案（8 方位 + 角度值）；无可用风向 → nil（整行不渲染）。
    ///
    /// 取"峰值风速时"而非自行算"主导风向"：主导风向需要圆周平均或众数，
    /// 用本文件的既有数据算出来会是一个**我们自己定义的量**，不如如实报出
    /// "风速最大那一刻的风向" —— 它是原始值，可核验、不含我们引入的口径。
    private var peakWindDirectionText: String? {
        guard let peak = peakValue(\.windSpeed) else { return nil }
        guard let point = points.first(where: { $0.windSpeed == peak.metersPerSecond }),
              let degrees = point.windDirection else { return nil }
        return "峰值风速时 \(WindDirectionFormatter.text(from: degrees)) \(Int(degrees.rounded()))°"
    }

    /// 单列：左实心（平均风速）+ 右空心（阵风），底部对齐、整列居中于柱心。
    private func column(index: Int, point: HourlyPoint, width: CGFloat, height: CGFloat) -> some View {        let barWidth = self.barWidth(width: width)
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
            // P2 · AC-B17b：逐时风向已接入（`hourlyFields` 追加 `wind_direction_10m`，
            // 探针实测 72 条 / 0 null / 6~360°）。此处给出**读图约定**与**峰值时刻的方位**。
            // 图例必须写清箭头约定：气象风向是「风**来向**」，而箭头画的是「风**去向**」
            // （`+180°`），不写明就会读反 180°。
            if peakWindDirectionText != nil {
                Text("箭头 = 风的去向（风向为来向）")
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.secondaryText)
                if let direction = peakWindDirectionText {
                    Text(direction)
                        .font(.system(size: Theme.FontSize.footnote))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
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

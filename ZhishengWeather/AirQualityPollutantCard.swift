//
//  AirQualityPollutantCard.swift
//  ZhishengWeather（主 App target）
//
//  空气质量**六污染物分项**卡（P2 · AC-C5b）：未来 24 小时逐时趋势，六行各一项。
//
//  ── 与既有 `AirQualityCard` 的分工（**只做加法，绝不重做**）──
//  `AirQualityCard`（既有，本轮**不改一个字符**）负责：当前 AQI 大字 + 六档等级名 +
//  主导污染物 + 六个**当前值**分格 + 欧标 AQI + **AQI** 24h 趋势曲线。
//  本卡**只补它没有的那一层**：六种污染物**各自的** 24 小时逐时走势。
//  为什么值得单列一卡：AQI 是**综合指数**（已按最差项定档），看不出"是 PM 拉高还是
//  O₃ 拉高"；而用户在"要不要开窗/要不要戴口罩"这类决策上需要的正是**分项**信息。
//
//  ── 六项的实测事实（2026-10-06探针，北京 39.9/116.4，`forecast_hours=24`）──
//  六键全部存在、各 24 条、**0 个 null**；峰值：pm10 157.9 / pm2_5 144.8 /
//  carbon_monoxide 2310.0 / nitrogen_dioxide 92.4 / sulphur_dioxide 16.6 / ozone 42.0（μg/m³）。
//
//  ── ⚠️ **绝不同轴**（本卡最容易犯的错）──
//  CO 峰值 2310 是其余污染物峰值的**一到两个数量级**。若六行共用一条纵轴，
//  SO₂（16.6）与 O₃（42）会被压成贴着底的平线，看起来"毫无变化"——那是**坐标系骗人**。
//  故每行**独立按自身峰值归一**（`PollutantRowLayout`），并在行尾标出该行峰值，
//  让"这条线多高"始终可读。
//
//  ── 诚实纪律 ──
//  - 某污染物**全序列缺测** → 该行**整行隐藏**，绝不显示"--"冒充；
//  - 序列中**部分**缺测 → 该行仍显示，但曲线在缺测处**断开**
//    （`PollutantRowLayout` 只连接相邻**都有值**的两点：把缺口连起来等于把
//    "没测到"画成"污染物平稳"，是本仓红线）；
//  - `0 μg/m³` 是合法读数，成点成段，**不得**当缺失；
//  - 时间轴只说「现在 / 24 小时后」**相对**表述，不说钟点：本卡只收到
//    `AqiHourlyPoint`（不含时区），用设备时区渲染异地城市的钟点会说谎（D-4）。
//
//  ── 配色 ──
//  复用既有 `Theme`（surface / divider / accentSecondary）与
//  `AirQualityCard.color(for:)` 的 AQI 档位色（按该行**该小时**的 usAqi 着色），
//  **不引入新配色体系**。
//

import Foundation
import SwiftUI

// MARK: - 纯几何（不依赖视图，可单测）

/// 单个污染物的 24h 迷你趋势几何（一条折线 + 若干点）。
///
/// 与 `AqiTrendLayout` 同款纪律（断点断开、`0` 成点、域内网格线），
/// 但**逐行独立归一**：纵轴上限取**本行自身峰值**（`domainCeiling`），
/// 故六行之间**不可比**（这是刻意的：见文件头「绝不同轴」）。
struct PollutantRowLayout {

    /// 一段折线（两端都有值）。
    struct Segment: Identifiable {
        /// 段左端点下标（同一序列内唯一）。
        let id: Int
        let start: CGPoint
        let end: CGPoint
    }

    /// 一个有值点。
    struct Dot: Identifiable {
        let id: Int
        let position: CGPoint
    }

    /// 本行要绘制的折线段（缺口处无段）。
    var segments: [Segment]
    /// 本行要绘制的有值点。
    var dots: [Dot]
    /// 本行纵轴上限（= 本行自身峰值；见 `domainCeiling`）。
    var upperBound: Double
    /// 本行是否**至少有一个可画点**（全 nil → 调用方整行隐藏）。
    var hasDrawableValue: Bool

    /// 曲线区上下留白（避免点/线在纵轴两端被裁掉半线宽）。
    private static let verticalInset: CGFloat = 2

    /// 纵轴上限：**直接取本行自身峰值**。
    ///
    /// ⚠️ 曾试过向上取整到"好看刻度"（1/2/5×10ⁿ），实测有害：CO 峰值 2310 会被
    /// 取整到 5000，峰值点只跑到画布 46% 高度，**白白浪费一半纵向空间**，
    /// 反而让"峰满域"这个可读性目标落空。故此处不做任何取整。
    ///
    /// 不取整也不影响可读性：本卡**不画纵轴刻度与网格线**，行尾用数字直接标出
    /// 该行峰值（见 `peakText`），读者要读的是**形状**（起伏）而不是刻度对齐；
    /// 而六行**本就不可比**（见文件头「绝不同轴」），强行对齐刻度只会误导。
    ///
    /// - 全序列无值 / 峰值非正 → 返回 1（避免除零，让退化输入不产生 NaN 坐标）。
    static func domainCeiling(_ peak: Double) -> Double {
        guard peak.isFinite, peak > 0 else { return 1 }
        return peak
    }

    /// - Parameters:
    ///   - values: 本行逐时浓度序列（元素可为 nil = 该小时缺测）。
    ///   - size: 绘制区尺寸。
    init(values: [Double?], size: CGSize) {
        let count = values.count
        let peak = values.compactMap { $0 }.max() ?? 0
        let upper = Self.domainCeiling(peak)
        self.upperBound = upper
        self.hasDrawableValue = values.contains { $0 != nil }

        guard count > 0, size.width > 0, size.height > 0 else {
            self.segments = []
            self.dots = []
            return
        }

        let stepX = size.width / CGFloat(count)
        let inset = Self.verticalInset
        let plotHeight = max(size.height - inset * 2, 1)
        let unitY = plotHeight / CGFloat(upper)
        func position(index: Int, value: Double) -> CGPoint {
            // 下限钳到 0：负浓度在 mapper 已净化，这里是双保险，
            // 免得一个异常值把整行曲线顶到画布外。
            let clamped = min(max(value, 0), upper)
            return CGPoint(x: (CGFloat(index) + 0.5) * stepX,
                           y: inset + plotHeight - CGFloat(clamped) * unitY)
        }

        var segments: [Segment] = []
        var dots: [Dot] = []
        for index in 0..<count {
            guard let value = values[index] else { continue }
            dots.append(Dot(id: index, position: position(index: index, value: value)))
            // 只有下一个点也有值才成段——缺测处断开（文件头纪律）。
            guard index + 1 < count, let next = values[index + 1] else { continue }
            segments.append(Segment(id: index,
                                    start: position(index: index, value: value),
                                    end: position(index: index + 1, value: next)))
        }

        self.segments = segments
        self.dots = dots
    }
}

// MARK: - 六污染物分项卡

/// 分项卡的一行 = 一种污染物。
///
/// ⚠️ **刻意声明在文件顶层、而不是嵌在 `@MainActor` 的视图类型里**：
/// 嵌套类型会**继承**外层的全局actor 隔离，而 `Identifiable` 派生的 ID 会被
/// `ForEach` 在视图求值时用到 —— 让纯数据行类型沾上主actor 隔离只会带来
/// 无谓的并发注解负担与"非隔离上下文求值"风险（本仓已因同类问题踩过编译坑，
/// 见 `ContentView.body` 里关于 `$` 投影的注释）。
/// 既有先例：`AqiTrendLayout` 同样是文件顶层的纯几何类型。
struct PollutantRow: Identifiable {

    /// 稳定标识（污染物短名；同一列表内唯一）。
    let id: String
    /// 行标题（如「PM2.5」）。
    let title: String
    /// 该污染物的逐时浓度序列（nil = 该小时缺测）。
    let values: [Double?]
    /// 与 `values` 同下标的逐时 AQI（用于着色；nil = 缺测）。
    let aqis: [Int?]
}

/// 六污染物 24h 分项卡。
@MainActor
struct AirQualityPollutantCard: View {

    /// 逐时空气序列（来自 `AirQuality.hourly`，已由 mapper 净化负值）。
    let points: [AqiHourlyPoint]

    /// 单行高度（pt）。
    private let rowHeight: CGFloat = 22
    /// 曲线列宽（pt）。
    private let curveWidth: CGFloat = 132

    /// 六行（顺序固定：颗粒物 → 气体，与既有 AQI 卡的指标顺序一致）。
    private var rows: [PollutantRow] {
        [
            row("pm25", title: "PM2.5", values: points.map(\.pm25)),
            row("pm10", title: "PM10", values: points.map(\.pm10)),
            row("o3", title: "臭氧 O₃", values: points.map(\.ozone)),
            row("no2", title: "二氧化氮", values: points.map(\.nitrogenDioxide)),
            row("so2", title: "二氧化硫", values: points.map(\.sulphurDioxide)),
            row("co", title: "一氧化碳", values: points.map(\.carbonMonoxide))
        ]
    }

    private func row(_ id: String, title: String, values: [Double?]) -> PollutantRow {
        PollutantRow(id: id, title: title, values: values, aqis: points.map(\.usAqi))
    }

    /// 可渲染的行：**只过滤整行全缺测的污染物**（部分缺测仍渲染，曲线断开）。
    private var visibleRows: [PollutantRow] {
        rows.filter { row in row.values.contains { $0 != nil } }
    }

    /// 可渲染行数（**internal 便于单测**断言"缺测的污染物整行被隐藏"这一判据）。
    /// 与`visibleRows` 同源，不引入第二份过滤逻辑。
    var visibleRowCount: Int { visibleRows.count }

    var body: some View {
        // 六项全缺测（服务端未返回 / 旧载荷）→ 整卡不渲染，绝不渲染六个"--"。
        if !visibleRows.isEmpty {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(visibleRows) { row in
                rowView(row)
            }
            axis
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 13))
                .foregroundStyle(Theme.accentSecondary)
            Text("六污染物 24 小时趋势")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 8)
            Text("μg/m³ · 各行独立刻度")
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    /// 单行：标题 + 峰值 + 迷你曲线。
    private func rowView(_ row: PollutantRow) -> some View {
        HStack(spacing: 8) {
            Text(row.title)
                .font(.system(size: Theme.FontSize.footnote, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 58, alignment: .leading)
            curve(row)
                .frame(width: curveWidth, height: rowHeight)
            Spacer(minLength: 4)
            Text(peakText(row))
                .font(.system(size: Theme.FontSize.footnote, weight: .medium))
                .foregroundStyle(peakColor(row))
                .lineLimit(1)
        }
    }

    /// 迷你曲线：几何全部由 `PollutantRowLayout` 给出，视图只负责描点连线。
    private func curve(_ row: PollutantRow) -> some View {
        GeometryReader { geometry in
            let layout = PollutantRowLayout(values: row.values, size: geometry.size)
            ZStack(alignment: .topLeading) {
                ForEach(layout.segments) { segment in
                    Path { path in
                        path.move(to: segment.start)
                        path.addLine(to: segment.end)
                    }
                    .stroke(lineColor(row, index: segment.id),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
                ForEach(layout.dots) { dot in
                    Circle()
                        .fill(dotColor(row, index: dot.id))
                        .frame(width: 2, height: 2)
                        .position(dot.position)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    /// 线段着色：按**左端点**该小时的 AQI 档位（缺测 → 中性灰）。
    /// 与既有 `AirQualityCard.color(for:)` 同源，不另造配色。
    private func lineColor(_ row: PollutantRow, index: Int) -> Color {
        Self.aqiColor(row.aqis[index])
    }

    private func dotColor(_ row: PollutantRow, index: Int) -> Color {
        Self.aqiColor(row.aqis[index])
    }

    private static func aqiColor(_ aqi: Int?) -> Color {
        guard let aqi else { return Theme.divider }
        return AirQualityCard.color(for: AqiLevel(usAqi: aqi))
    }

    /// 行尾峰值文案（μg/m³，1 位小数；本行全缺测时不会走到这里）。
    private func peakText(_ row: PollutantRow) -> String {
        guard let peak = row.values.compactMap({ $0 }).max() else { return "--" }
        return String(format: "峰值 %.1f", peak)
    }

    /// 峰值着色：取峰值所在小时的 AQI 档位色；该小时 AQI 缺测 → 中性灰。
    private func peakColor(_ row: PollutantRow) -> Color {
        guard let peak = row.values.compactMap({ $0 }).max(),
              let index = row.values.firstIndex(where: { $0 == peak }) else {
            return Theme.secondaryText
        }
        return Self.aqiColor(row.aqis[index])
    }

    /// 相对时间轴：只说"现在 / 24 小时后"，不说钟点（D-4，理由见文件头）。
    private var axis: some View {
        HStack(spacing: 0) {
            Text("现在")
                .font(.system(size: 9))
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 8)
            Text("24 小时后")
                .font(.system(size: 9))
                .foregroundStyle(Theme.secondaryText)
        }
    }
}
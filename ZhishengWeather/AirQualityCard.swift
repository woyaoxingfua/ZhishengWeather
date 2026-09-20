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
//  P2 修订（D-C4 / D-B11，AC-C9 / AC-C10 / AC-B24）：在既有 current 展示之后
//  **只做加法**地追加「未来 24 小时 AQI 趋势」区：
//   - 曲线按**既有六档语义色**分段着色（复用 `AqiLevel` + 本卡 `color(for:)`，
//     不新造第二套分档/配色）；
//   - 曲线**只连接都有值的相邻两点**，nil 处断开（几何由 `AqiTrendLayout` 决定）；
//   - 逐时数据整块缺失 / 全无 AQI 值 → 趋势区**整块隐藏**，不留空槽。
//
//  时间轴取**相对小时数**（「现在 / 24 小时后」）而非钟点：本卡只收到
//  `AirQuality`（不含时区），调用点也未透传时区，用设备时区渲染异地城市的
//  钟点会说谎（多城市纪律 D-4）。相对表述与时区无关，恒不失真。
//

import SwiftUI

/// 逐时 AQI 趋势曲线的纯几何布局（不依赖视图，可单测 —— AC-C9 / AC-C10 的判据在此可验证）。
///
/// 输入**完整**逐时序列（含无值点：它们承载如实的缺口宽度）与绘制区尺寸，产出：
/// - `segments`：**仅当相邻两点都有 AQI 值**时才生成的折线段 —— nil 处**不生成**
///   任何线段，曲线就此断开（AC-C10）。绝不连线跨越缺口，否则会把"没有数据"
///   画成"空气持续/变好"。
/// - `dots`：每个有值点（便于逐点读数，也让缺口两侧端点可见）。
/// - `gridLines`：落在纵轴域内的六档断点水平参考线 y（便于对档读色）。
///
/// 纵轴域固定为 `[0, upperBound]`（`upperBound` = 数据峰值向上取整到 50 的整数倍，
/// 且不小于 50），使不同帧之间纵向可比。
///
/// 段的着色档位取两端中**较大 AQI**（更差）所属档位：宁可把跨档过渡段画得略重，
/// 也绝不把正在转差的时段画成"优"（与 AC-C10 同源的诚实取向）。
struct AqiTrendLayout {

    /// 一段折线（两端都有值）。
    struct Segment: Identifiable {
        /// 段**左端点**下标（同一序列内唯一）。
        let id: Int
        let start: CGPoint
        let end: CGPoint
        /// 着色档位 = 两端中较大 AQI 所属档位（见类型注释）。
        let level: AqiLevel
    }

    /// 一个有值点。
    struct Dot: Identifiable {
        /// 点下标。
        let id: Int
        let position: CGPoint
        let level: AqiLevel
    }

    /// 要在曲线区中绘制的折线段（缺口处无段）。
    var segments: [Segment]
    /// 要在曲线区中绘制的有值点。
    var dots: [Dot]
    /// 六档断点参考线的 y 坐标（已落在域内的才给）。
    var gridLines: [CGFloat]
    /// 纵轴上限（50 的整数倍，且 ≥ 50）。
    var upperBound: Int

    /// 六档断点（美标 AQI，与 `AqiLevel` 的档位边界一致：50/100/150/200/300）。
    private static let gridBoundaries = [50, 100, 150, 200, 300, 400, 500]

    /// 曲线区上下留白：避免点/线在纵轴两端被裁掉一半线宽。
    private static let verticalInset: CGFloat = 3

    init(points: [AqiHourlyPoint], size: CGSize) {
        let count = points.count
        let values: [Int?] = points.map(\.usAqi)
        let maxValue = values.compactMap { $0 }.max() ?? 0
        let upper = max(50, Int((Double(maxValue) / 50.0).rounded(.up)) * 50)
        self.upperBound = upper

        guard count > 0, size.width > 0, size.height > 0 else {
            self.segments = []
            self.dots = []
            self.gridLines = []
            return
        }

        // 点 i 落在第 i 个等宽槽的**中心**（与下方时间轴 / 柱状区同款槽位模型）。
        let stepX = size.width / CGFloat(count)
        let inset = Self.verticalInset
        let plotHeight = max(size.height - inset * 2, 1)
        let unitY = plotHeight / CGFloat(upper)
        func position(index: Int, value: Int) -> CGPoint {
            let clamped = min(max(value, 0), upper)
            return CGPoint(x: (CGFloat(index) + 0.5) * stepX,
                           y: inset + plotHeight - CGFloat(clamped) * unitY)
        }

        var segments: [Segment] = []
        var dots: [Dot] = []
        for index in 0..<count {
            guard let value = values[index] else { continue }
            dots.append(Dot(id: index,
                            position: position(index: index, value: value),
                            level: AqiLevel(usAqi: value)))
            // 只有"下一个点也有值"才生成线段 —— nil 处断开（AC-C10）。
            guard index + 1 < count, let next = values[index + 1] else { continue }
            segments.append(Segment(id: index,
                                    start: position(index: index, value: value),
                                    end: position(index: index + 1, value: next),
                                    level: AqiLevel(usAqi: max(value, next))))
        }

        self.segments = segments
        self.dots = dots
        self.gridLines = Self.gridBoundaries
            .filter { $0 < upper }
            .map { inset + plotHeight - CGFloat($0) * unitY }
    }
}

/// 主屏空气质量卡。
@MainActor
struct AirQualityCard: View {

    let airQuality: AirQuality

    /// 曲线区高度（pt）。
    private let trendCurveHeight: CGFloat = 54

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

            // 六项分测横向格（缺项 --；MetricCell 签名 = icon/value/caption，
            // icon 用真实存在的 SF Symbol——运行时空白不报错，QA 静态查不出，须人工核）。
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                MetricCell(icon: "airquality", value: concentration(airQuality.pm25, unit: "μg/m³"), caption: "PM2.5")
                MetricCell(icon: "wind", value: concentration(airQuality.pm10, unit: "μg/m³"), caption: "PM10")
                MetricCell(icon: "sun.max", value: concentration(airQuality.ozone, unit: "μg/m³"), caption: "臭氧 O₃")
                MetricCell(icon: "cloud.fog", value: concentration(airQuality.nitrogenDioxide, unit: "μg/m³"), caption: "二氧化氮")
                MetricCell(icon: "flame", value: concentration(airQuality.sulphurDioxide, unit: "μg/m³"), caption: "二氧化硫")
                MetricCell(icon: "smoke", value: concentration(airQuality.carbonMonoxide, unit: "μg/m³"), caption: "一氧化碳")
            }

            // 欧标 AQI 辅助展示（不参与着色，Q2 裁定）。
            if let eu = airQuality.europeanAqi {
                Text("欧洲标准 AQI：\(eu)")
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            }

            // P2：24 小时 AQI 趋势（新增区；无逐时数据 → 整块不渲染，AC-B24）。
            if let trend = trendPoints {
                trendSection(trend)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 24 小时 AQI 趋势（D-C4 / D-B11）

    /// 可渲染的逐时序列；整块缺失 / 为空 / **全部无 AQI 值** → nil
    /// → 趋势区整块隐藏、不留空槽（AC-B24）。
    private var trendPoints: [AqiHourlyPoint]? {
        guard let hourly = airQuality.hourly, !hourly.isEmpty else { return nil }
        guard hourly.contains(where: { $0.usAqi != nil }) else { return nil }
        return hourly
    }

    /// 趋势区：标题 + 峰值 + 曲线 + 相对时间轴。
    @ViewBuilder
    private func trendSection(_ points: [AqiHourlyPoint]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("未来 24 小时 AQI 趋势")
                    .font(.system(size: Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 8)
                // 峰值用其所属档位的语义色（与曲线同源，不另造一套配色）。
                if let peak = points.compactMap(\.usAqi).max() {
                    Text("最高 \(peak)")
                        .font(.system(size: Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Self.color(for: AqiLevel(usAqi: peak)))
                }
            }
            trendCurve(points)
            trendAxis
        }
    }

    /// 曲线区：断点参考线 + 分段着色折线 + 有值圆点。
    /// 所有几何（哪儿连、哪儿断、什么色）都由 `AqiTrendLayout` 给出。
    private func trendCurve(_ points: [AqiHourlyPoint]) -> some View {
        GeometryReader { geometry in
            let layout = AqiTrendLayout(points: points, size: geometry.size)
            ZStack(alignment: .topLeading) {
                ForEach(layout.gridLines, id: \.self) { y in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                    }
                    .stroke(Theme.divider, lineWidth: 0.5)
                }
                ForEach(layout.segments) { segment in
                    Path { path in
                        path.move(to: segment.start)
                        path.addLine(to: segment.end)
                    }
                    .stroke(Self.color(for: segment.level),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                ForEach(layout.dots) { dot in
                    Circle()
                        .fill(Self.color(for: dot.level))
                        .frame(width: 3.5, height: 3.5)
                        .position(dot.position)
                }
            }
            .frame(width: geometry.size.width,
                   height: geometry.size.height,
                   alignment: .topLeading)
        }
        .frame(height: trendCurveHeight)
    }

    /// 相对时间轴：只说"距当前多少小时"，不说钟点（见文件头 D-4 说明）。
    private var trendAxis: some View {
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
    /// 曲线分段着色**复用本函数**，确保与标题圆点同色同义。
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

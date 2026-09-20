//
//  HourlySeriesChartSupport.swift
//  ZhishengWeather（主 App target）  [D-C1 / D-C2 共用]
//
//  两张逐时序列图（`HourlyPrecipitationChart` / `HourlyWindChart`）共用的
//  **几何算法 + 时间轴**，抽出来只为消灭"两张图各写一份、改一处忘另一处"的漂移：
//   - 列几何：n 列等宽，第 i 列柱心 x = (i + 0.5) × 列宽。两张图用**同一套算式**，
//     故柱心与轴标签必然对齐；
//   - 时间轴：标签由 `HourlySeriesAxis.labels(times:timeZone:every:)` 统一派生
//     （首格「现在」+ 每 6 小时一格），并由 `HourlySeriesAxisRow` 以**等宽单元格**
//     渲染 —— 单元格宽度 == 绘图区列宽，标签才落在柱心上。
//
//  D-4 时区纪律：时刻一律按**传入的城市时区**渲染（经 `WeatherTimeFormatter`，
//  @MainActor / 格式器内部缓存），本文件不取设备时区做默认。
//
//  边界：本文件只做排版与时间轴，**不含任何数据判定**（"算不算有雨 / 有没有值"
//  各自留在卡片内）—— 两种量纲的语义不同，不该下沉到公共层。
//
//  @MainActor：与项目内其他 View 一致（SwiftUI 仅对 body 推断主 actor；且本文件
//  的时间渲染经 @MainActor 的 `WeatherTimeFormatter`）。
//

import SwiftUI

/// 逐时序列图的共享几何（两张图同高、同列算法）。
enum HourlySeriesChartLayout {

    /// 绘图区高度（pt）。与 `EnsembleUncertaintyCard.maxBarHeight` 同量级，
    /// 保证主屏各图视觉一致。
    static let plotHeight: CGFloat = 56

    /// 单柱宽占列宽的比例（余下留白，保证相邻柱可辨）。
    static let barWidthRatio: CGFloat = 0.55

    /// 列宽 = 绘图区宽 / 列数；列数 ≤ 0 时回 0（防御，调用方已保证非空）。
    static func columnWidth(count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return width / CGFloat(count)
    }

    /// 第 index 列的中心 x（柱心 = 列中心，故等宽单元格的轴标签天然对齐）。
    static func columnCenterX(index: Int, count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return width * (CGFloat(index) + 0.5) / CGFloat(count)
    }

    /// 单柱宽（下限 1pt，避免列数多时柱宽归零而"看不见"）。
    static func barWidth(count: Int, width: CGFloat) -> CGFloat {
        max(1, columnWidth(count: count, width: width) * barWidthRatio)
    }
}

/// 逐时序列图的时间轴标签派生（单一真相源）。
@MainActor
enum HourlySeriesAxis {

    /// 轴标签数组（与 `times` 等长同序；空串 = 该列不标注）。
    ///
    /// - 首格固定 `leadingLabel`（默认「现在」，与 `HourlyStrip` 口径一致）；
    /// - 其后每 `every` 小时标注一次（默认 6 小时，24 小时窗 → 4 个标注，窄屏不挤）。
    /// - 时刻按传入城市时区渲染（D-4）。
    ///
    /// - Parameters:
    ///   - times: 各列的时刻（与序列同序）。
    ///   - timeZone: 选中城市时区。
    ///   - every: 标注间隔（小时格数）。
    ///   - leadingLabel: 首格文案。
    /// - Returns: 与 `times` 等长的标签数组。
    static func labels(times: [Date],
                       timeZone: TimeZone,
                       every: Int = 6,
                       leadingLabel: String = "现在") -> [String] {
        let step = max(1, every)
        var result: [String] = []
        result.reserveCapacity(times.count)
        for (index, time) in times.enumerated() {
            if index % step != 0 {
                result.append("")
            } else if index == 0 {
                result.append(leadingLabel)
            } else {
                result.append(WeatherTimeFormatter.string(from: time, format: "H", timeZone: timeZone))
            }
        }
        return result
    }
}

/// 轴标签行：等宽单元格 + 居中标签（`.fixedSize()` 防压缩，
/// 溢出只会落在卡片内边距上，不会与相邻标注重叠——相邻标注相隔 6 列）。
@MainActor
struct HourlySeriesAxisRow: View {

    /// 轴标签（与绘图区列等长同序，空串 = 不标注）。
    let labels: [String]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

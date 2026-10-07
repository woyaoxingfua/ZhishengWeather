//
//  TideConditions.swift
//  Core / Models  [App + Widget 共用]
//
//  潮汐领域模型（第四源 Open-Meteo Marine 的 `minutely_15` 块，免 Key）。
//
//  ═══════════════════════════════════════════════════════════════════════
//  ⚠️⚠️ 本文件头是**语义边界**的唯一权威，UI 文案必须与之一致
//  ═══════════════════════════════════════════════════════════════════════
//  设计稿曾断言「`sea_level_height_msl` = 天文潮（不含气压/风暴增水）」，
//  **实测 + 官方文档均不支持该断言**。Open-Meteo Marine 文档对该变量的逐字
//  描述是：
//
//    "The sea level height accounts for ocean tides, **the inverted barometer
//     effect**, sea surface height, global mean steric variation, and global
//     mean mass volume variation. The reference (datum) height is the
//     **global mean sea level**, **not the lowest astronomical tide**."
//
//  拆开看，这条变量**不是**纯天文潮，它 = 天文潮 + 倒压效应 + 海面高度 +
//  全球平均比容变化 + 全球平均质量体积变化。其中与用户日常感受最相关的两项：
//
//  ① **倒压效应**（inverted barometer）：气压升高把海面压低。Open-Meteo 另有
//     独立变量 `invert_barometer_height` 给出这一项，且文档逐字说明
//     *"This is already considered in sea_level_height_msl"*（已计入）。
//     → 实测（大连 38.9,121.6）该项为 **-0.13…-0.01m**（1–13 cm）。
//     → 故本模型**取差值** `seaLevelMSL - invertBarometer` 得到**天文潮分量**，
//        并把两者**都**保留，让 UI 能诚实呈现"这是天文潮，不是实测水位"。
//
//  ② **风暴增水 / 波浪增水**：文档**没有**把它列进这个变量
//     （列的是上列五项，没有 storm surge）。但文档同时逐字警告：
//     *"Accuracy is limited in coastal areas — while it can be reasonably
//     accurate near unobstructed coasts, it may be completely unreliable
//     further inland. This data is not suitable for coastal navigation."*
//     → 即便如此，它仍**不是**验潮站实测水位，且近岸精度有限。
//
//  ── UI 必须如实标注（三条，缺一即为过度承诺）──────────────────────────
//   1. 写「**天文潮**」而不是「潮高 / 当前水位」——后者会被读成实测水位；
//   2. 基准面是**全球平均海平面（MSL）**，**不是**中国海事惯用的
//      "理论最低潮位（LAT）"，故数值**不可**与官方潮汐表直接比对；
//   3. ⚠️ **不可用于航海**（文档逐字 "not suitable for coastal navigation"）。
//
//  ── 为什么不放 `invert_barometer_height` 进 UI 曲线 ─────────────────────
//  本模型保留它只是为了**能算出天文潮分量**（差值）。若某点缺该字段，
//  该点天文潮分量为 nil → 曲线**断开**，绝不拿"只扣了一半"的数去画。
//
//  ── 零 null 之外的失败形态（实测）────────────────────────────────────
//  · 整块被静默省略（`minutely_15` 键不存在）→ 解码出 nil；
//  · **内陆 / 网格吸附到陆地的坐标**：HTTP 200 + 数组长度正常但元素**全 null**
//    （实测北京、成都、乌鲁木齐，以及上海/天津/杭州/广州）→ 必须靠
//    `isEffectivelyEmpty` 判定，否则会把"无数据"画成"潮高 0 m 的平直线"。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 潮汐曲线上的一个点（15 分钟粒度）。
struct TidePoint: Codable, Equatable, Identifiable, Sendable {

    /// 该点时刻（由 `minutely_15.time` 的 epoch 秒解析）。
    var time: Date

    /// **天文潮分量**（m，相对全球平均海平面）= `sea_level_height_msl − invert_barometer_height`。
    ///
    /// nil = 该点缺测（任一被减项缺失即nil）。**不补0**。
    var astronomical: Double?

    /// 服务端原始的 `sea_level_height_msl`（m，**含倒压效应**）。保留供诊断/对照。
    var seaLevelMSL: Double?

    /// 倒压效应（m，气压高 → 负值）。保留供诊断/对照。
    var invertBarometer: Double?

    /// 以时刻作为稳定标识（同一 15 分钟格唯一）。
    var id: Date { time }
}

/// 一次 marine 链路的潮汐领域模型（逐 15 分钟序列）。
struct TideForecast: Codable, Equatable, Sendable {

    /// 逐 15 分钟潮汐序列（**按时间升序**）。空数组 = 无数据。
    ///
    /// ⚠️ 元素可含 `astronomical == nil` 的点（该点缺测）——
    /// UI **必须**在缺口处断开曲线，**绝不**跨缺口连线（同 `AirQualityPollutantCard`）。
    var points: [TidePoint]

    /// 服务端返回的序列原始点数（**实测 672** = 7 天 × 96 点/天）。
    ///
    /// 用途：UI 可诚实说明"未来 7 天逐 15 分钟"，而不是只画 24 小时
    /// 却让人以为只有 24 小时数据。仅供展示，不参与判定。
    var totalPoints: Int

    /// 空模型（供 mapper 的"缺块 / 全 null"回落路径使用）。
    static let empty = TideForecast(points: [], totalPoints: 0)
}

extension TideForecast {

    /// **实质无数据**判定 → 转发到 `SnapshotCompleteness.isEffectivelyEmpty(_:)`。
    ///
    /// ⚠️ 判据的**权威不在本模型**（与 `MarineConditions.isEffectivelyEmpty` 同款
    ///   纪律）：全仓库只应有一处"解码成功但实质无数据"的判定，否则 N 份各自
    ///   实现必然漂移。本便捷属性只是转发，**不新增**判定逻辑。
    var isEffectivelyEmpty: Bool {
        SnapshotCompleteness.isEffectivelyEmpty(self)
    }

    /// 从**现在**起未来 24 小时的点（15 分钟粒度 → 96 点）。
    ///
    /// - Parameter now: 参照时刻（**由调用方注入**，Core 纪律禁内部取时钟）。
    /// - Returns: `time >= now` 且落在 24 小时窗内的点（保持原序）。
    ///
    /// ⚠️ **半开窗 `[now, now+24h)`**：用 `>=` 而非 `>`，让"现在这一刻"
    ///   总在窗内（用户刷新后曲线不会莫名空掉一格）。
    func pointsInNext24Hours(now: Date) -> [TidePoint] {
        let horizon = now.addingTimeInterval(24 * 60 * 60)
        return points.filter { $0.time >= now && $0.time < horizon }
    }
}

/// 潮汐极值（高潮或低潮）。
struct TideExtremum: Equatable, Identifiable, Sendable {

    /// 是否为高潮（true）/ 低潮（false）。
    var isHighTide: Bool

    /// 极值时刻（15 分钟格，**取实测采样点本身**，不做插值 —— 插值出来的
    /// 时刻是**模型推测值**，与"实测采样格"不是一回事，故不做）。
    var time: Date

    /// 极值潮高（m，相对全球平均海平面，天文潮分量）。
    var height: Double?

    /// 稳定标识（同 `TideExtremum` 内isHighTide + time唯一）。
    var id: String {
        return (isHighTide ? "h" : "l") + "-\(time.timeIntervalSince1970)"
    }
}

extension TideForecast {

    /// 在给定序列里找**局部**高/低潮极值（**纯函数、可单测、不联网**）。
    ///
    /// 判据（标准局部极值定义，闭区间两端按"单侧够大即算"处理，
    /// 避免序列首尾永远拿不到极值）：
    ///   · 高潮点：该值 **>** 左邻 且 **>=** 右邻；
    ///   · 低潮点：该值 **<** 左邻 且 **<=** 右邻。
    /// ⚠️ 任一邻点缺测 → 该点**不参与**极值判定（不做跨缺口推断）。
    ///
    /// - Parameter points: 参与判定的点序列（通常已截取为 24 小时窗）。
    /// - Returns: 高潮与低潮各自按时刻升序排列的结果。
    static func extrema(in points: [TidePoint]) -> (high: [TideExtremum], low: [TideExtremum]) {
        var high: [TideExtremum] = []
        var low: [TideExtremum] = []
        guard points.count >= 2 else { return (high, low) }

        for index in points.indices {
            // ⚠️ 缺测点：跳过（既不判高也不判低），曲线缺口由 UI 断开。
            guard let value = points[index].astronomical else { continue }

            let isFirst = index == points.startIndex
            let isLast = index == points.index(before: points.endIndex)
            let left = isFirst ? nil : points[index - 1].astronomical
            let right = isLast ? nil : points[index + 1].astronomical

            // 首点无左邻、尾点无右邻 → 只按单侧判；两侧都缺测的点无从判定
            //（宁缺不猜：那不是极值，只是缺数据），故一律不算极值。
            let beatsLeft = left.map { value >= $0 } ?? true
            let beatsRight = right.map { value > $0 } ?? true
            let losesLeft = left.map { value <= $0 } ?? true
            let losesRight = right.map { value < $0 } ?? true

            let comparable = left != nil || right != nil
            guard comparable else { continue }

            if beatsLeft && beatsRight {
                high.append(TideExtremum(isHighTide: true,
                                         time: points[index].time,
                                         height: value))
            }
            if losesLeft && losesRight {
                low.append(TideExtremum(isHighTide: false,
                                        time: points[index].time,
                                        height: value))
            }
        }
        return (high, low)
    }
}
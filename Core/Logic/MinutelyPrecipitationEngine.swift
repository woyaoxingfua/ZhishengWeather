//
//  MinutelyPrecipitationEngine.swift
//  Core / Logic  [App + Widget 共用]
//
//  B1-2 短时降水卡的展示决策（纯逻辑，可 @testable 单测）。
//
//  裁定：短时降水卡在**干窗**（窗口内无降水）或**无有效数据**时**整卡隐藏**
//  （沿用原 Android 本体行为；AC-B1-8「无雨即隐藏」/ AC-B1-9「缺数据整卡隐藏，
//  不显示空槽」）。本类型只做"要不要显示 / 何时开始停止 / 峰值多少"的纯判定，
//  不做格式化（格式化由 UI 层按时区渲染，避免 Core 触碰 DateFormatter 共享状态）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 短时降水卡的展示决策引擎（纯函数，无状态）。
enum MinutelyPrecipitationEngine {

    /// 降水判定阈值（mm / 15min）。
    ///
    /// 大于该值才视为"该 15 分钟窗内有降水"。取 0.01 以滤掉浮点噪声 / 微量数值，
    /// 避免 0.001 级别的记录把整卡点亮（与"不冒充"纪律一致：没下就不显示）。
    static let precipitationThreshold: Double = 0.01

    // MARK: - 干窗判定（决定整卡是否隐藏）

    /// 窗口内是否存在降水（"干窗"判定）。
    ///
    /// - Parameter points: 短时降水序列；nil 或空 → 视为无降水。
    /// - Returns: 任一点降水超过阈值 → true；否则 false。
    static func hasPrecipitation(_ points: [MinutelyPrecipitationPoint]?) -> Bool {
        guard let points else { return false }
        return points.contains { $0.precipitation > precipitationThreshold }
    }

    /// 窗口内峰值降水（mm / 15min）。
    /// - Parameter points: 短时降水序列；nil 或空 → nil。
    /// - Returns: 最大单窗降水；无点 → nil。
    static func peakPrecipitation(_ points: [MinutelyPrecipitationPoint]?) -> Double? {
        guard let points, !points.isEmpty else { return nil }
        return points.map(\.precipitation).max()
    }

    // MARK: - 开始 / 停止时序（可派生才给）

    /// 短时降水时序（纯派生结果，不含格式化字符串）。
    struct Timing: Equatable, Sendable {
        /// 窗口首点是否已有降水（= 当前正在下雨）。
        var isRainingNow: Bool
        /// 降水开始时刻；`isRainingNow == true` 时为 nil（已经在下，无"开始"）。
        var start: Date?
        /// 降水转为无降水的**窗起始时刻**（近似"减弱/停止"点）；
        /// nil = 持续到窗口末（或正在下且未在窗内停）。
        var stop: Date?
    }

    /// 派生开始 / 停止时序。
    ///
    /// 规则（对 15 分钟粒度的诚实近似，不夸大精度）：
    /// - 首点有降水 → "正在下"：窗内首次转干 → `stop` 为该窗起始；
    ///   全程湿 → `stop = nil`（持续到窗末）。
    /// - 首点无降水但稍后有 → `start` 为首次转湿的窗起始；若其后又转干 → `stop` 为该窗起始。
    /// - 全窗无降水 → nil（调用方本就整卡隐藏）。
    ///
    /// - Parameter points: 短时降水序列；nil / 空 / 全干 → nil。
    /// - Returns: 时序；无法派生 → nil。
    static func timing(_ points: [MinutelyPrecipitationPoint]?) -> Timing? {
        guard let points, !points.isEmpty else { return nil }

        let wet = points.map { $0.precipitation > precipitationThreshold }
        guard wet.contains(true) else { return nil }

        if wet[0] {
            // 正在下：找窗内首次转干（注意 firstIndex 返回的可能是 0 之后的任意下标）。
            if let stopIndex = wet.firstIndex(of: false) {
                return Timing(isRainingNow: true, start: nil, stop: points[stopIndex].time)
            }
            return Timing(isRainingNow: true, start: nil, stop: nil)
        }

        guard let startIndex = wet.firstIndex(of: true) else { return nil }
        var stop: Date?
        if let relativeStop = wet[startIndex...].firstIndex(of: false) {
            stop = points[relativeStop].time
        }
        return Timing(isRainingNow: false, start: points[startIndex].time, stop: stop)
    }
}

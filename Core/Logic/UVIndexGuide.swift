//
//  UVIndexGuide.swift
//  Core / Logic  [App + Widget 共用]
//
//  紫外线（UV）指数的**分级与防晒建议**（纯逻辑，可 @testable 单测，不联网、无系统时钟依赖）。
//
//  ## 量表出处与口径（务必随表改动一起复核）
//  分级采用 **WHO（世界卫生组织）全球标准 UV 指数**（WHO Global Solar UV Index，
//  见 WHO 官方发布 *Global Solar UV Index: A Practical Guide*，2002）所采用的五档量表：
//
//  | UV 指数区间 | 等级（本文件 `UVIndexLevel`） | 典型防护动作 |
//  |---|---|---|
//  |0 –2| 低（`low`）      | 无需防护                       |
//  |3 –5| 中等（`moderate`）| 建议 SPF30+                |
//  |6 –7| 高（`high`）    | 建议 SPF50+、减少正午户外       |
//  |8 –10| 很高（`veryHigh`）| 尽量避开 11–16 时          |
//  |11+ | 极高（`extreme`） | 避免日晒                       |
//
//  口径说明（**别把它当别的量**，本仓存在三个同族但不同义的字段）：
//  - 本文件判定的是 **UV 指数**（UVI，**无量纲**，0–11+，数值越大皮肤受伤害越强）；
//  - `WeatherSnapshot.uvIndex` = **此刻**实况；`DailyForecast.uvIndexMax` = **当日峰值**；
//    `HourlyPoint.uvIndex` = **逐小时**值。三者语义不同，**UI 不许共用一个标签**。
//  - WHO 的原始建议还附带「白色皮肤 200 分钟累积剂量」等剂量口径，本工程**不**做剂量换算
//    （没有皮肤类型输入），只做**分级 + 动作文案**。
//
//  ## 诚实取值纪律（与全仓一致，最易出错的三处）
//  1. **`0` 是合法值，不是缺失**：夜间 UV 恒为 0（实测 2026-10-06 北京逐时序列前 7 条
//     即 `0.0`）。故分级用 `uv <= 2` 判为「低」，**绝不可**用 `uv == 0` 判「无数据」。
//  2. **nil（无数据）→ 返回 nil**，让调用方**整块隐藏**，绝不显示「未知 / 0 / --」
//     把"没测到"说成"没有紫外线"。
//  3. **峰值必须由注入的序列 + 注入的 `now` 计算**，本文件（Core）**不调用 `Date()`**
//     （硬门禁 SC-11 会扫）。跨零点归属由调用方给的 `timeZone` 裁定——设备时区渲染异地
//     城市的"当日峰值"会说谎（多城市纪律 D-4），故**强制要求**显式传时区。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError / 凭据读取。
//

import Foundation

// MARK: - 分级

/// WHO 标准 UV 指数五档分级（区间口径见文件头表格）。
///
/// 档位**刻意不实现** `RawRepresentable` 的整数映射：`low = 0` 极易被误当成
/// "UV 原始值 = 0"，而 0 其实是 low 这个**区间**（0–2）的下沿。故用枚举 + 显式 `init?(uv:)`。
enum UVIndexLevel: Equatable, Sendable, CaseIterable {

    /// 0–2：无需防护。
    case low
    /// 3–5：建议 SPF30+。
    case moderate
    /// 6–7：建议 SPF50+、减少正午户外。
    case high
    /// 8–10：尽量避开 11–16 时。
    case veryHigh
    /// 11+：避免日晒。
    case extreme

    /// 由 UV 指数数值分级。
    ///
    /// 边界（半开区间，逐一对应 WHO 量表，实测 2/3、5/6、7/8、10/11 四个临界点）：
    /// - `<= 2` → `.low`（**含 0**：夜间是合法低值，不是缺测）
    /// - `<= 5` → `.moderate`
    /// - `<= 7` → `.high`
    /// - `<= 10` → `.veryHigh`
    /// - 其余 → `.extreme`
    ///
    /// - Parameter uv: UV 指数（**无量纲**）；`nil` / 非有限值 / 负数（物理上不存在，
    ///   服务端异常）→ **nil**，调用方须整块隐藏，**不得**当 0 处理。
    init?(uv: Double?) {
        guard let uv, uv.isFinite, uv >= 0 else { return nil }
        if uv <= 2 { self = .low }
        else if uv <= 5 { self = .moderate }
        else if uv <= 7 { self = .high }
        else if uv <= 10 { self = .veryHigh }
        else { self = .extreme }
    }

    /// 档位中文名（UI 显示）。
    var displayName: String {
        switch self {
        case .low: return "低"
        case .moderate: return "中等"
        case .high: return "高"
        case .veryHigh: return "很高"
        case .extreme: return "极高"
        }
    }

    /// 该档位的防护动作文案（防晒建议；本仓唯一真源，UI 不另拼句）。
    var adviceText: String {
        switch self {
        case .low: return "无需防护"
        case .moderate: return "建议 SPF30+"
        case .high: return "建议 SPF50+、减少正午户外"
        case .veryHigh: return "尽量避开 11–16 时"
        case .extreme: return "避免日晒"
        }
    }
}

// MARK: - 当日峰值

/// 当日 UV 峰值（数值 + 出现时刻），**结构化**输出（非 String）。
///
/// 时刻由调用方给的 `timeZone` 渲染（Core 不碰 `DateFormatter`，见 `WeatherTimeFormatter`）。
struct UVPeak: Equatable, Sendable {

    /// 峰值 UV 指数（**无量纲**）。
    ///
    /// ⚠️ **`0.0` 是合法结果**（全天夜间 / 极夜），**不得**据此判定"无数据"——
    /// 是否隐藏由 `UVIndexGuide.dailyPeak` 返回 nil 与否决定，不看这个数。
    let value: Double

    /// 峰值出现时刻（取自逐时序列的整点时刻，非"某个插值时刻"）。
    let time: Date
}

// MARK: - 入口

/// UV 分级与防晒建议的单一真源（纯函数、无状态、无 IO、**时钟由参数注入**）。
enum UVIndexGuide {

    /// 逐时序列被截断时一天的小时数上限（对齐 `OpenMeteoMapper.maxHourlyCount`）。
    ///
    /// 仅用于**防御性校验**：若调用方传入的序列跨了不止一天（例如把多天的逐时混在一起），
    /// 峰值口径会变成"多天峰值"而不是"当日峰值"，与文案承诺不符。
    /// 故超过该长度的序列直接返回 nil，**绝不**悄悄换个口径出数。
    static let maxHoursPerDay = 24

    // MARK: 入口一：当日峰值 UV + 峰值时刻

    /// 当日峰值 UV 与其出现时刻。
    ///
    /// 规则（逐条可单测）：
    /// - **只统计"当地同一自然日"内的点**：`now` 与逐时点的日历日由 `timeZone` 裁定，
    ///   跨零点的前一天的点被排除（否则"当日峰值"会是昨天+今天的最大值）；
    /// - **只统计 `uvIndex` 有值的点**；某点 `uvIndex == nil`（缺测）→ 跳过该点，
    ///   **不**把 nil 当 0（否则夜间缺测会伪装成"低"）；
    /// - **峰值可以合法地是 `0.0`**（全天无日照）：此时仍**返回峰值**（含时刻），
    ///   而不是 nil —— 「全天 UV 为 0」是**结论**，「没有数据」才是 nil，二者必须可区分；
    /// - 序列为空 / 当日无任何有效点 / 序列跨天超长 → **nil**（调用方整块隐藏）。
    ///
    /// - Parameters:
    ///   - points: 逐时序列（来自 `WeatherSnapshot.hourly`）。
    ///   - now: 当前时刻（**注入**；Core 内不取时钟）。
    ///   - timeZone: 归属自然日的时区（D-4：必须由调用方给出**城市时区**，
    ///     绝不可用设备时区替异地城市说"今天"）。
    /// - Returns: 当日峰值；无法派生 → nil。
    static func dailyPeak(points: [HourlyPoint]?, now: Date, timeZone: TimeZone) -> UVPeak? {
        guard let points, !points.isEmpty else { return nil }
        // 跨天超长序列 → 拒绝出数（见 maxHoursPerDay 注释），避免口径与文案不符。
        guard points.count <= maxHoursPerDay else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let nowDay = calendar.startOfDay(for: now)

        var best: UVPeak?
        for point in points {
            guard calendar.startOfDay(for: point.time) == nowDay else { continue }
            guard let uv = point.uvIndex, uv.isFinite, uv >= 0 else { continue }
            if let current = best {
                // 严格大于：并列时保留**序列里更早**的那个时刻（同值取首次出现，
                // 与"正午最先达到峰值"的直觉一致，且结果稳定可复现）。
                if uv > current.value { best = UVPeak(value: uv, time: point.time) }
            } else {
                best = UVPeak(value: uv, time: point.time)
            }
        }
        return best
    }

    // MARK: 入口二：当前档位文案

    /// 当前（或任一时刻）的 UV 档位与建议文案。
    ///
    /// - Parameter uv: 该时刻的 UV 指数（**无量纲**）。`nil` → nil（调用方整块隐藏）。
    /// - Returns: 结构化结果；无数据 → nil。
    static func currentAdvice(uv: Double?) -> Advice? {
        guard let level = UVIndexLevel(uv: uv) else { return nil }
        return Advice(level: level, adviceText: level.adviceText)
    }

    /// 档位 + 文案的结构化输出（便于单测同时断言"档位"与"文案"两个字面量）。
    struct Advice: Equatable, Sendable {

        /// WHO 五档分级。
        let level: UVIndexLevel

        /// 防护动作文案（直接取自 `UVIndexLevel.adviceText`，保证与档位永不脱节）。
        let adviceText: String
    }
}
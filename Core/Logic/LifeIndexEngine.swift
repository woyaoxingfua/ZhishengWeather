//
//  LifeIndexEngine.swift
//  Core / Logic  [App + Widget 共用]
//
//  生活指数规则引擎（A2-3，精简版本地自算，ARCH-A2P1 §1.1）：
//   - 纯函数、无副作用、禁 Date()（输入全部来自 `WeatherSnapshot` 静态字段）；
//   - 输出**结构化** `[LifeIndexItem]`（kind/level/value），文案由 UI 组装——
//     规则与文案解耦，单测只看结构（AC-A2-11）；
//   - 输出顺序固定：防晒 → 穿衣 → 洗车 → 运动；
//   - ⚠️ AC-A2-10：区块标题必须标注"本地估算·仅供参考"，本引擎与 UI
//     **均不得**出现"官方"字样（grep 纪律，R-A2P1-1）。
//
//  阈值（D-A2P1-1 备案：首版经验值，static let 集中便于调参）。
//
//  Core 纪律：仅 import Foundation；纯函数；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 生活指数类别（输出顺序固定）。
enum LifeIndexKind: String, Codable, Sendable, CaseIterable {
    case sun        // 防晒
    case clothing   // 穿衣
    case carWash    // 洗车
    case exercise   // 运动

    /// 中文名（UI 组装用；引擎不拼句）。
    var displayName: String {
        switch self {
        case .sun: return "防晒"
        case .clothing: return "穿衣"
        case .carWash: return "洗车"
        case .exercise: return "运动"
        }
    }
}

/// 生活指数等级。
enum LifeIndexLevel: String, Codable, Sendable {
    case recommended  // 适宜
    case neutral      // 中性
    case caution      // 注意
    case avoid        // 不宜

    /// 中文名（UI 组装用）。
    var displayName: String {
        switch self {
        case .recommended: return "适宜"
        case .neutral: return "中性"
        case .caution: return "注意"
        case .avoid: return "不宜"
        }
    }
}

/// 单项生活指数（结构化，非 String）。
struct LifeIndexItem: Equatable, Sendable {
    let kind: LifeIndexKind
    let level: LifeIndexLevel
    /// 补充数值文案（如 "UV 8"），UI 选择性展示；引擎不拼最终句。
    let value: String?
}

/// 生活指数规则引擎（纯函数）。
enum LifeIndexEngine {

    // MARK: - 阈值（D-A2P1-1 备案，首版经验值）

    /// 防晒：UV ≥ 8 必须防晒；≥ 6 注意；< 3 无需。
    static let uvVeryHigh: Double = 8
    static let uvHigh: Double = 6
    static let uvLow: Double = 3
    /// 洗车：降水概率 < 20% 适宜；≥ 60% 不宜。
    static let washDryProbability: Double = 20
    static let washWetProbability: Double = 60
    /// 运动：降水概率 < 30% 且气温 [10, 30]℃ 且无强天气码。
    static let exercisePrecipThreshold: Double = 30
    static let exerciseLowTemp: Double = 10
    static let exerciseHighTemp: Double = 30
    /// 强天气码（雷暴等，WMO 95–99）：运动不宜。
    static let strongWeatherCodes: Range<Int> = 95..<100

    /// 计算四项生活指数（顺序固定：防晒→穿衣→洗车→运动）。
    /// - Parameter snapshot: 天气快照（uvIndexMax 来自 `daily[0]`，A2-P0 已落地）。
    static func indices(for snapshot: WeatherSnapshot) -> [LifeIndexItem] {
        [
            sunIndex(for: snapshot),
            clothingIndex(for: snapshot),
            carWashIndex(for: snapshot),
            exerciseIndex(for: snapshot)
        ]
    }

    // MARK: - 单项规则（internal 便于独立单测）

    /// 防晒：输入今日 UV 峰值（`daily[0].uvIndexMax`，A2-P0 落地）。
    static func sunIndex(for snapshot: WeatherSnapshot) -> LifeIndexItem {
        let uv = snapshot.daily?.first?.uvIndexMax
        guard let uv else {
            return LifeIndexItem(kind: .sun, level: .neutral, value: nil)
        }
        let level: LifeIndexLevel
        if uv >= uvVeryHigh {
            level = .avoid       // "必须防晒"（避免暴晒语义，UI 显示"不宜（暴晒）"档）
        } else if uv >= uvHigh {
            level = .caution     // 注意防晒
        } else if uv < uvLow {
            level = .recommended // 无需防晒
        } else {
            level = .neutral
        }
        return LifeIndexItem(kind: .sun, level: level, value: "UV \(Int(uv.rounded()))")
    }

    /// 穿衣：纯温度启发式（今日高/低温，不联合体感/风——P1 够用，D-A2P1-1）。
    static func clothingIndex(for snapshot: WeatherSnapshot) -> LifeIndexItem {
        // 优先用 daily[0] 的高低温；缺则回退 snapshot 的 dailyHigh/Low。
        let high = snapshot.daily?.first?.tempMax ?? snapshot.dailyHigh
        let low = snapshot.daily?.first?.tempMin ?? snapshot.dailyLow
        let level: LifeIndexLevel
        let hint: String
        if high < 5 {
            level = .caution
            hint = "厚羽绒"
        } else if high < 15 {
            level = .neutral
            hint = "毛衣外套"
        } else if high <= 26 {
            level = .recommended
            hint = "轻薄"
        } else {
            level = .neutral
            hint = "短袖"
        }
        return LifeIndexItem(kind: .clothing, level: level,
                             value: "今日 \(Int(low.rounded()))–\(Int(high.rounded()))℃ · \(hint)")
    }

    /// 洗车：今日降水概率（daily[0].precipitationProbability；nil = 未知 → 中性）。
    static func carWashIndex(for snapshot: WeatherSnapshot) -> LifeIndexItem {
        let probability = snapshot.daily?.first?.precipitationProbability
        guard let probability else {
            return LifeIndexItem(kind: .carWash, level: .neutral, value: nil)
        }
        let level: LifeIndexLevel
        if probability >= washWetProbability {
            level = .avoid       // 不宜洗车
        } else if probability < washDryProbability {
            level = .recommended // 适宜洗车
        } else {
            level = .neutral     // 酌情
        }
        return LifeIndexItem(kind: .carWash, level: level,
                             value: "降水概率 \(Int(probability))%")
    }

    /// 运动：联合判据 —— 降水概率 < 30% 且气温 ∈ [10, 30]℃ 且无强天气码。
    static func exerciseIndex(for snapshot: WeatherSnapshot) -> LifeIndexItem {
        let probability = snapshot.daily?.first?.precipitationProbability
        let high = snapshot.daily?.first?.tempMax ?? snapshot.dailyHigh
        let code = snapshot.daily?.first?.weatherCode ?? snapshot.weatherCode

        let hasStrongWeather = strongWeatherCodes.contains(code)
        let tooWet = (probability.map { $0 >= exercisePrecipThreshold }) ?? false
        let tempOk = high >= exerciseLowTemp && high <= exerciseHighTemp

        let level: LifeIndexLevel
        if hasStrongWeather || tooWet {
            level = .avoid       // 雷暴/强降水：不宜户外运动
        } else if !tempOk {
            level = .neutral     // 温度不适但无强天气：中性
        } else {
            level = .recommended // 全条件满足：适宜
        }
        return LifeIndexItem(kind: .exercise, level: level, value: nil)
    }
}

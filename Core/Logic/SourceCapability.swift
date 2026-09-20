//
//  SourceCapability.swift
//  Core / Logic  [App + Widget 共用]
//
//  源能提供哪一类「能力」（不是「能替代整包」）。
//  第二源 sunrise-sunset.org 只声明 `.solarEvents`，故只能补日出/日落那一格，
//  无法挂上温度/降水/风——这正是「按能力挂载」而非「按整源替换」的落点（ARCH §3.2）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 数据源能力（按能力挂载的寻址单位）。
enum SourceCapability: String, Codable, CaseIterable, Sendable {
    case currentObservation      // 实况标量
    case hourlyForecast          // 逐时序列
    case dailyForecast           // 逐日序列
    case minutelyPrecipitation   // 短时降水（15min）
    case airQuality
    case historicalArchive
    case ensemble
    case geocoding
    case solarEvents             // 日出/日落/昼长/太阳正午 ← 第二源只需这一项
    case basicNumericFields      // 基础数值标量：温/压/湿/云量/风速/风向
                                 // ← 第三源 MET Norway（compact）只声明这一项。
                                 //   单列一个 case 而不复用 `.currentObservation`：
                                 //   `.currentObservation` 隐含体感温度 / 天气码 / 降水等
                                 //   本轮并不提供 → 复用会**虚报能力**（下游按能力寻址时会误信）。
}

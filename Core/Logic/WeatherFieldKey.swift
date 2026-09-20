//
//  WeatherFieldKey.swift
//  Core / Logic  [App + Widget 共用]
//
//  可被「逐字段降级」的字段键（L2 标注与 L4 诊断的寻址单位）。
//  降级单位是「字段」而非「快照」，所以这里列出可被辅助源补齐的全部字段。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 可被逐字段降级的字段键。
enum WeatherFieldKey: String, Codable, CaseIterable, Sendable {
    case temperature, apparentTemperature, humidity, pressure, weatherCode
    case windSpeed, windDirection, windGust
    case precipitation, precipitationProbability, precipitationSum
    case uvIndex, visibility, dewPoint, cloudCover
    case sunrise, sunset, daylightDuration, sunshineDuration, solarNoon
}

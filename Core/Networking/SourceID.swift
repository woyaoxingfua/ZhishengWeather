//
//  SourceID.swift
//  Core / Networking  [App + Widget 共用]
//
//  数据源稳定标识（字符串真源，禁散落字面量）。
//  第二源 sunrise-sunset.org 的标识在此登记，主源/空气源等同理。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 数据源稳定标识。
///
/// 用 `RawRepresentable`（字符串真源）而非裸字符串，避免全仓散落
/// `"sunrise-sunset"` 之类的字面量；新增源只在 `static let` 处登记一次。
struct SourceID: RawRepresentable, Codable, Hashable, Sendable {

    /// 字符串真源（如 "sunrise-sunset"）。
    let rawValue: String

    /// 显式非 failable 初始化（满足 `RawRepresentable` 的 `init?(rawValue:)`）。
    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 主天气源（Open-Meteo forecast，现状整体快照的来源）。
    static let openMeteoForecast = SourceID(rawValue: "open-meteo-forecast")
    /// 空气质量源（Open-Meteo air-quality）。
    static let openMeteoAirQuality = SourceID(rawValue: "open-meteo-air-quality")
    /// 第二源：日出日落（仅补 solarEvents 能力字段）。
    static let sunriseSunset = SourceID(rawValue: "sunrise-sunset")
}

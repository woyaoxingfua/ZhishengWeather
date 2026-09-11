//
//  DailyForecast.swift
//  Core / Models  [App + Widget 共用]
//
//  F-A 逐日预报：单个自然日的领域点。
//  风格与 `HourlyPoint` 保持一致：Codable + Equatable + Identifiable + Sendable。
//
//  v1.1 修订（A1-4）：追加可选 `sunrise` / `sunset`（按日存，而非只在
//  snapshot 存今天 —— A2-5「逐日行展开看日落」直接复用，避免二次迁移，
//  ARCH-A1 §1.4）。全部可选 + 合成 Codable，旧缓存解码不失败。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 逐日预报中的一个自然日。
struct DailyForecast: Codable, Equatable, Identifiable, Sendable {

    /// 当日零点（epoch 秒解析而来；Open-Meteo daily.time = 当地当日 00:00）。
    var date: Date
    /// 当日 WMO 天气码。
    var weatherCode: Int
    /// 当日最高温（℃）。
    var tempMax: Double
    /// 当日最低温（℃）。
    var tempMin: Double
    /// 当日最大降水概率（%）。
    /// nil = 服务端未返回 / null → UI 显示 "--"，**绝不显示 0%**（AC-A5）。
    var precipitationProbability: Int?
    /// 当日日出（A1 新增，可选）。
    /// 经 `ISOTimeStringDecoder` 从 ISO 墙钟字符串解码；
    /// nil = 字符串缺失 / 解析失败 / 旧缓存无此键（UI 隐藏该段）。
    var sunrise: Date? = nil
    /// 当日日落（A1 新增，可选）。语义同 `sunrise`。
    var sunset: Date? = nil

    /// 以日期作为稳定标识（自然日唯一）。
    var id: Date { date }
}

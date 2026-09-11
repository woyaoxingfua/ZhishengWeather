//
//  GeocodingProviding.swift
//  Core / Networking  [App + Widget 共用]
//
//  F-B：geocoding 搜索协议抽象。
//  PRD §3.5.1 明示**非可选项** —— 搜索失败态（AC-B17）的单测依赖 Fake 注入。
//

import Foundation

/// 城市搜索提供者抽象。
///
/// 所有失败路径收敛为 `WeatherError`（复用既有错误类型，不新造错误枚举），
/// 与 `WeatherProviding` 的错误语义保持一致。
protocol GeocodingProviding: Sendable {

    /// 按城市名搜索候选城市。
    /// - Parameter name: 城市名（中文安全）。
    /// - Returns: 候选城市数组；无命中时为空数组（≠ 失败，AC-B19）。
    /// - Throws: `WeatherError`（badURL / badStatus / network / decoding）。
    func search(name: String) async throws -> [City]
}

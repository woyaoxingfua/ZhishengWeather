//
//  WeatherProviding.swift
//  Core / Networking  [App + Widget 共用]
//
//  取数协议 + 唯一网络/解析错误类型（便于注入 Fake 做单测）。
//

import Foundation

/// 取数相关的全部错误（`Equatable` 便于测试断言）。
enum WeatherError: Error, Equatable, Sendable {
    /// URL 拼装失败。
    case badURL
    /// HTTP 状态码非 2xx。
    case badStatus(Int)
    /// 传输层失败。
    case network(String)
    /// 解码失败。
    case decoding(String)
}

/// 天气数据提供者抽象。
protocol WeatherProviding: Sendable {
    /// 依据坐标取回一次天气快照。
    func fetch(latitude: Double, longitude: Double) async throws -> WeatherSnapshot
}

//
//  WeatherProviding.swift
//  Core / Networking  [App + Widget 共用]
//
//  取数协议 + 唯一网络/解析错误类型（便于注入 Fake 做单测）。
//
//  本轮扩展（可诊断性修复）：`WeatherError` 新增三个细分 case——
//   `timeout`（超时单列）、`decodingDetail`（**携带 codingPath**）、
//   `dataMissing`（请求的城市无数据）、`appGroup`（共享容器故障，不再静默）。
//  既有 case（badURL / badStatus / network / decoding）**原样保留**，
//  保证既有调用点与既有测试零改动。
//  纯分类与文案见 `Core/Logic/FaultDomain.swift`。
//

import Foundation

/// 取数相关的全部错误（`Equatable` 便于测试断言）。
enum WeatherError: Error, Equatable, Sendable {
    /// URL 拼装失败。
    case badURL
    /// HTTP 状态码非 2xx（4xx / 5xx 的细分由 `FaultDomain.classify(statusCode:)` 裁定）。
    case badStatus(Int)
    /// 传输层失败（非超时）。
    case network(String)
    /// 解码失败（**旧抛点，无字段路径**；新代码请走 `decodingDetail`）。
    case decoding(String)
    /// 请求超时（从网络失败中细分出来，文案与处置不同）。
    case timeout(String)
    /// 解码失败，**携带 `DecodingError` 上下文**（codingPath + debugDescription）。
    ///
    /// run37 真机事故的直接修复：字段路径必须可达，否则「哪个字段解不出来」
    /// 这条唯一线索会在错误传递中丢失。
    case decodingDetail(path: String, debugDescription: String)
    /// 请求的城市**无可用数据**（响应结构性为空：既无逐小时也无逐日）。
    case dataMissing(String)
    /// App Group 共享容器故障（读 / 写失败或容器不可用）——不再静默。
    case appGroup(String)
}

/// 天气数据提供者抽象。
protocol WeatherProviding: Sendable {
    /// 依据坐标取回一次天气快照。
    func fetch(latitude: Double, longitude: Double) async throws -> WeatherSnapshot
}

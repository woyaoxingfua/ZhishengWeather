//
//  SourceDiagnosticsProviding.swift
//  Core / Networking  [App + Widget 共用]
//
//  L4 开发者诊断接口（ARCH §5）：仅留接口，D-C13 对比视图本轮**不做**。
//
//  目的：让将来「多源对比视图」不必再动骨架——直接消费本协议即可拿到
//  各源对同字段的原始取值，做主备分歧可视化。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 单源对某字段的原始取值（诊断用，保留字符串原貌便于对比）。
struct SourceRawValue: Sendable {
    var sourceID: SourceID
    var value: String
}

/// L4 多源诊断协议（本轮仅留接口，无 App 侧实现）。
protocol SourceDiagnosticsProviding {
    /// 取某字段在各源的原始取值（用于主备分歧对比视图）。
    func rawValue(for key: WeatherFieldKey, latitude: Double, longitude: Double) async -> [SourceRawValue]
}

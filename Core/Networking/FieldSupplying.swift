//
//  FieldSupplying.swift
//  Core / Networking  [App + Widget 共用]
//
//  源的声明面（DataFieldSource）与能力型取数面（FieldSupplying）。
//  第二源 sunrise-sunset.org 实现 FieldSupplying，只负责补自己声明能力的字段。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 源的声明面：我是谁、我能干什么、我的必填集是什么（运行期 EV-1 用它判「缺字段」）。
protocol DataFieldSource: Sendable {
    /// 稳定标识。
    var id: SourceID { get }
    /// 展示名（设置页「多源管理」使用）。
    var displayName: String { get }
    /// 我能提供哪些能力（如 [.solarEvents]）。
    var capabilities: Set<SourceCapability> { get }
    /// 必填字段集（运行期 EV-1 判「缺字段」的输入）。
    var requiredFields: Set<WeatherFieldKey> { get }
}

/// 能力型源：只负责「补自己声明能力的字段」，返回稀疏 FieldPatch。
protocol FieldSupplying: DataFieldSource {
    /// 按坐标拉取所请求能力的字段补丁。
    ///
    /// - Parameters:
    ///   - latitude: 纬度（WGS84）。
    ///   - longitude: 经度（WGS84）。
    ///   - capabilities: 本次请求的能力集合（源可据此裁剪，缺能力则回空补丁）。
    ///   - now: 采集时刻（调用方注入，源内不取时钟）。
    /// - Returns: 稀疏字段补丁（未命中的字段为 nil）。
    /// - Throws: 失败收敛为 `WeatherError`（由调用方按纪律隔离，不 rethrow 到主链路）。
    func fetchFields(latitude: Double,
                     longitude: Double,
                     capabilities: Set<SourceCapability>,
                     now: Date) async throws -> FieldPatch
}

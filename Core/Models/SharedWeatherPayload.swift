//
//  SharedWeatherPayload.swift
//  Core / Models  [App + Widget 共用]
//
//  App Group 共享容器的落盘结构：{ snapshot, updatedAt, timeZoneIdentifier? }。
//
//  v1.1 修订（D-4 Widget 时区补齐）：新增**可选** `timeZoneIdentifier`（默认 nil）。
//  `LocationInfo` 无时区字段，故布局时区随载荷一起传递——Widget 才能在异地城市
//  按城市当地时区渲染时刻（app 侧已在 ebd6560 / e530ce8 完成）。
//  兼容核心（R3）：可选 + 合成 Codable + 默认 nil —— 旧缓存 JSON 无此键 → 解码 nil、
//  不失败；Widget 侧 nil → 回退**设备时区**（保持既有行为，绝不硬编码偏移）。
//  **禁止**手写 `init(from:)` / 引入 payloadVersion。
//

import Foundation

/// 写入共享容器的载荷。主 App 写、Widget 只读。
struct SharedWeatherPayload: Codable, Equatable, Sendable {

    /// 天气快照。
    var snapshot: WeatherSnapshot
    /// 该快照的写入时间（用于「更新于 HH:mm」与新鲜度判断）。
    var updatedAt: Date
    /// 该快照对应城市的 IANA 时区标识（如 "Asia/Shanghai"）。
    ///
    /// nil = 旧缓存无此键 / 城市无时区信息 → 消费方回退设备时区。
    /// 声明在末尾且带默认值：既有 `SharedWeatherPayload(snapshot:updatedAt:)` 调用点零改动。
    var timeZoneIdentifier: String? = nil
}

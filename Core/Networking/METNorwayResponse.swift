//
//  METNorwayResponse.swift
//  Core / Networking  [App + Widget 共用]
//
//  第三源 DTO。**所有字段可选 / 嵌套块可选 / 数组元素亦可选** ——
//  缺键、缺块、元素为 `null` 一律**不得让解码抛错**。
//
//  ⚠️ 为什么数组元素必须写成 `[Entry?]`：本仓库真实吃过一次亏 ——
//  DTO 把数组元素声明为非可选，响应末尾一个 `null` 元素就让**整包**解码失败，
//  结果**主屏与小组件同时无数据**。这里 `timeseries` 是 89–90 条的长数组，
//  尾部出现 `null` 的概率不可忽略，故元素声明为可选（`null` → 跳过该条）。
//
//  **实测键名（2026-09-20 探针，HTTP 200，见 METNorwayEndpoint 文件头）**：
//  `properties.timeseries[].{time, data.instant.details}`。
//
//  **刻意不建模的块**（本轮无消费者，不声明就无从误用）：
//  · `properties.meta.{updated_at, units}` —— 单位与我们一致，不做换算，
//    故不需要读 units；采集时刻用注入的 `now`，不读 `updated_at`。
//  · `data.next_1_hours` / `next_6_hours` / `next_12_hours` —— 降水与天气符号
//    本轮明确不做（`symbol_code` 是 MET 自有符号集，映射成 WMO 码需长期维护表）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 第三源响应 DTO（解码失败安全：全部可选）。
struct METNorwayResponse: Decodable, Sendable {

    /// `properties` 块。
    struct Properties: Decodable, Sendable {
        /// 逐小时序列（**元素可选**：`null` 元素不得让整包解码失败）。
        var timeseries: [Entry?]?
    }

    /// 序列单条。
    struct Entry: Decodable, Sendable {
        /// 时刻（ISO8601 UTC，形如 "2026-09-20T05:00:00Z"）。
        var time: String?
        /// 数据块。
        var data: Data?

        /// `data` 块（只建模本轮要用的 `instant`）。
        struct Data: Decodable, Sendable {
            /// 瞬时值块。
            var instant: Instant?

            /// `instant` 块。
            struct Instant: Decodable, Sendable {
                /// 明细块。
                var details: Details?

                /// `details`：本源映射的全部字段（缺键 → nil，**不是 0**）。
                ///
                /// 单位与我们一致（℃ / hPa / % / m/s / 度）→ **不做任何换算**。
                struct Details: Decodable, Sendable {
                    /// 气温（celsius）。
                    var air_temperature: Double?
                    /// 海平面气压（hPa）。
                    var air_pressure_at_sea_level: Double?
                    /// 相对湿度（%）。
                    var relative_humidity: Double?
                    /// 总云量（%）。
                    var cloud_area_fraction: Double?
                    /// 风速（m/s）。
                    var wind_speed: Double?
                    /// 风的**来向**（度）——与 Open-Meteo 同约定，**不翻转**。
                    /// ⚠️ `0`（正北）是合法取值，绝不可被当成"缺失"。
                    var wind_from_direction: Double?
                }
            }
        }
    }

    /// 属性块（缺失 → nil，由 mapper 回落为空补丁）。
    var properties: Properties?
}

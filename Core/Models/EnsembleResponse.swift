//
//  EnsembleResponse.swift
//  Core / Models  [App + Widget 共用]
//
//  Open-Meteo Ensemble API（独立域名
//  `ensemble-api.open-meteo.com/v1/ensemble`）的原始 DTO。
//
//  ⚠️ 与其余 DTO 的关键差异：**成员键是动态的**。响应 `hourly` 块内的成员并非固定
//  字段名，而是 `precipitation`（控制成员）+ `precipitation_member01…memberNN`
//  （两位零填充，NN 随模式变化：1 / 30 / 40 / 50…，见 PRD §11-8）。故 `Hourly`
//  需要一个**手写的 `init(from:)`** 把「除 `time` 外的所有键」收进字典 `series`。
//
//  注意：本条手写 `init(from:)` **只落在 DTO 上**，且此 DTO **不落盘、不进共享容器**
//  （成员数据仅存于 WeatherViewModel 内存态）。项目「禁手写 init(from:)」的红线
//  （ARCH §5 条款 2）针对的是**持久化模型**（旧缓存兼容），**不适用于本动态键 DTO**。
//  唯一替代方案是把整块交给 `JSONSerialization`，那会破坏「service → Codable DTO →
//  mapper」的既有链路范式；此处选择显式 DTO 解码。
//
//  整键可选（DTO 不落盘）：服务端异常省略 `hourly` / 某成员键时不炸，缺失由 mapper
//  收敛为空预报（UI 整块隐藏）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// Open-Meteo Ensemble 原始响应（仅保留本项目所需部分）。
struct EnsembleResponse: Codable, Sendable {

    /// 逐小时块。**成员键动态**，故 `series` 用字典承载；`time` 单独解出。
    struct Hourly: Codable, Sendable {

        /// 本地墙钟时刻字符串（默认 iso8601，如 "2026-09-16T00:00"）。整键可选。
        let time: [String]?

        /// 其余全部键（控制成员 + 各成员）→ 「键名 → 逐小时数值序列」。
        /// 数值元素可 null（服务端缺失）→ `Double?`。
        let series: [String: [Double?]]

        /// 任意键名的 CodingKey（成员键动态，无法用静态枚举）。
        private struct FlexibleKey: CodingKey {
            let stringValue: String
            let intValue: Int?

            init?(stringValue: String) {
                self.stringValue = stringValue
                self.intValue = nil
            }

            init?(intValue: Int) {
                self.stringValue = String(intValue)
                self.intValue = intValue
            }
        }

        /// 手写解码：遍历 `hourly` 全部键，`time` 取字符串数组，其余按数值数组
        /// 收进 `series`。键缺失 / 类型不符 → 该键跳过（不抛错）。
        /// - Parameter decoder: JSON 解码器。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: FlexibleKey.self)
            var decodedTime: [String]? = nil
            var collected: [String: [Double?]] = [:]

            for key in container.allKeys {
                if key.stringValue == "time" {
                    decodedTime = try? container.decode([String].self, forKey: key)
                } else if let values = try? container.decode([Double?].self, forKey: key) {
                    collected[key.stringValue] = values
                }
            }

            self.time = decodedTime
            self.series = collected
        }
    }

    /// 该响应墙钟字符串所属的 UTC 偏移秒（时间解释用）。整键可选。
    let utc_offset_seconds: Int?
    /// 时区标识（诊断用）。整键可选。
    let timezone: String?
    /// 逐小时块。整键可选。
    let hourly: Hourly?
}

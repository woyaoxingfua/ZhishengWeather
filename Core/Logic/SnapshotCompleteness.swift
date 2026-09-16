//
//  SnapshotCompleteness.swift
//  Core / Logic  [App + Widget 共用]
//
//  快照「实质是否为空」的纯判定（用于「请求的城市无数据」故障域）。
//
//  为什么单独成文件而非写成 `WeatherSnapshot` 的成员：本项目纪律要求任何
//  有分支语义的判定都在 Core 里可被纯单测覆盖（CI-pitfalls P-18 同源盲区），
//  独立小类型便于直接喂各种边界组合做断言。
//

import Foundation

/// 快照完整性判定（纯函数）。
enum SnapshotCompleteness {

    /// 快照是否**实质无数据**：既无逐小时序列，也无逐日预报。
    ///
    /// 语义：Open-Meteo 对有效坐标总会返回 `hourly`；若两者皆空，说明该坐标
    /// 拿不到任何预报时间线 —— 归为「数据缺失」而非「解码成功」。
    /// 注：实况（`current`）在 DTO 里是非可选字段，缺了会先在解码阶段失败，
    /// 故此处不需重复检查。
    /// - Parameter snapshot: 映射后的领域快照。
    /// - Returns: 无逐小时且无逐日 → true。
    static func isEffectivelyEmpty(_ snapshot: WeatherSnapshot) -> Bool {
        if !snapshot.hourly.isEmpty { return false }
        if let daily = snapshot.daily, !daily.isEmpty { return false }
        return true
    }
}

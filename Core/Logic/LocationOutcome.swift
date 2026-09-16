//
//  LocationOutcome.swift
//  Core / Logic  [App + Widget 共用]
//
//  最近一次定位的**结果分类**（定位层只产出事实，"要不要提示用户"由
//  `FaultDomain.classify(locationOutcome:)` 裁定）。
//
//  为什么放 Core（CI-pitfalls P-18 同源盲区纪律）：`LocationProvider` 在
//  主 App target（不可单测），若把「拒绝 → 提示」的分支写在它里面，测试
//  只能手写模拟，容易与实现共享同一套错误假设。故把**判定**下沉为纯枚举 +
//  纯映射，`LocationProvider` 只负责如实记录结果。
//

import Foundation

/// 最近一次定位请求的结果。
enum LocationOutcome: Equatable, Sendable {

    /// 定位成功，拿到真实坐标。
    case authorized
    /// 权限被拒绝 / 受限（用户可在系统设置里恢复）。
    case denied
    /// 尚未决定（授权弹窗未作答或等待定位结果超时）——静默回落默认城市。
    case undetermined
    /// 已授权但本次定位失败（`CLLocationManager` 回调 didFailWithError）。
    case failed
}

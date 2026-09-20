//
//  FieldValue.swift
//  Core / Networking  [App + Widget 共用]
//
//  辅助源可承载的字段值（类型擦除枚举）。T10 §3.1。
//
//  为什么需要它：泛化前的 `FieldPatch` 是「每个字段一个写死属性」
//  （`sunrise` / `sunset` / `solarNoon` / `daylightDuration`），于是接入任何
//  新字段都要同时改「属性 + fields 的 if + merge 的分支 + isFieldNil 的 case」
//  四处，漏一处该字段就**静默恒 nil**（UI 永远 `--`、无报错）。
//  改成「一个值容器 + 类型擦除枚举」后，新字段**零改动**即自动参与。
//
//  **单位纪律（硬约束，P2 §3.1 / §9 R-2）**：`.number` **只存值、不携带换算语义**；
//  字段的单位是**该字段自身的契约**（`precipitation` 是 mm、`snowfall` 是 **cm**，
//  差 10 倍）。**本容器绝不换算**；换算只允许发生在纯格式化器
//  `Core/Logic/WeatherFieldFormatters.swift`。→ 泛化**不得**变成「顺手把 cm 转 mm」的入口。
//
//  兼容性事实：本类型（与 `FieldPatch`）**不 Codable、不落盘、不进 Widget 载荷**，
//  故泛化**没有**任何缓存 / 线格式兼容负担，唯一兼容面是源码级调用点。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 辅助源可承载的字段值（类型擦除，防「把 Date 当 Double 用」）。
///
/// 单一存储点：`FieldPatch.values` 是**唯一**的字段存储，`fields` / `isMissing` /
/// 合并遍历全部由它派生 —— 不可能出现「日期字典有、数值字典没有」的幽灵态。
enum FieldValue: Equatable, Sendable {

    /// 已归一单位的数值（℃ / m/s / mm / cm / % …）。**只存值，不携带换算语义**。
    case number(Double)
    /// 时长（昼长 / 日照时数，秒）。
    case seconds(TimeInterval)
    /// 绝对时刻（日出 / 日落 / 太阳正午）。
    case instant(Date)
}

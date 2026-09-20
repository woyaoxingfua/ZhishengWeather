//
//  FieldPatch.swift
//  Core / Networking  [App + Widget 共用]
//
//  一个辅助源的「字段补丁」：只装它声明能力范围内的字段，绝不携带整包快照。
//  这是「按能力挂载而非按整源替换」的载体。
//
//  ── T10 泛化（ARCH-T10 §3.1）────────────────────────────────────────────────
//  泛化前本类型是 **4 个写死属性**（sunrise / sunset / solarNoon / daylightDuration），
//  `fields` 也是这 4 个的 `if`。任何新能力都无处承载，且每加一个字段要同时改
//  四处（属性 / fields / merge / isFieldNil），漏一处 → 该字段**静默恒 nil**。
//  现在改为「**单一值字典 + 类型擦除枚举**（`FieldValue`）」：
//    · `fields` / `isMissing` / 合并遍历全部由 `values` **派生**，不可能不同步；
//    · 新增字段**零改动**即自动参与（容器不认识字段名）。
//  ⚠️ **不许**退回「每个字段一个属性」的写法（那正是本泛化要消除的病根）。
//
//  **稀疏补丁语义（必须保住）**：**未命中的字段是「不存在」（`isMissing == true`）**，
//  与「值是 0 / 0.0」严格区分 —— `set(.temperature, .number(0))` 之后该字段
//  **不是**缺失。UI 对缺失走 `--` / 隐藏，**绝不用假值填**。
//
//  兼容性事实：`FieldPatch` 现声明为 `Equatable, Sendable`，**不是 `Codable`**
//  → **不落盘、不进共享载荷、不进 Widget**。故泛化**没有**缓存 / 线格式兼容负担，
//  唯一兼容面是源码级调用点；因此**不需要**任何兼容 façade（旧访问器已全部删除，
//  避免留下「两套入口」——本项目曾因两处入口漂移吃过亏）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 辅助源产出的「稀疏字段补丁」。
///
/// `capturedAt` 由调用方注入（Core 禁内部取时钟），承载时间维度，
/// 使后续 `FieldFallbackResolver` 纯函数化、无需读墙钟。
struct FieldPatch: Equatable, Sendable {

    /// 产出此补丁的源标识。
    var sourceID: SourceID
    /// 采集时刻（调用方注入，非源内取时钟）。
    var capturedAt: Date
    /// 字段值存储（**唯一**存储点；未命中的字段不在字典里）。
    private var values: [WeatherFieldKey: FieldValue]

    /// 已装载字段键（派生，取代原来的 4 个 `if`）。
    ///
    /// 用于快速判断「该源补了哪些字段」。注意：字典键序不保证稳定，调用方
    /// 只应做集合语义的比较（本项目内的唯一调用点是 `merge` 的并集）。
    var fields: [WeatherFieldKey] { Array(values.keys) }

    /// 便捷构造：默认空补丁（全字段缺失）。
    init(sourceID: SourceID,
         capturedAt: Date,
         values: [WeatherFieldKey: FieldValue] = [:]) {
        self.sourceID = sourceID
        self.capturedAt = capturedAt
        self.values = values
    }

    /// 写入一个字段值（`set` 之后该字段即「已装载」，不再是缺失）。
    mutating func set(_ key: WeatherFieldKey, _ value: FieldValue) {
        values[key] = value
    }

    /// 取某字段的擦除值（未装载 → nil，不造假值）。
    func value(_ key: WeatherFieldKey) -> FieldValue? {
        values[key]
    }

    /// 取数值型字段值（类型不符或未装载 → nil）。
    func number(_ key: WeatherFieldKey) -> Double? {
        guard case .some(.number(let value)) = values[key] else { return nil }
        return value
    }

    /// 取时长型字段值（秒；类型不符或未装载 → nil）。
    func seconds(_ key: WeatherFieldKey) -> TimeInterval? {
        guard case .some(.seconds(let value)) = values[key] else { return nil }
        return value
    }

    /// 取时刻型字段值（类型不符或未装载 → nil）。
    func instant(_ key: WeatherFieldKey) -> Date? {
        guard case .some(.instant(let value)) = values[key] else { return nil }
        return value
    }

    /// 该字段是否缺失（EV-1 判据，ARCH-T10 §3.3）。
    ///
    /// 判据与**字段名无关**：只问「这个 key 在不在补丁里」。因此任何新字段
    /// 只要被某个源的 `requiredFields` 列出，就**自动**参与 EV-1 ——
    /// 没有 `default` 分支可供漏写（旧实现 `default: return false` 会让新字段
    /// 恒判「不缺失」，EV-1 **永不触发**，源明明坏了却永远不被摘）。
    func isMissing(_ key: WeatherFieldKey) -> Bool {
        values[key] == nil
    }
}

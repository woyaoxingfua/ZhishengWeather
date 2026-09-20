//
//  SourceID.swift
//  Core / Networking  [App + Widget 共用]
//
//  数据源稳定标识（字符串真源，禁散落字面量）。
//
//  ── T10 变更（ARCH-T10 §3.4）────────────────────────────────────────────────
//  由 `struct RawRepresentable` 改为 **`enum ... CaseIterable`**：
//  `SourceID.allCases` 由**编译器**保证完备 —— 新增源必须加 case，
//  **无法「忘记声明」**。这使「每个被声明的源都有目录条目」这条性质可被
//  机械守卫（`SourceCatalog.all` 与之求双射）钉死；漏登记会让该源
//  自动摘除**静默哑火**且设置页**隐身**（本仓库已存在的 `openMeteoAirQuality`
//  缺目录项就是现实样本）。
//
//  ⚠️ 迁移注意：`init?(rawValue:)` 现在是**可失败**的（enum 合成）。
//  `SourceHealthLedger` 反序列化历史键时对未知 rawValue **跳过该项**，
//  绝不造一个假 id（见该文件注释）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 数据源稳定标识（每个源一个 case；rawValue 即持久化 / 落盘用的稳定字符串）。
enum SourceID: String, CaseIterable, Sendable {

    /// 主天气源（Open-Meteo forecast，现状整体快照的来源）。
    case openMeteoForecast = "open-meteo-forecast"
    /// 空气质量源（Open-Meteo air-quality）。
    case openMeteoAirQuality = "open-meteo-air-quality"
    /// 第二源：日出日落（仅补 solarEvents 能力字段）。
    case sunriseSunset = "sunrise-sunset"
    /// 第三源：MET Norway（api.met.no locationforecast compact，免 Key）
    /// —— 仅补**基础数值字段**（温 / 压 / 湿 / 云 / 风），且是**不同的数值模式**
    /// （与 Open-Meteo 交叉校验才有意义）。
    case metNorwayForecast = "met-norway-forecast"
}

// MARK: - Codable

extension SourceID: Codable {

    /// 解码：接受**单值字符串**形态（enum 的惯用形态），
    /// 并**兼容旧 struct 的 keyed 容器**形态（`{"rawValue": "..."}`）。
    ///
    /// 为什么必须两种都收：本类型的旧定义是
    /// `struct SourceID: RawRepresentable, Codable { let rawValue: String }`，
    /// 其编码形态与 enum 的合成形态**可能不同**（合成 Codable 对单属性 struct
    /// 走 keyed 容器）。而 `SourcePreferences` 把用户「手动停用某源」的偏好
    /// 以 `Set<SourceID>` **落盘在 UserDefaults** —— 若只认一种形态，
    /// 升级后旧数据解不出来，`try?` 静默回落成空集合，用户的停用选择被**无声清空**。
    /// 双形态解码把这个静默行为变更彻底消除（写出去一律用单值形态）。
    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let raw = try? single.decode(String.self), let id = SourceID(rawValue: raw) {
            self = id
            return
        }
        // 兼容旧 keyed 形态。
        let keyed = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let raw = try keyed.decode(String.self, forKey: .rawValue)
        guard let id = SourceID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .rawValue,
                                                   in: keyed,
                                                   debugDescription: "未知的 SourceID rawValue: \(raw)")
        }
        self = id
    }

    /// 编码：一律写**单值字符串**（enum 的惯用形态）。
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// 旧形态（struct 合成 Codable）的键。
    private enum LegacyCodingKeys: String, CodingKey {
        case rawValue
    }
}

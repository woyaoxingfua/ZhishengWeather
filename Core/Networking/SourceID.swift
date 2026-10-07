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
    /// 第四源：海浪（Open-Meteo Marine，`marine-api.open-meteo.com`，免 Key）——
    /// 仅补**海浪要素**（浪高 / 浪向 / 周期 / 涌浪），且**只在沿海坐标**才有数据。
    ///
    /// ⚠️ rawValue **必须与实际域名语义一致**：端点已从 `api.open-meteo.com`
    /// 迁到**独立子域名** `marine-api.open-meteo.com`，写在主站上一律 404
    /// （实测 `{"reason":"Not Found"}`）。故此处是 `open-meteo-marine`，
    /// **不是** `open-meteo-forecast` 的变体、也不是 `marine.open-meteo.com`。
    case marineForecast = "open-meteo-marine"
    /// 第五源：河道流量（Open-Meteo Flood，`flood-api.open-meteo.com`，免 Key）——
    /// 仅补**河道流量**（`river_discharge`，m³/s）。
    ///
    /// ⚠️ 同上：独立子域名，写在主站上 404。
    case floodForecast = "open-meteo-flood"
    /// 第六源：**官方气象预警**（中国气象局 NMC 预警信号公开接口，免 Key）
    /// —— 仅补**预警**能力（颜色等级 / 类型 / 行政区划 / 发布时间）。
    ///
    /// ⚠️ rawValue 用 `nmc-alarm`：与前五个源不同，本源**不是**数值预报，
    /// 而是**预警信号**本身（其余五家都是气象要素）。
    case nmcAlarm = "nmc-alarm"
    /// 第七源：**台风路径**（中央气象台台风网 `typhoon.nmc.cn`，免 Key、零鉴权）
    /// —— 仅补**台风路径与官方预报**能力（路径点 / 强度 / 风圈 / BABJ 预报）。
    ///
    /// ⚠️ rawValue 用 `nmc-typhoon`：与第六源 `nmc-alarm` **同域名不同服务**
    /// （`www.nmc.cn/rest/findAlarm` 是预警信号，本源是
    /// `typhoon.nmc.cn/weatherservice/typhoon/jsons/…` 的台风路径），
    /// 但二者是**完全不同的数据形态**（一个是预警条目，一个是路径点序列），
    /// 故**必须**是两个独立 SourceID —— 否则健康账本会把台风故障
    /// 记到预警源头上（两个源的失败域是独立的）。
    case nmcTyphoon = "nmc-typhoon"
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

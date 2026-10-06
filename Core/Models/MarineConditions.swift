//
//  MarineConditions.swift
//  Core / Models  [App + Widget 共用]
//
//  海浪领域模型（第四源 Open-Meteo Marine，独立子域名
//  `marine-api.open-meteo.com/v1/marine`，**免 Key**）。
//
//  ── 为什么单独成模型、而不塞进 `WeatherSnapshot` ──────────────────────────
//  海浪要素（浪高 / 浪向 / 周期 / 涌浪）**不属于** `WeatherFieldKey` 域，
//  与 `AirQuality` 的处境完全相同（同为独立链路的独立模型）。故：
//    · 不进 `WeatherSnapshot` / `SharedWeatherPayload` → **Widget 载荷契约零改动**；
//    · 不占用 `WeatherFieldKey` → 不参与逐字段降级与 EV-1（详见
//      `SourceDescriptor` 里 marine 源 `requiredFields` 诚实留空的注释）。
//
//  ── 语义纪律（与既有源逐条一致）────────────────────────────────────────
//  1. `0` 是**合法读数**（无浪 / 静水，0 m），**绝不**与"缺测"混为一谈：
//     `nil` = 缺测，`0` = 真的没有浪。二者在 UI 上必须分别呈现。
//  2. **负值一律视为服务端异常数据 → nil**（浪高 / 周期不可能为负；
//     绝不冒充合法读数），沿用 `AirQualityMapper.sanitizedConcentration` 的净化纪律。
//  3. **内陆坐标返回全 null 是常态**（实测北京 39.9,116.4 → 三项全 null），
//     故"整块实质无数据"必须能被独立判定 —— 见本文件的 `isEffectivelyEmpty`
//     （转发到 `SnapshotCompleteness` 那唯一权威），它把「解码成功但实质无数据」
//     这一状态显式化，供 UI 整卡隐藏。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 海浪要素（一次 marine 链路的完整领域模型）。
///
/// 全部字段可选：**缺测（nil）与 0 严格区分**，理由见文件头第 1 条。
struct MarineConditions: Codable, Equatable, Sendable {

    /// 有效浪高（m）。nil = 缺测或内陆坐标无数据；`0` = 真的无浪（合法）。
    var waveHeight: Double?
    /// 浪**来向**（度，0–360，与既有风的 `windDirection` 同一「来向」约定，**不翻转**）。
    ///
    /// ⚠️ `0`（浪自正北来）是合法取值，绝不可被当成"缺失"。
    var waveDirection: Double?
    /// 浪周期（s）。
    var wavePeriod: Double?
    /// 涌浪有效浪高（m）。
    var swellWaveHeight: Double?
    /// 涌浪来向（度）。同上，`0` 是合法取值。
    var swellWaveDirection: Double?
    /// 涌浪周期（s）。
    var swellWavePeriod: Double?

    /// 采集时刻（由 marine 端点 `current.time` 解析；端点已钉死
    /// `timeformat=unixtime`，故为 epoch 秒）。
    ///
    /// 用注入的响应时间而**非** `Date()`（Core 纪律：禁内部取时钟）。
    var capturedAt: Date?
}

extension MarineConditions {

    /// **实质无数据**判定 → 转发到 `SnapshotCompleteness.isEffectivelyEmpty(_ conditions:)`。
    ///
    /// ⚠️ 判据的**权威不在本模型**，而在 `SnapshotCompleteness` ——
    /// 「解码成功但实质无数据」这条判据全仓库只有那一处（天气快照 / 海浪 /
    /// 河道流量三者共用）。让每个模型自带一份同名判据就会变成 N 份各自实现，
    /// 必然漂移 —— 那正是 `SnapshotCompleteness` 存在的理由所要消灭的东西。
    /// 本便捷属性只是转发，**不新增**任何判定逻辑。
    var isEffectivelyEmpty: Bool {
        SnapshotCompleteness.isEffectivelyEmpty(self)
    }

    /// 全字段皆 nil 的空模型（供 mapper 的"缺块"回落路径使用）。
    ///
    /// 保留为独立具名工厂而非各处重复写六行 nil —— 空模型的构造点只有一个，
    /// 将来增字段时不会漏改出"某个构造点仍是旧字段集"的静默漂移。
    static let empty = MarineConditions(waveHeight: nil,
                                       waveDirection: nil,
                                       wavePeriod: nil,
                                       swellWaveHeight: nil,
                                       swellWaveDirection: nil,
                                       swellWavePeriod: nil,
                                       capturedAt: nil)
}
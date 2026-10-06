//
//  CoordinateTransform.swift
//  Core / Logic  [App + Widget 共用]
//
//  WGS84 ⇄ GCJ-02 换算 + **纠偏模式开关**。
//
//  ── 为什么需要它 ────────────────────────────────────────────────────────
//  RainViewer 雷达瓦片是纯 **WGS84 / EPSG:3857**；中国大陆的 Apple 底图由高德
//  供数，其坐标是 **GCJ-02**。两者叠加会出现 **266–622 m** 的系统性平移。
//
//  ── ⚠️🔴 未确认项（R1，真机闸门）────────────────────────────────────────
//  **Apple 是否会自动对 `MKTileOverlay` 施加 GCJ-02 偏移，本机无法回答。**
//  两种可能：
//    A. MapKit 把整个地图空间（含自定义 overlay）一起平移 → 我们**不该**纠偏；
//    B. MapKit 只平移底图，自定义图层仍按原始索引取 → 我们**必须**纠偏。
//  社区资料只证实了相邻事实（国内底图用高德；`addAnnotation` 的坐标按 GCJ-02
//  解释），**公开资料没有区分** A / B。本文件**不猜**，而是把不确定性做成
//  `CoordinateTransformMode` 三态开关，由用户在设置页切换、实测后收敛。
//
//  ── 真机验收方法与标准 ─────────────────────────────────────────────────
//  · 方法：北京天安门广场轮廓 / 上海黄浦江北岸线，比对雷达回波边缘与底图已知地物。
//  · 验收：偏移 **< 50 m**。
//  · 收敛：满足 → 保留 `.autoAssumeNotApplied`；不满足 → 切 `.autoAssumeAppleApplies`。
//  · **禁止**同时纠偏与不纠偏（会双重偏移，更糟）。
//
//  ── ⚠️ 已知局限（实测发现，预研报告 §3.4 的说法有误）────────────────────
//  经典 GCJ-02 边界框 `lon∈[72.004,137.8347] × lat∈[0.8293,55.8271]` 会把
//  **一批境外城市误判为境内**（实测：新加坡 167 m、首尔 459 m、乌兰巴托 449 m、
//  新德里 479 m、河内 440 m 均被错误偏移）。本项目是**全球**天气 App。
//  这里**刻意保留**该边界框而**不**手绘多边形排除：相邻国家（越南/老挝/缅甸）
//  与中国云南/广西的经纬度**矩形重叠**，手写矩形必然误裁中国境内城市
//  （实测Inner Mongolia 锡林郭勒 (115.9, 43.9) 就在任何合理的"蒙古排除框"内），
//  那样会把纠偏**关掉**于中国境内 —— 后果比境外多偏 200 m 严重得多。
//  故：保留业界标准实现 + 在 `knownOutOfChinaRegions` 里如实列出受影响地区，
//  由 `CoordinateTransformMode.disabled` 提供全局总闸（境外城市为主的用户可关）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

// MARK: - 纠偏模式（把 R1 的不确定性做成可切换开关）

/// 雷达瓦片的 GCJ-02 纠偏模式。
///
/// **默认值见 `CoordinateTransform.defaultMode`（附判断依据）。**
enum CoordinateTransformMode: String, CaseIterable, Sendable {

    /// 假定 **MapKit 已自动**对 overlay 施加 GCJ-02 偏移 → **不纠偏**。
    ///
    /// 若真机实测显示回波已与底图地物对齐（偏移 < 50 m），应选此项。
    case autoAssumeAppleApplies

    /// 假定 **MapKit 未对** overlay 施加偏移（只平移了底图）→ **纠偏**。
    ///
    /// 这是默认档：自定义瓦片 overlay 在中国区普遍需要自行纠偏，若该行为学说是
    /// 真的（见文件头"为什么默认这一档"），纠偏即正确。
    case autoAssumeNotApplied

    /// **完全关闭**纠偏（总闸 / 对照组）。
    ///
    /// 与 `autoAssumeAppleApplies` 的渲染结果相同，区别在于**语义**：
    /// 本档用于「境外城市为主、根本不需要纠偏」的用户，以及作为 A/B 对照组
    /// （确保纠偏代码路径可被单独关掉，而不是隐式生效）。
    case disabled

    /// 是否施加纠偏。
    ///
    /// - `.disabled` 与 `.autoAssumeAppleApplies` → false（都不纠偏）。
    /// - `.autoAssumeNotApplied` → true。
    var appliesCorrection: Bool {
        self == .autoAssumeNotApplied
    }

    /// 设置页 Picker 与诊断行的展示文案（**文案单一真源**，视图只负责展示）。
    var displayName: String {
        switch self {
        case .autoAssumeAppleApplies: return "不纠偏（假定 MapKit 已处理）"
        case .autoAssumeNotApplied:   return "纠偏（假定 MapKit 未处理）"
        case .disabled:               return "关闭纠偏（对照用）"
        }
    }

    /// 一句话说明（设置页脚注，解释这一档到底做了什么）。
    var explanation: String {
        switch self {
        case .autoAssumeAppleApplies:
            return "请求的瓦片索引不做任何偏移。适用于回波已与底图地物对齐的情况。"
        case .autoAssumeNotApplied:
            return "把请求的瓦片索引反向纠偏到 GCJ-02。中国大陆城市建议用这一档。"
        case .disabled:
            return "总闸：关闭整个纠偏代码路径，用于对照与境外城市为主的用户。"
        }
    }

    /// 解析（供偏好读回；非法值回落默认档）。
    /// - Parameter rawValue: 持久化字符串。
    static func from(rawValue: String?) -> CoordinateTransformMode {
        guard let rawValue, let mode = CoordinateTransformMode(rawValue: rawValue) else {
            return CoordinateTransform.defaultMode
        }
        return mode
    }
}

/// 坐标系换算（纯函数，无状态）。
enum CoordinateTransform {

    // MARK: - 默认档（判断依据写在这里，不要只写在提交信息里）

    /// **默认纠偏模式 = `.autoAssumeNotApplied`（纠偏）。**
    ///
    /// 判断依据（三条，按强度排序）：
    ///
    /// 1. **社区共识倾向于这一档**。若 MapKit 会在中国区自动平移自定义瓦片图层，
    ///    则「在中国用 `MKTileOverlay` 叠加 WGS84 瓦片」这件事根本不需要纠偏，
    ///    也不会成为已知问题。反过来，MapKit 自定义瓦片在中国区**普遍需要自行
    ///    GCJ-02 纠偏**这一现象，正是"Apple 不处理自定义图层"的间接证据。
    /// 2. **失效方向不对称**。猜错的代价：选"不纠偏"而实际需要纠偏 → 中国境内
    ///    整体偏 266–622 m（z7 下 ≈0.6 px，肉眼可见"雨在马路对面"）；
    ///    选"纠偏"而实际 Apple 已处理 → 境外城市多重 200–600 m，中国境内恰好抵消。
    ///    两边都有错，但**先修更常见的那个**。
    /// 3. **两种猜法都必须能被推翻**，所以真正的保障不是这一行默认值，而是
    ///    设置页开关 + 文件头写明的真机验收（< 50 m）。默认档只是"第一次打开
    ///    App 时误差最小"的选择，**不是**结论。
    ///
    /// ⚠️ **本默认值在真机验证前是未确认的。** 验证方法与验收标准见文件头。
    static let defaultMode: CoordinateTransformMode = .autoAssumeNotApplied

    // MARK: - 克拉玛沃斯基椭球常量

    /// 克拉玛沃斯基椭球长半轴（GCJ-02 标准实现取值）。
    static let semiMajorAxis: Double = 6_378_245.0

    /// 第一偏心率平方。
    static let eccentricitySquared: Double = 0.00669342162296594323

    // MARK: - 境内判定

    /// 粗略的"中国境内"判定（业界标准边界框）。
    ///
    /// ⚠️ 该边界框**包含**一批境外区域，详见文件头"已知局限"。
    /// 命中边界框即视为需要纠偏（宁可多纠，也勿漏纠中国境内）。
    ///
    /// - Parameters:
    ///   - longitude: 经度（东正）。
    ///   - latitude: 纬度（北正）。
    /// - Returns: 在边界框内 → true（需要纠偏）。
    static func isInsideChinaBox(longitude: Double, latitude: Double) -> Bool {
        (72.004...137.8347).contains(longitude) && (0.8293...55.8271).contains(latitude)
    }

    /// 会被边界框**误判为境内**从而被错误偏移的境外地区（实测确认）。
    ///
    /// 列出它不是为了修（修不了，见文件头），而是为了**如实告知**：
    /// 这些地区在纠偏开启时会多偏 130–480 m。
    static let knownOutOfChinaRegions: [String] = [
        "新加坡（约 167 m）", "吉隆坡（约 132 m）", "首尔（约 459 m）",
        "乌兰巴托（约 449 m）", "新德里（约 479 m）", "河内（约 440 m）"
    ]

    // MARK: - WGS84 → GCJ-02

    /// WGS84 → GCJ-02。
    ///
    /// 边界框外**原样返回**（不叠加偏移）——境外底图本就是 WGS84 系的源，
    /// 无条件加偏移反而制造错误。
    ///
    /// - Parameters:
    ///   - longitude: WGS84 经度（东正）。
    ///   - latitude: WGS84 纬度（北正）。
    /// - Returns: GCJ-02 的 (经度, 纬度)；框外返回入参原值。
    static func wgs84ToGCJ02(longitude: Double, latitude: Double) -> (longitude: Double, latitude: Double) {
        guard isInsideChinaBox(longitude: longitude, latitude: latitude) else {
            return (longitude, latitude)
        }
        let dLat = transformLatitude(x: longitude - 105.0, y: latitude - 35.0)
        let dLon = transformLongitude(x: longitude - 105.0, y: latitude - 35.0)
        let radLat = latitude / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - eccentricitySquared * magic * magic
        let sqrtMagic = sqrt(magic)
        let latOffset = (dLat * 180.0) / ((semiMajorAxis * (1 - eccentricitySquared)) / (magic * sqrtMagic) * .pi)
        let lonOffset = (dLon * 180.0) / (semiMajorAxis / sqrtMagic * cos(radLat) * .pi)
        return (longitude + lonOffset, latitude + latOffset)
    }

    /// 按模式施加纠偏（**模式闸门在此**，是全局唯一入口）。
    ///
    /// - Parameters:
    ///   - longitude: WGS84 经度。
    ///   - latitude: WGS84 纬度。
    ///   - mode: 纠偏模式。
    /// - Returns: 纠偏后的 (经度, 纬度)；未纠偏时返回入参原值。
    static func applyMode(_ mode: CoordinateTransformMode,
                          longitude: Double,
                          latitude: Double) -> (longitude: Double, latitude: Double) {
        guard mode.appliesCorrection else { return (longitude, latitude) }
        return wgs84ToGCJ02(longitude: longitude, latitude: latitude)
    }

    /// 偏移量（米，东 / 北）。用于诊断与单测；负号表示向西 / 向南。
    ///
    /// 换算按所在纬度做球面近似：经度方向乘 `cos(lat)`，纬度方向乘 110_574 m/度。
    static func offsetMeters(longitude: Double, latitude: Double) -> (east: Double, north: Double) {
        let g = wgs84ToGCJ02(longitude: longitude, latitude: latitude)
        let midLat = (latitude + g.latitude) / 2
        let east = (g.longitude - longitude) * 111_320.0 * cos(midLat * .pi / 180.0)
        let north = (g.latitude - latitude) * 110_574.0
        return (east: east, north: north)
    }

    // MARK: - 私有：偏移量分解（标准公式）

    /// 纬度方向偏移分解量（度）。
    static func transformLatitude(x: Double, y: Double) -> Double {
        var result = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        result += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        result += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return result
    }

    /// 经度方向偏移分解量（度）。
    static func transformLongitude(x: Double, y: Double) -> Double {
        var result = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        result += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        result += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return result
    }
}

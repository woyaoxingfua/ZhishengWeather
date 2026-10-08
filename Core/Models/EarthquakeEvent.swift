//
//  EarthquakeEvent.swift
//  Core / Models  [App + Widget 共用]
//
//  第九源 **USGS 地震**（`earthquake.usgs.gov`，FDSN Event Web Service，
//  **完全免 Key / 免注册**）的领域模型。
//
//  ═══════════════════════════════════════════════════════════════════════
//  实测基准：2026-10-08（主理人当次真实 curl 探针，逐字样本见
//  `ZhishengWeatherTests/UsgsEarthquakeTests.swift`）
//  官方文档：https://earthquake.usgs.gov/fdsnws/event/1/
//  ═══════════════════════════════════════════════════════════════════════
//
//  ── 🔴 坐标序：**经度在前**（GeoJSON 规范，与本仓台风源同款但成因不同）──
//  实测样本 `geometry.coordinates = [120.5395, -7.7761, 10]`：
//  · 下标 0 = **经度** 120.5395（印尼鲁滕东北，东经 120° 落**东半球**）；
//  · 下标 1 = **纬度** −7.7761（印尼鲁滕在南半球，**负纬度**）；
//  · 下标 2 = **深度** 10（km）。
//  这是 **GeoJSON 的标准约定**（RFC 7946 §3.1.1：位置是 `[经度, 纬度, 高度]`），
//  与本仓台风源「下标 4=经度 / 下标 5=纬度」是**两套独立来源的同一约定**。
//  → 写反的后果与台风源同款：**镜像到地球另一侧**，数值全部合法、
//   编译与运行都不报错，只有看图才发现。故除本注释外，
//   `UsgsEarthquakeMapper` 里还有**取值域兜底**（经度 ±180/ 纬度 ±90）。
//
//  ── 🔴 `mag` **可以是 null**（本模型字段可空的硬理由）─────────────────
//  实测样本里有 `mag = 5`，但 `properties.mag` 在 USGS 的契约里**允许缺测**
//  （例如只有定位而没有定级的记录）。故 `magnitude` 是 `Double?`，
//  分级函数对 nil 返回 nil，卡片显示「震级未提供」——
//  **绝不补0、绝不显示 M0.0**（那会把「没定级」说成「一场微震」）。
//
//  ── 单位（上游已归一，**本 App 不做任何换算**）────────────────────────
//  · 震级 `mag`：**矩震级 Mw 等标量**，**无量纲**（不同 `magType` 量表不同，
//    实测样本 `magType` 字段存在；本模型**不**把它当同一把尺子，见下条警告）；
//  · 深度 `coordinates[2]`：**千米（km）**，实测样本 10；
//  · 时刻 `properties.time`：**Unix 毫秒**（epoch ms），实测 1791434939943；
//  · 距离 `distanceKm`：**本 App 自己算**（Haversine，见 `GeoDistance`），
//    上游**不提供**任何距离字段。
//
//  ⚠️ **震级量表的诚实警告**：`magType` 实测有 `mb` / `md` / `ml` / `mww` 等多种。
//  不同量表测的是不同物理量（体波/短波/面波/矩震级），**数值不可直接横比**。
//  本模型**保留上游 `mag` 原值并如实展示**，但分级文案必须带上
//  「按上游给定震级」这一限定（见 `EarthquakeCard` 页脚）——
//  宣称「M5.0 一定比 M4.8 释放的能量更多」在不同量表间是**不成立**的。
//
//  ── 与快照的关系 ───────────────────────────────────────────────────────
//  地震要素**不在 `WeatherFieldKey` 域内**（与marine / flood 同处境），
//  故不进 `WeatherSnapshot` / 共享容器 → **Widget 载荷契约零改动**。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

// MARK: - 距离（Haversine）

/// 大圆距离计算（纯函数，**地球半径 6371 km**）。
///
/// ⚠️ 为什么半径取 6371 而不是 6372.8（IUGG 平均半径）或 6378.137（WGS84 赤道半径）：
/// 本仓只把它用于「**给用户一个量级正确的公里数**」，不用于任何测量学用途。
/// 三种半径的差异 < 0.3%，而实测端点半径参数 `maxradiuskm` 本身也是整数公里，
/// 用 6371（常用中值）足够，且**口径可被单测钉住**。
///
/// ── 数值稳定性（为什么要用 `asin(√a)` 而不是 `acos`）────────────────────
/// Haversine 的 `a` 是半正矢平方和，理论落在 `[0, 1]`；但浮点误差下
/// 极接近对跖点（`a ≈ 1`）时可能算出 `1 + 1e-16` → `asin` 定义域报错。
/// 故**先夹到 `[0, 1]`** 再取 `asin`（不夹则极端输入直接抛异常）。
enum GeoDistance {

    /// 地球平均半径（**km**）。口径见类型注释。
    static let earthRadiusKm = 6371.0

    /// 球面两点大圆距离（Haversine 公式，纯函数）。
    ///
    /// - Parameters:
    ///   - originLatitude: 起点纬度（**-90…90**）。
    ///   - originLongitude: 起点经度（**-180…180**）。
    ///   - targetLatitude: 终点纬度。
    ///   - targetLongitude: 终点经度。
    /// - Returns: 大圆距离（**km**）；任一坐标非有限值 → **nil**
    ///   （**如实缺测，绝不返回 0** —— 0 会被渲染成「震中就在你脚下」）。
    static func kilometers(originLatitude: Double,
                           originLongitude: Double,
                           targetLatitude: Double,
                           targetLongitude: Double) -> Double? {
        let inputs = [originLatitude, originLongitude, targetLatitude, targetLongitude]
        guard inputs.allSatisfy({ $0.isFinite }) else { return nil }

        let earthRadius = earthRadiusKm
        let phi1 = originLatitude * .pi / 180
        let phi2 = targetLatitude * .pi / 180
        let deltaPhi = (targetLatitude - originLatitude) * .pi / 180
        let deltaLambda = (targetLongitude - originLongitude) * .pi / 180

        // 半正矢平方和（a）。**不**命名成 `a` 之外的遮蔽名（P-32）。
        let halfChordSquared =
            sin(deltaPhi / 2) * sin(deltaPhi / 2)
            + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
        // 夹到 [0, 1]：浮点误差可能让它略大于 1（见类型注释「数值稳定性」）。
        let clamped = min(1, max(0, halfChordSquared))
        let centralAngle = 2 * asin(sqrt(clamped))
        return earthRadius * centralAngle
    }
}

// MARK: - 震级分级

/// 地震**震级**的三档分级（**本仓自定的展示口径，不是 USGS 官方等级**）。
///
/// ⚠️ **诚实警告（务必随阈值改动一起复核）**：
/// 1. **这不是 USGS 的官方分级**。USGS / 地震学界常用的是
///    「微震 / 有感地震 / 破坏性地震」这类**定性**描述，或按烈度（MMI/CDI）分级；
///    本枚举是**为了给用户一个量级直觉**而自定的三档，
///    阈值 3.0 / 4.5 与「有感地震 M3」「中强震 M4.5」这两个**常见说法**对齐，
///    **不是**任何官方标准的逐字复刻。
/// 2. **跨`magType` 不可比**（见文件头）：`mb` / `md` / `ml` / `mww` 测的不是同一个量，
///    所以本分级只是「按上游给定数值」的分级，**不得**被解读为严格的能量排序。
///
/// ⚠️ 档位**刻意不实现** `RawRepresentable` 的整数映射：`minor = 0` 极易被误当成
///「震级 0」，而 0 其实不在本量表的有效范围内（实测端点已用
/// `minmagnitude = 2.5` 过滤）。故用枚举 + 显式 `init?(magnitude:)`，
/// 形状与 `UVIndexLevel` 一致。
enum EarthquakeMagnitudeLevel: Equatable, Sendable, CaseIterable {

    /// `< 3.0`：弱（通常无感）。
    case minor

    /// `3.0…< 4.5`：中等（一般有感）。
    case moderate

    /// `>= 4.5`：强（中强震以上，可能造成破坏）。
    case strong

    /// 由震级数值分级。
    ///
    /// 边界（半开区间，逐一对应文件头阈值）：
    /// - `< 3.0` → `.minor`
    /// - `< 4.5` → `.moderate`
    /// - 其余 → `.strong`
    ///
    /// ⚠️ **负震级是合法的**（极微弱远震，实测 USGS 会返回 `mag < 0`）
    /// → **不得**用 `>= 0` 做守卫，那会把合法的远震误判成缺测。
    ///
    /// - Parameter magnitude: 上游给定震级（**无量纲**）。`nil` / 非有限值 →
    ///   **nil**，调用方须显示「震级未提供」，**不得**当 0 处理。
    init?(magnitude: Double?) {
        guard let magnitude, magnitude.isFinite else { return nil }
        if magnitude < 3.0 { self = .minor }
        else if magnitude < 4.5 { self = .moderate }
        else { self = .strong }
    }

    /// 档位中文名（UI 显示）。
    var displayName: String {
        switch self {
        case .minor: return "弱"
        case .moderate: return "中等"
        case .strong: return "强"
        }
    }

    /// 该档位的极简说明（一句事实，不夸大）。
    var detailText: String {
        switch self {
        case .minor: return "通常无感，个别情况下浅源小震可能有感"
        case .moderate: return "一般有感，震中附近可能有轻微损失"
        case .strong: return "震中附近可能造成明显破坏"
        }
    }
}

// MARK: - PAGER 警报等级

/// USGS **PAGER**（震后快速警报产品）的警报等级。
///
/// ⚠️ **做成 `RawRepresentable` 结构体而非 `enum`**，理由与 `TyphoonIntensity` 完全同款：
/// 上游可能出现本枚举未收录的新档位，建成 `enum` + `init(rawValue:)` 会让未知档位
/// `nil` 掉 → 警报等级被**静默吞掉**（信息丢失）。故**原样保留上游字符串**，
/// 由 `displayName` 决定显示成什么。
///
/// 实测样本 `alert = null`（**大多数事件没有 PAGER 产品** —— PAGER 只对
/// 可能有重大影响的地震触发）→ `nil` 是**常态**，不是缺测。
/// 另实测存在 `felt = null`，同样是「没人上报有感」的常态。
/// 🔴 **`RawRepresentable` + `Codable` 是必需的**（2026-10-08 CI 实测）：
/// 外层 `EarthquakeEvent` 声明了 `Codable`，而它含 `pagerAlert: EarthquakePagerAlert?`
/// → 本类型**必须**也 `Codable`，否则**整个外层的 Codable 合成失败**
/// （CI 报 `type 'EarthquakeEvent' does not conform to protocol 'Decodable'`）。
/// ⚠️ 因已有手写 `init(rawValue:)`（**不返回 nil**，故**不**用 `RawRepresentable`
/// 的默认 `Codable` 合成——那套合成依赖 `init?(rawValue:)`），
/// 这里**手写 `Codable`**，语义与构造器保持一致：**任何字符串都收**。
struct EarthquakePagerAlert: RawRepresentable, Codable, Equatable, Hashable, Sendable {

    /// 上游原值（逐字保留，如 `"yellow"`）。
    let rawValue: String

    /// 构造（实测档位以外的取值**照样收**，不返回 nil）。
    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 解码：**任何**字符串都收（不因未知档位失败 ——
    /// 警报等级被静默吞掉是信息丢失）。
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // ⚠️ `String.self` 而**不是** `String()` —— 后者是把「类型当函数」调用，
        // 报 `cannot convert value of type 'String' to expected argument type
        // 'String.Type'`（2026-10-08 CI 实测）。
        self.rawValue = try container.decode(String.self)
    }

    /// 编码：写回上游原值（往返无损）。
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // 实测四档（构造常量而非 enum case，便于将来上游加档而不改本文件）。
    static let green = EarthquakePagerAlert(rawValue: "green")
    static let yellow = EarthquakePagerAlert(rawValue: "yellow")
    static let orange = EarthquakePagerAlert(rawValue: "orange")
    static let red = EarthquakePagerAlert(rawValue: "red")

    /// 面向用户的中文名。
    ///
    /// ⚠️ 未知原值**如实显示上游原值并标注「未收录」**——
    /// 绝不猜一个中文名（猜错就是把警报等级讲错了）。
    var displayName: String {
        switch rawValue {
        case "green": return "绿色（PAGER 影响评估：轻微）"
        case "yellow": return "黄色（PAGER 影响评估：局部影响）"
        case "orange": return "橙色（PAGER 影响评估：较大影响）"
        case "red": return "红色（PAGER 影响评估：重大影响）"
        default: return "\(rawValue)（警报等级未收录）"
        }
    }

    /// 该等级是否属于「需要立即关注」（橙色及以上）。
    ///
    /// 供 UI 决定是否用**强强调色**渲染；判定只看**已收录**的三档，
    /// 未知等级一律**返回 false**（宁可弱化也不谎报「重大影响」）。
    var needsAttention: Bool {
        self == .orange || self == .red
    }
}

// MARK: - 单次地震事件

/// 一次 USGS 查询命中的**一条**地震事件（实测对应 GeoJSON 的一个 `feature`）。
///
/// ── 字段的「缺测」纪律 ────────────────────────────────────────────────
/// · `magnitude` / `depthKm` / `feltReportCount` / `pagerAlert` / `placeDescription`
///   / `detailURLString` **全部可空**，且**空就是空**，**绝不补默认值**：
///   实测 `felt` 与 `alert` 实测就是 `null`（常态，不是故障）；
/// · `latitude` / `longitude` / `time` / `distanceKm` **不可空**——
///   缺了它们这条地震**画不出来也定位不了**，mapper 直接**丢弃该条**
///   （一条坏数据只丢自己，不拖垮整批）。
struct EarthquakeEvent: Codable, Equatable, Identifiable, Sendable {

    /// USGS 事件 id（实测形如 `us6000kcd`，来自 GeoJSON 的 `id` 字段）。
    ///
    /// ⚠️ 上游 `id` 极罕见缺失；真缺失时mapper 用「时刻 + 坐标」构造**确定性兜底 id**
    /// （而不是丢弃这条**真实地震** —— 丢掉会让一次真实事件凭空消失，
    /// 那比id 不优雅严重得多）。
    let id: String

    /// 震级（**上游给定值，无量纲**；`nil` = 上游未给出，`magType` 亦可能不同量表）。
    let magnitude: Double?

    /// 震级量表代号（实测 `mb` / `md` / `ml` / `mww` 等；`nil` = 上游未给出）。
    ///
    /// ⚠️ 保留它是为了**如实告诉用户不同量表不可直接横比**（见文件头）。
    let magnitudeType: String?

    /// 震中描述文案（实测形如 `"92 km N of Ruteng, Indonesia"`，**英文**）。
    ///
    /// ⚠️ 上游**只给英文**，本App **不做机器翻译**（翻译会引入错地名）。
    /// 原样展示 + 卡内说明这是 USGS 原文。
    let placeDescription: String?

    /// 发生时刻（由实测 `properties.time` 的 Unix **毫秒**构造）。
    let time: Date

    /// 震中**经度**（WGS84，GeoJSON `coordinates[0]`）。
    let longitude: Double

    /// 震中**纬度**（WGS84，GeoJSON `coordinates[1]`）。
    let latitude: Double

    /// 震源深度（**km**，GeoJSON `coordinates[2]`；`nil` = 上游坐标数组不足 3 项）。
    let depthKm: Double?

    /// 有感（`felt`）上报数（`nil` = **没人上报有感**，这是**常态**，不是缺测）。
    ///
    /// ⚠️ 它是「**主动上报**的人数」，不是烈度，也不是「有感范围」。
    /// 上游另有 `cdi` / `mmi`（实测常为 null）字段才是仪器烈度 ——
    /// 本模型**不**映射它们（无消费者不建模，本仓既有纪律）。
    let feltReportCount: Int?

    /// PAGER 警报等级（`nil` = 上游无 PAGER 产品，**绝大多数事件如此**）。
    let pagerAlert: EarthquakePagerAlert?

    /// 是否为**海啸相关**事件（实测 `tsunami` = `0` / `1` 整数）。
    let hasTsunamiFlag: Bool

    /// USGS 官方详情页地址（实测 `properties.url`，**可点**；`nil` = 上游未给出）。
    let detailURLString: String?

    /// 距观测点（**用户所在城市**）的大圆距离（**km**；由 `GeoDistance` 计算）。
    ///
    /// ⚠️ 这是**本 App 计算值**，不是 USGS 提供的字段——
    /// 页脚必须如实说明「距离为本应用按 Haversine 公式计算」。
    let distanceKm: Double

    // MARK: 派生量

    /// 震级分级；`magnitude == nil` → **nil**（调用方须显示「震级未提供」）。
    var magnitudeLevel: EarthquakeMagnitudeLevel? {
        EarthquakeMagnitudeLevel(magnitude: magnitude)
    }

    /// 详情页地址（**可失败解析**：字面量非法 → nil，绝不崩）。
    var detailURL: URL? {
        guard let detailURLString, !detailURLString.isEmpty else { return nil }
        return URL(string: detailURLString)
    }
}

// MARK: - 一次查询的完整结果

/// 一次 USGS 附近查询的**完整**领域模型（实测对应顶层 `{type, metadata, features[]}`）。
struct EarthquakeFeed: Codable, Equatable, Sendable {

    /// 命中事件（**已按距观测点的距离升序**排好序，可直接渲染）。
    ///
    /// - 端点侧请求了 `orderby=time`（时间倒序），但那是「**最新优先**」；
    ///   本卡片的主题是「**附近有感地震**」，故 mapper **改按距离升序**重排 ——
    ///   「离你最近的那次」才是用户问的问题。见 `UsgsEarthquakeMapper` 注释。
    var events: [EarthquakeEvent]

    /// 无任何事件时的空结果（供 mapper 的「`features` 为空」回落路径使用）。
    static let empty = EarthquakeFeed(events: [])
}

extension EarthquakeFeed {

    /// **实质无数据**判定：`events` 为空 → true。
    ///
    /// ⚠️ **为什么不收敛到 `SnapshotCompleteness`**（marine / flood / tide 三者都在那里）：
    /// 那三者的判据是「**元素级**缺测」—— 序列里可能有点，但**全都没值**，
    /// 于是需要「有没有非 nil 的值」这一层。
    /// 而本源的 mapper 对每条事件采取**整条丢弃**策略：
    /// 缺经纬 / 缺时刻 / 坐标越界的 feature **根本不会进入** `events`，
    /// 且 `mag` / `felt` / `alert` 这些可空字段**不影响该条是否被保留**。
    /// →故 feed 只有「有完整事件」与「空」两种状态，
    /// **不存在**「有条目但全是缺测」这种中间态，
    /// 判据就是数组是否为空。**不硬塞进 `SnapshotCompleteness`** 是为了
    /// 不把一个语义不同的判据混进那个「单一真源」里（那是另一种漂移）。
    var isEffectivelyEmpty: Bool {
        events.isEmpty
    }
}
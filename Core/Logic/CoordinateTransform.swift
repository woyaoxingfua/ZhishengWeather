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
//  **Apple 是否会自动对 `MKTileOverlay` 施加 GCJ-02 偏移。**
//  两种可能：
//    A. MapKit 把整个地图空间（含自定义 overlay）一起平移 → 我们**不该**纠偏；
//    B. MapKit 只平移底图，自定义图层仍按原始索引取 → 我们**必须**纠偏。
//
//  ── 官方文档查证结论（2026-10-06，本轮新增；带链接）────────────────────
//  · `MKTileOverlay` 官方页（developer.apple.com/documentation/mapkit/
//    mktileoverlay）**通篇未提**坐标系 / 基准面 / GCJ-02 / 任何偏移处理。
//    只说"Each URL incorporates the x and y index of the map tile"，
//    以及"you can also subclass and override `url(forTilePath:)` … to map
//    between the requested tile and your custom indexing scheme"。
//  · `MKTileOverlayPath` 官方页同样只描述 x/y/z 三个整数索引，**无任何**
//    "这些索引是在哪个坐标系下算出的" 的说明。
//  · Apple 归档文档《Location and Maps Programming Guide》"Working With
//    Tiled Overlays" 一节**确实**写了投影要求（原文见 `tileIndexRequires3857`
//    的注释）：自定义瓦片要用 EPSG:3857 球面墨卡托。**但它同样没有说**
//    中国区是否会对索引施加 GCJ-02 偏移。
//  ⇒ **官方文档未定义 A / B 的区别。** 这不是"没查到"，是"文档层面不存在
//    这个承诺"。因此本问题**只能靠真机实测收敛**，任何声称"Apple 文档说了
//    应该纠偏"的说法都是误读。
//
//  ── Apple 官方论坛的可引用旁证（DTS 工程师答复，2026-09-25）────────────
//  developer.apple.com/forums/thread/797697 中 Apple DTS 工程师答复
//  （原文引用见 `appleDTSQuote`）：
//    "Maps in China must use the government-mandated coordinate system
//     which automatically applies obfuscation. So, yes, it is wrong.
//     But it's supposed to be wrong."
//  该答复确认了两件**相邻**事实：① 中国区底图确实施加法定加偏；
//  ② MapKit **不对开发者传入的 `CLLocationCoordinate2D` 做纠偏**
//  （"你传 WGS84，它就按WGS84 画，故而错"——故错是设计，不是 bug）。
//  ⚠️ 它**没有**提到 `MKTileOverlay`。但由 ② 可推出一个很强的旁证：
//  **MapKit 把"你给它的坐标"原样当作已加偏坐标使用**——若它连annotation
//  都不纠偏，就更没有理由单独去纠偏一个自定义瓦片图层（瓦片索引比annotation
//  更"原始"，MapKit无从知道你用的是WGS84 还是 GCJ-02）。
//  ⇒ 这条**倾向** B（我们必须自己纠偏），但它是**推理**，不是对tile overlay
//    的直接断言。**不足以定案，仍须真机验证。**
//
//  ── 真机验收方法与标准 ─────────────────────────────────────────────────
//  · 方法：北京天安门广场轮廓 / 上海黄浦江北岸线，比对雷达回波边缘与底图已知地物。
//  · 验收：偏移 **< 50 m**。
//  · 收敛：满足 → 保留 `.autoAssumeNotApplied`；不满足 → 切 `.autoAssumeAppleApplies`。
//  · **禁止**同时纠偏与不纠偏（会双重偏移，更糟）。
//
//  ── 🔴🔴 本轮新发现：纠偏在 z4–z7 上是**数学上的恒等变换**（比A/B 更要紧）──
//  **详见 `tileIndexCorrectionIsInertAtSupportedZooms` 的推导。** 简版：
//  `correctedTileCoordinates` 是把「瓦片中心点纠偏后再反算索引」，而瓦片中心点
//  距最近索引边界恒为**半格**。z7 的半格≈ 156 km，而 GCJ-02 最大偏移仅 **663 m**
//  →余量 **236 倍**。故纠偏后的索引**必然仍落在同一格内**，三态开关在
//  z4–z7（RainViewer 唯一可用区间，见 `RadarTileZoomRange`）**产生完全相同的
//  URL**，开关切了等于没切。
//  ⇒推论：**R1 的真机验收不能靠"切开关看回波是否对齐"来做** —— 那样三个档位
//  渲染结果逐像素相同，必然"看不出区别"，会得出"开关无效"的错误结论。
//  真机要验的是「**不纠偏时**回波与底图差多少米」，而这个差值由
//  **底图本身**决定，与开关无关（见 `radarAlignmentProbe`）。
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
    /// ⚠️⚠️ **2026-10-06 更新：本默认值的"依据 1"已被削弱，依据 2/3 已被推翻。**
    /// 保留该默认值**不是因为它已被证实**，而是因为**它当前无害** ——
    /// 详见下面「为什么保留一个无效的默认值」。
    ///
    /// 判断依据（三条，**并标注各自的当前有效性**）：
    ///
    /// 1. ~~**社区共识倾向于这一档**。~~ **【已削弱】**
    ///    原论证是「若MapKit 自动纠偏，则在中国叠加 WGS84 瓦片根本不需要纠偏，
    ///    也不会成为已知问题；反之则是 Apple 不处理自定义图层的间接证据」。
    ///    本轮查证发现：Apple DTS 工程师明确说 MapKit **对annotation 坐标
    ///    也不纠偏**（`Evidence.appleDTSQuote`），这**加强**而非削弱了本条。
    ///    但它仍**不是**对 tile overlay 的直接断言 → 只能算旁证。
    /// 2. ~~**失效方向不对称**。~~ **【已推翻】**
    ///    原论证是「猜错代价：选不纠偏而实际需要纠偏 → 偏 266–622 m；
    ///    选纠偏而实际 Apple 已处理 → 境外多重 200–600 m」。
    ///    **这个不对称性在当前实现下并不存在**：纠偏在 z4–z7 上是恒等变换
    ///    （见 `correctionIsInertAcrossRadarZooms`），三档产生**完全相同的
    ///    瓦片 URL**，渲染结果逐像素一致 → **无论选哪档，偏移都一样**。
    ///    「先修更常见的那个」这套推理的前提（两档渲染不同）不成立。
    /// 3. **真正的保障不是这一行默认值，而是能被证伪的判据。**
    ///    本轮据此新增了 `correctionIsInertAcrossRadarZooms`（可单测）
    ///    与 `OffsetProbe`（真机读数），把"到底有没有偏移"变成可测量的问题。
    ///
    /// ── 为什么保留一个「无效」的默认值 ──────────────────────────────────
    /// 因为在 z4–z7 上它**确实无效**：切档不改变任何瓦片请求。
    /// 换默认值既无收益（渲染不变），又会在真机验收时**制造假信号** ——
    /// 用户切档后看到"完全没变化"，会误以为"纠偏没用/开关坏了"，
    /// 而实际上**三个档位本来就该一模一样**。
    /// ⇒ 保留现状 +把惰性写进代码与文档，是当前**最不容易误导**的选择。
    ///
    /// ⚠️ **若将来 RainViewer 支持 z≥15**（半格 ≤611 m < 最大偏移 663 m），
    /// 纠偏将**不再是恒等**，届时本默认值才真正开始产生区分度，
    /// 必须**重新**依据真机实测收敛，且 `correctedTileCoordinates`
    /// 需改为像素级平移而非改索引（改索引粒度太粗，见该函数注释）。
    ///
    /// ⚠️ **本默认值在真机验证前是未确认的。**
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

    /// 偏移量（米，东 / 北）。用于诊断与单测；负号表示向左 / 向南。
    ///
    /// 换算按所在纬度做球面近似：经度方向乘 `cos(lat)`，纬度方向乘 110_574 m/度。
    static func offsetMeters(longitude: Double, latitude: Double) -> (east: Double, north: Double) {
        let g = wgs84ToGCJ02(longitude: longitude, latitude: latitude)
        let midLat = (latitude + g.latitude) / 2
        let east = (g.longitude - longitude) * 111_320.0 * cos(midLat * .pi / 180.0)
        let north = (g.latitude - latitude) * 110_574.0
        return (east: east, north: north)
    }

    // MARK: - R1 证据：官方文档查证记录（**单一真源，报告与代码必须一致**）

    /// Apple 官方文档对「tile overlay 是否被施加 GCJ-02 偏移」的表述。
    ///
    /// - `mktileOverlayDocURL`: `MKTileOverlay` 官方文档页。
    /// - `tilePathDocURL`: `MKTileOverlayPath` 官方文档页。
    /// - `archivedGuideURL`: Apple 归档《Location and Maps Programming Guide》。
    /// - `appleDTSQuote`: Apple 开发者论坛 DTS 工程师答复原文（**逐字引用，未改写**）。
    ///
    /// ⚠️ **这些常量是「证据」，不是「结论」。** 它们记录的是**查到了什么**，
    /// 用途有两个：① 报告与代码引用同一份链接，杜绝各说各话；
    /// ② 将来若Apple 更新文档/发布新说明，只改这里一处。
    enum Evidence {

        /// `MKTileOverlay` 官方文档页。
        static let mktileOverlayDocURL =
            "https://developer.apple.com/documentation/mapkit/mktileoverlay"

        /// `MKTileOverlayPath` 官方文档页。
        static let tilePathDocURL =
            "https://developer.apple.com/documentation/mapkit/mktileoverlaypath"

        /// Apple 归档《Location and Maps Programming Guide · Annotating Maps》。
        static let archivedGuideURL =
            "https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/LocationAwarenessPG/AnnotatingMaps/AnnotatingMaps.html"

        /// Apple 开发者论坛 DTS 工程师答复（讨论中国区坐标加偏）。
        static let appleForumURL =
            "https://developer.apple.com/forums/thread/797697"

        /// DTS 工程师答复中与「中国区加偏」直接相关的**逐字**片段。
        ///
        /// 原文（英文，逐字引用，未翻译改写）：
        /// "Maps in China must use the government-mandated coordinate system
        ///  which automatically applies obfuscation. So, yes, it is wrong.
        ///  But it's supposed to be wrong."
        static let appleDTSQuote =
            "Maps in China must use the government-mandated coordinate system which automatically applies obfuscation. So, yes, it is wrong. But it's supposed to be wrong."

        /// 同一答复中关于内部坐标表示的**逐字**片段。
        ///
        /// 原文："Coordinates in MapKit are just basic latitude and longitude.
        /// Internally, they are represented as map points in the web mercator
        /// system (EPSG:3857), not WGS84."
        static let appleDTSInternalRepresentationQuote =
            "Coordinates in MapKit are just basic latitude and longitude. Internally, they are represented as map points in the web mercator system (EPSG:3857), not WGS84."

        /// Apple 归档指南关于自定义瓦片投影要求的**逐字**片段。
        ///
        /// 原文："To create tiles that match the curvature of the map, use the
        /// EPSG:3857 spherical Mercator projection coordinate system."
        static let archivedGuideProjectionQuote =
            "To create tiles that match the curvature of the map, use the EPSG:3857 spherical Mercator projection coordinate system."

        /// **官方文档是否定义了 tile overlay 的GCJ-02 处理？**
        ///
        /// = `false`。查证结论：官方文档**从未提及** GCJ-02、基准面转换，
        /// 也从未说明中国区是否会对自定义瓦片索引施加偏移。
        /// 故 A / B 两种行为均**未被官方文档排除或确认**。
        static let officialDocsDefineOverlayOffset: Bool = false

        /// DTS 答复是否**直接**谈到了 `MKTileOverlay`？= `false`。
        ///
        /// ⚠️ 这一条存在的意义：防止后来者把「MapKit 不纠偏 annotation」
        /// 当成「MapKit 会纠偏 tile overlay」或反之——**原文没提 tile overlay**。
        static let appleDTSMentionsTileOverlay: Bool = false
    }

    // MARK: - R1 实测探针：把「偏移量」变成可读数值，而不是靠人眼比两个位置

    /// 单个参考点上的纠偏探针结果。
    ///
    /// 字段全部是**可直接显示/记录**的数值或短句，设计目标：
    /// 真机验收时用户只需要**读一个数字**，而不是人眼比对两处地物。
    struct OffsetProbe: Equatable, Sendable {

        /// 参考点名称（如 "北京"）。
        let name: String

        /// 该点是否落在「需要纠偏」的判定内（复用 `isInsideChinaBox`）。
        let needsCorrection: Bool

        /// 东向偏移（米，正 = 向东）。
        let eastMeters: Double

        /// 北向偏移（米，正 = 向北）。
        let northMeters: Double

        /// 合成偏移（米）。
        var distanceMeters: Double { (eastMeters * eastMeters + northMeters * northMeters).squareRoot() }

        /// 该偏移折合多少**屏幕像素**（给定 zoom 与瓦片边长）。
        ///
        /// ⚠️ 这是「偏移到底有多大」的**唯一直观量**：R1 的 50 m 门槛、
        /// 「肉眼能不能看出来」，本质都是像素当量问题。
        ///
        /// - Parameters:
        ///   - zoom: Web Mercator 层级。
        ///   - tileEdge: 瓦片边长（像素），本项目为 256。
        /// - Returns: 像素当量；参数非法时返回 0。
        func pixels(atZoom zoom: Int, tileEdge: Double) -> Double {
            let mpp = CoordinateTransform.metersPerPixel(atZoom: zoom, tileEdge: tileEdge)
            guard mpp > 0 else { return 0 }
            return distanceMeters / mpp
        }

        /// 单行摘要（可直接进诊断面板 / 日志）。
        var summary: String {
            let tail = needsCorrection ? "" : "（境外·不加偏移）"
            return name + tail
                + " 偏移 " + CoordinateTransform.rounded(distanceMeters) + " m"
                + "（东 " + CoordinateTransform.rounded(eastMeters)
                + " / 北 " + CoordinateTransform.rounded(northMeters) + "）"
        }
    }

    /// 一个 Web Mercator 瓦片在指定层级的**边长（米，赤道处）**。
    ///
    /// 等价于 `40075016.686 / 2^zoom` —— EPSG:3857 的定义值
    /// （赤道周长 40075.017 km / 2^zoom）。
    ///
    /// ⚠️ 这是**解析证明 R1 恒等性的关键量**：瓦片中心点距最近索引边界
    /// 恒为「半格」，而这个半格远大于 GCJ 偏移量。
    ///
    /// - Parameter zoom: Web Mercator 层级（负值按 0 处理）。
    /// - Returns: 瓦片边长（米）。
    static func tileEdgeMeters(atZoom zoom: Int) -> Double {
        // ⚠️ `<<` 只对整数有定义，`2.0 << 7` **编译不过**（曾踩）；
        // 故先用 Int 位运算再转 Double。负 zoom 按 0 处理。
        let shifted: Int = 1 << (zoom < 0 ? 0 : zoom)
        guard shifted > 0 else { return 0 }
        return 40_075_016.686 / Double(shifted)
    }

    /// 指定层级 + 瓦片边长下的**米/像素**（赤道处；未乘纬度余弦）。
    ///
    /// ⚠️ 真实米/像素 = 本值 × cos(纬度)，故本值是**下界**，
    /// 适合做「最多能有多少像素」的上界估计。
    ///
    /// - Parameters:
    ///   - zoom: Web Mercator 层级。
    ///   - tileEdge: 瓦片边长（像素），本项目为 256。
    /// - Returns: 米/像素；`tileEdge <= 0` 或层级为负时返回 0。
    static func metersPerPixel(atZoom zoom: Int, tileEdge: Double) -> Double {
        guard tileEdge > 0, zoom >= 0 else { return 0 }
        return tileEdgeMeters(atZoom: zoom) / tileEdge
    }

    /// 诊断文案用的整数取整（避免在Core 里散落 `String(format:)`）。
    ///
    /// - Parameter value: 原值。
    /// - Returns: 四舍五入后的整数字符串。
    static func rounded(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    /// 参考点表（真机验收用；**城市中心 + 若干参考点**）。
    ///
    /// 选点理由：天安门（广场轮廓清晰）、黄浦江北岸（岸线笔直）都是
    /// 底图上**边界锐利**、肉眼可判的地物 —— 偏移最容易看出来。
    static let probeReferencePoints: [(name: String, longitude: Double, latitude: Double)] = [
        ("北京天安门", 116.3970, 39.9090),
        ("上海黄浦江", 121.4900, 31.2400),
        ("广州", 113.2640, 23.1290),
        ("成都", 104.0660, 30.5720),
        ("乌鲁木齐", 87.6170, 43.7930)
    ]

    /// 计算某点的偏移探针结果。
    ///
    /// - Parameters:
    ///   - longitude: WGS84 经度。
    ///   - latitude: WGS84 纬度。
    ///   - name: 参考点名。
    /// - Returns: 探针结果（纯函数，可单测）。
    static func offsetProbe(longitude: Double, latitude: Double,
                            name: String = "") -> OffsetProbe {
        let m = offsetMeters(longitude: longitude, latitude: latitude)
        return OffsetProbe(name: name,
                           needsCorrection: isInsideChinaBox(longitude: longitude, latitude: latitude),
                           eastMeters: m.east,
                           northMeters: m.north)
    }

    /// 一次算出全部参考点的探针摘要（多行，供诊断落盘）。
    ///
    /// - Parameters:
    ///   - tileEdge: 瓦片边长（像素）；用于折算像素当量。
    ///   - zoom: 折算像素当量所用的层级（默认取雷达可用上限）。
    /// - Returns: 每行一条摘要。
    static func probeSummaries(tileEdge: Int,
                               zoom: Int = RadarTileZoomRange.maximum) -> [String] {
        probeReferencePoints.map { point in
            let probe = offsetProbe(longitude: point.longitude,
                                    latitude: point.latitude,
                                    name: point.name)
            let px = probe.pixels(atZoom: zoom, tileEdge: Double(tileEdge))
            let pxText = String(Int((px * 100).rounded()))   // 定点两位小数，避开 format
            return probe.summary + " ≈ " + pxText + " px@z" + String(zoom)
        }
    }

    // MARK: - R1 解析判据：纠偏在 z4–z7 上是**恒等变换**

    /// 瓦片中心到最近索引边界的距离（米，赤道处）。
    ///
    /// 瓦片 `x` 覆盖归一化区间 `[x/n, (x+1)/n)`，其中心恰为 `(x+0.5)/n`
    /// → 距左右边界**恒为半格**。要把索引挪到相邻格，偏移量必须**超过半格**。
    ///
    /// - Parameter zoom: Web Mercator 层级。
    /// - Returns: 半格边长（米）。
    static func halfTileMarginMeters(atZoom zoom: Int) -> Double {
        tileEdgeMeters(atZoom: zoom) / 2.0
    }

    /// **纠偏能否改变瓦片索引**（R1 的解析判据，纯函数、可单测）。
    ///
    /// `correctedTileCoordinates` 的做法是「取瓦片中心 → 纠偏 → 反算索引」。
    /// 由于中心距边界恒为半格（`halfTileMarginMeters`），只要
    /// **偏移量 < 半格**，纠偏后的点必然仍落在同一格内 → 索引**不变**。
    ///
    /// - Parameters:
    ///   - zoom: 目标层级。
    ///   - offsetMeters: 该点的合成偏移（米）。
    /// - Returns: `true` = 纠偏**可能**改变索引；`false` = **必然不变**（恒等）。
    static func canCorrectionChangeTileIndex(zoom: Int, offsetMeters offset: Double) -> Bool {
        let margin = halfTileMarginMeters(atZoom: zoom)
        guard margin > 0 else { return false }
        return offset >= margin
    }

    /// 雷达可用层级区间内，纠偏是否**处处**为恒等变换。
    ///
    /// ⚠️ **这是本轮最重要的结论，R1 真机验收必须知道。**
    ///
    /// - Parameter maximumOffsetMeters: 境内观测到的最大合成偏移（米）。
    /// - Returns: `true` = 在 `RadarTileZoomRange` 全区间内纠偏都不改变索引。
    static func correctionIsInertAcrossRadarZooms(maximumOffsetMeters: Double) -> Bool {
        (RadarTileZoomRange.minimum...RadarTileZoomRange.maximum).allSatisfy { zoom in
            !canCorrectionChangeTileIndex(zoom: zoom, offsetMeters: maximumOffsetMeters)
        }
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

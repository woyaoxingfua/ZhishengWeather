//
//  RadarMapCard.swift
//  ZhishengWeather（主 App target）
//
//  降水雷达地图卡：MKMapView + 雷达回波覆盖层 + past 帧回放时间轴。
//
//  ── 为什么用 UIViewRepresentable 而非 SwiftUI `Map` ──────────────────────
//  `MKTileOverlay` 是 `MKOverlay` 子类，必须经 `MKMapView.addOverlay(_:level:)`
//  注册；SwiftUI `Map` + `MapOverlay` 承载不了它。故走 `UIViewRepresentable`。
//  （MapKit 只在此文件出现，Core/ 保持零 MapKit 依赖。）
//
//  ── 三条实测硬约束（详见 Core/Networking/RainViewerService.swift 文件头）──
//  1. 瓦片 URL 的 `{size}` 必须在 `{z}` **之前**；写反了服务端**不报错**，
//     而是静默返回 1370 B 灰阶占位图 → 用户看到 "Zoom Level Not Supported"。
//  2. zoom 必须钳制到 **4–7**；z8 起恒为占位图。
//  3. `nowcast` **实测恒空** → 时间轴只渲染 past 帧；帧数 0 时**禁用 scrubber**。
//
//  ── 🔴 GCJ-02 纠偏：开关在设置页，不在本卡 ──────────────────────────────
//  MapKit 是否自动对 `MKTileOverlay` 施加 GCJ-02 偏移**未经真机确认**（R1）。
//  故纠偏模式由 `RadarCoordinateModeStore`（App 本地偏好）驱动，
//  **默认档未经真机验证**，见 `CoordinateTransform.defaultMode` 的判断依据。
//
//  ── 🆕 本轮：相机缩放上限（`RadarZoomCap.swift`）────────────────────────
//  RainViewer 只有 z4–z7 的瓦片，而 Apple 文档明写 `maximumZ` 之外
//  **MapKit 根本不去取瓦片**（`MKTileOverlay.maximumZ`："The map doesn't
//  attempt to load tiles for a zoom level greater than…"）→ 一旦 MapKit
//  开始索取 z8，就**只剩底图**。故把相机上限卡在"刚好不让它开口要 z8"
//  的位置：用户既能用到**真实的 z7 瓦片**，又绝不会空白。
//  ⚠️ **绝不**去请求/伪造 z8+ 的瓦片（RainViewer 没有那个数据）。
//
//  ── 🆕 本轮：像素级平移机制（`ShiftedTileOverlayRenderer`）────────────────
//  昨天证明「改瓦片索引」在 z4–z7 是恒等变换，做不到纠偏。本轮改用
//  **绘制期平移**：`MKOverlayRenderer.draw(_:zoomScale:in:)` 是 Apple 文档
//  明写的子类钩子，在其中`context.translateBy` 即可整体平移瓦片内容。
//  ⚠️ **但实测平移量不足 1 设备像素**（z7 @2x 最大 0.931 pt，境内 552 瓦片
//  0个达到 1.0 px）→ **平了也看不见**。故本卡上的平移档默认**关闭**，
//  且UI 必须如实显示「平移量 = N px · 纠偏方向未验证」，**不得**写成"已纠偏"。
//
//  ── 许可（硬要求，非可选）─────────────────────────────────────────────
//  RainViewer 要求显示署名：本卡**左下角**固定显示
//  "Weather data by RainViewer" + 指向 rainviewer.com 的链接。
//

import SwiftUI
import MapKit
// `CLLocationCoordinate2D` 显式引入：MapKit 虽会连带 CoreLocation，
// 但不保证 Swift 侧可见（模块 re-export 不是语言保证）。显式引入零成本。
import CoreLocation
// ⚠️ `UIScreen` 属于 **UIKit**，不由 SwiftUI / MapKit 保证 re-export
// （同款判断见 `SettingsView.pixelShiftReading` 的注释）→ 必须显式引入，
// 否则 `UIScreen.main.scale` 报 "cannot find 'UIScreen' in scope"。
// 本类型整体已标 `@MainActor`（见下），故 `UIScreen.main` 的隔离也满足。
import UIKit

// MARK: - 纠偏模式偏好（App 本地，不进共享容器）

/// 雷达纠偏模式偏好读写（**App 本地 UserDefaults**）。
///
/// 为什么不进共享容器：小组件**不显示雷达地图**（一期不进小组件，见 R4），
/// 扩展进程无需知道这个值。
enum RadarCoordinateModeStore {

    /// 偏好键。
    static let key = "zs.radar.coordinateMode"

    /// 读取当前模式（非法值回落默认档）。
    static func current() -> CoordinateTransformMode {
        CoordinateTransformMode.from(rawValue: UserDefaults.standard.string(forKey: key))
    }

    /// 写入模式。
    static func set(_ mode: CoordinateTransformMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: key)
    }
}

// MARK: - 回波覆盖层

/// RainViewer 雷达回波覆盖层。
///
/// ⚠️ **不用 `urlTemplate`**：Apple 只文档化 `{z}/{x}/{y}/{scale}` 四个占位符，
/// **没有 `{size}`**，而 `{size}` 正是 RainViewer 要求的路径段。交给 MapKit
/// 拼 URL 拼不出来，故在 `loadTile(at:result:)` 里完全自控 —— 顺带获得
/// 缓存、限流、占位图拒收三项能力。
final class RadarTileOverlay: MKTileOverlay {

    /// 瓦片宿主（取自元数据 `host` 字段）。
    private let host: String
    /// 帧路径（形如 `/v2/radar/cc4e98e720b0`）。
    private let framePath: String
    /// 色表 ID。
    private let colorScheme: Int
    /// 纠偏模式（R1 开关）。
    private let mode: CoordinateTransformMode
    /// 缓存（actor）。
    private let cache: RadarTileCache

    /// 构造。
    init(host: String,
         framePath: String,
         colorScheme: Int = RadarTileURLBuilder.defaultColorScheme,
         mode: CoordinateTransformMode,
         cache: RadarTileCache) {
        self.host = host.hasSuffix("/") ? String(host.dropLast()) : host
        self.framePath = framePath
        self.colorScheme = colorScheme
        self.mode = mode
        self.cache = cache
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: CGFloat(RadarTileURLBuilder.tileEdge),
                          height: CGFloat(RadarTileURLBuilder.tileEdge))
        // 标准 EPSG:3857 XYZ（左上原点），**不是** TMS —— 翻转会把回波镜像错位。
        isGeometryFlipped = false
        minimumZ = RadarTileZoomRange.minimum
        maximumZ = RadarTileZoomRange.maximum
        // 盖在 Apple 底图之上，不替换底图内容。
        canReplaceMapContent = false
        //
        // ⚠️ **此处曾有一行 `loadingPolicy = .loadBeforeDisplay`（已删）**
        //
        // 那是个**不存在的 API**：2026-10-07 逐页核对 Apple 官方文档确认 ——
        //  · `MKTileOverlay` 的全部属性：tileSize / isGeometryFlipped /
        //    minimumZ / maximumZ / canReplaceMapContent / urlTemplate
        //    —— **无 loadingPolicy**
        //  · `MKTileOverlayRenderer` 只有 `init(tileOverlay:)` 与 `reloadData()`
        //    —— **无 loadingPolicy**
        //  · `MKMapView` 属性里也**无 loadingPolicy**
        //
        // CI 报 `cannot find 'loadingPolicy' in scope` 就是这么来的。
        // 教训：这不是「设错了对象」，而是**属性根本不存在**——
        // 它是我们照着「应该有这个开关」的直觉编出来的。
        //
        // 瓦片加载时机因此**保持 MapKit 默认行为**，不做任何自定义。
        // 若将来确需控制，唯一可靠的入口是自控的 `loadTile(at:result:)`
        // 里自己做预取/节流（本次不做：无实测依据表明默认行为有问题）。
    }

    /// 纠偏后的瓦片请求坐标。
    ///
    /// 纠偏的落点：把 MapKit 要的瓦片中心点（`MKTileOverlayPath` → 经纬度）
    /// 正向纠偏到 GCJ-02，再换算回瓦片索引 → 即"反向纠偏请求索引"。
    ///
    /// ── 🔴 本轮新增结论：该实现在 z4–z7 上是**恒等变换** ──────────────
    /// 推导：瓦片 `x` 覆盖 `[x/n,(x+1)/n)`，中心 `(x+0.5)/n` 距最近边界
    /// **恒为半格**；z7 的半格 ≈ 156 km，而 GCJ-02 最大偏移仅 **663 m**
    /// → 余量 **236 倍**，纠偏后的点必然仍落在同一格内，索引**不变**。
    /// 实测：对z4–z9 全中国境内瓦片穷举，索引改变数 **0**。
    /// ⇒ 三态开关在RainViewer 可用区间（z4–z7）**产生完全相同的 URL**，
    /// 渲染结果逐像素相同。**「切档看回波是否对齐」这个 R1 验收方法无效。**
    ///
    /// ⚠️ 保留本实现的原因（不是"以为它在起作用"）：
    /// ① 它是**正确的**纠偏方向（若未来能在更高 zoom 或像素级纠偏，
    ///    直接可用）；② 删除会改变现有渲染行为，而 R1 尚未定案；
    /// ③ 它同时充当"纠偏逻辑是否被正确调用"的活文档。
    /// 若将来要真正纠偏，**正确的做法不是改索引**（粒度太粗），
    /// 而是把瓦片图像按偏移量做亚像素平移。
    ///
    /// - Parameter path: MapKit 给的瓦片路径。
    /// - Returns: 实际应请求的 (x, y, z)。
    func correctedTileCoordinates(for path: MKTileOverlayPath) -> (x: Int, y: Int, z: Int) {
        // 先夹紧 zoom：MapKit 理论上遵守 maximumZ，但**防御性夹紧**可确保
        // z8 占位图在任何情况下都不会被请求（R5）。
        let z = RadarTileZoomRange.clamp(path.z)
        guard mode.appliesCorrection else {
            return (x: path.x, y: path.y, z: z)
        }
        let span = Double(1 << z)
        // 瓦片中心经纬度（WGS84）。
        let lon = (Double(path.x) + 0.5) / span * 360.0 - 180.0
        let latRad = atan(sinh(.pi * (1 - 2 * (Double(path.y) + 0.5) / span)))
        let lat = latRad * 180.0 / .pi
        // 正向纠偏到 GCJ-02 后反算索引 —— 这就是"把偏移纠到瓦片空间"。
        let g = CoordinateTransform.applyMode(mode, longitude: lon, latitude: lat)
        let newX = Int(floor((g.longitude + 180.0) / 360.0 * span))
        let newY = Int(floor((1.0 - asinh(tan(g.latitude * .pi / 180.0)) / .pi) / 2.0 * span))
        return (x: min(max(newX, 0), Int(span) - 1),
                y: min(max(newY, 0), Int(span) - 1),
                z: z)
    }

    /// 取一张瓦片（MapKit 回调）。
    ///
    /// 三道防线：① zoom 钳制；② 缓存（含 TTL）；③ 占位图拒收（在 cache 内）。
    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, (any Error)?) -> Void) {
        let coords = correctedTileCoordinates(for: path)
        let key = RadarTileURLBuilder.cacheKey(framePath: framePath,
                                               zoom: coords.z,
                                               x: coords.x,
                                               y: coords.y,
                                               colorScheme: colorScheme)
        guard let url = RadarTileURLBuilder.url(host: host,
                                                framePath: framePath,
                                                zoom: coords.z,
                                                x: coords.x,
                                                y: coords.y,
                                                colorScheme: colorScheme) else {
            result(nil, URLError(.badURL))
            return
        }
        Task {
            let outcome = await cache.load(url: url, key: key, now: Date())
            switch outcome {
            case .success(let data):
                result(data, nil)
            case .failure:
                // 失败（含占位图）→ 传 nil：MapKit 画透明瓦片，
                // **绝不让灰图上屏**。
                result(nil, URLError(.cannotDecodeContentData))
            }
        }
    }
}

// MARK: - 像素级平移偏好（App 本地）

/// 雷达**像素级平移**档位（**独立于 `CoordinateTransformMode`**）。
///
/// ── 为什么必须与 `CoordinateTransformMode` 分开 ──────────────────────────
/// 三态开关控制的是**「请求哪个瓦片索引」**，本enum 控制的是**「绘制时往哪挪」**。
/// 两者物理层完全不同（前者改 URL，后者改 `CGContext`），混在一起会让
/// "切档= 改请求" 的旧心智模型继续误导人——而昨天已证明那个模型在 z4–z7
/// 上根本产生不了差别。
///
/// ── 为什么默认 `.off` ────────────────────────────────────────────────────
/// 平移量实测不足 1 设备像素（见 `CoordinateTransform.PixelShiftProbe`），
/// **用户看不出差别**；而**方向仍未定**（R1，真机才能定）。在这种状态下
/// 默认开启一个方向未知的亚像素平移，是**制造假信号**：用户会以为"纠偏生效了"。
/// 故默认关闭，让机制可被显式打开做 A/B，但绝不冒充已纠偏。
enum RadarPixelShiftMode: String, CaseIterable, Sendable {

    /// 不平移（**默认**）。
    case off

    /// 按「正向纠偏量」平移（东→西、北→南）。
    ///
    /// ⚠️ 方向来自「假定 MapKit 未对 overlay 施加偏移」这一**未验证**假设。
    case shiftAlongCorrection

    /// 按「反向」平移（东→东、北→北）。
    ///
    /// 与 `shiftAlongCorrection` 互为对照，用于真机 A/B。
    case shiftOppositeCorrection

    /// 是否实际施加平移。
    var appliesShift: Bool { self != .off }

    /// 设置页/ 诊断文案。
    var displayName: String {
        switch self {
        case .off:                return "不平移（默认）"
        case .shiftAlongCorrection:   return "平移· 沿纠偏方向（方向未验证）"
        case .shiftOppositeCorrection: return "平移 · 反纠偏方向（对照）"
        }
    }

    /// 该档位的方向符号：`+1` = 沿纠偏方向，`-1` = 反向，`0` = 不平移。
    var directionSign: Double {
        switch self {
        case .off:                     return 0
        case .shiftAlongCorrection:    return 1
        case .shiftOppositeCorrection:  return -1
        }
    }

    /// 解析（非法值回落 `.off` —— **安全的**默认）。
    static func from(rawValue: String?) -> RadarPixelShiftMode {
        guard let rawValue, let mode = RadarPixelShiftMode(rawValue: rawValue) else {
            return .off
        }
        return mode
    }
}

/// 像素级平移偏好读写（**App 本地 UserDefaults**）。
enum RadarPixelShiftStore {

    /// 偏好键。
    static let key = "zs.radar.pixelShiftMode"

    /// 读取当前档位（非法值回落 `.off`）。
    static func current() -> RadarPixelShiftMode {
        RadarPixelShiftMode.from(rawValue: UserDefaults.standard.string(forKey: key))
    }

    /// 写入档位。
    static func set(_ mode: RadarPixelShiftMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: key)
    }
}

// MARK: - 像素级平移渲染器

/// **在绘制期平移瓦片内容**的渲染器（`MKTileOverlayRenderer` 子类）。
///
/// ── 机制（路径 A，可行性已查证）────────────────────────────────────────
/// `MKTileOverlayRenderer` 官方页**只有** `init(tileOverlay:)` 与 `reloadData()`，
/// **没有任何**平移属性（实测查证，见 `CoordinateTransform.Evidence.tileRendererExposesTranslationAPI`）。
/// 但 `MKOverlayRenderer.draw(_:zoomScale:in:)` 是 Apple 文档**明写**的子类钩子：
/// "Subclasses need to override the `draw(_:zoomScale:in:)` method to draw the
/// contents of the overlay."（见 `Evidence.overlayRendererSubclassHookQuote`）
/// 该方法收 `CGContext`，故用 Core Graphics 的 `translateBy` 即可整体平移。
///
/// ── ⚠️🔴 两条必须一起读的诚实说明 ──────────────────────────────────────
/// 1. **平移量不足 1 设备像素**（实测：z7 @2x 全中国境内最大 **0.931 pt**，
///    552 个瓦片里**0 个** ≥ 1.0 px）→ **开了也看不出对齐变了**。
///    这不是 bug，是 663 m 偏移在 z7 分辨率下的物理事实。
/// 2. **方向未定**（R1）。本类**只提供机制**，不宣称哪个方向正确；
///    正/反两个方向由 `RadarPixelShiftMode` 显式选择，供真机 A/B。
///
/// ──🔴 `draw` 的两个约束（Apple 文档原文）────────────────────────────────
///  "The map view may tile large overlays and distribute the rendering of each
///   tile to separate threads. Therefore, the implementation of your
///   `draw(_:zoomScale:in:)` method needs to be safe to run from background
///   threads and from multiple threads simultaneously."
/// ⇒ 本实现**只读**不可变 `let` 属性、不改任何共享状态，天然线程安全。
final class ShiftedTileOverlayRenderer: MKTileOverlayRenderer {

    /// 平移量（**点**，东正西负 / 北正南负已在外部算好）。
    ///
    /// ⚠️ 之所以能在init 里定死：偏移是**该overlay 覆盖区域的常量**
    /// （瓦片内任一点与区域中心的 GCJ 偏移差< 1 m，可忽略），
    /// 且`draw` 可能被多线程并发调用 —— 故**绝不能在 draw 内算**。
    private let shiftX: CGFloat

    /// 纵向平移量（点；CGContext 的 y 向下，故北向偏移对应**负** y）。
    private let shiftY: CGFloat

    /// 构造。
    ///
    /// - Parameters:
    ///   - tileOverlay: 覆盖层。
    ///   - shift: 平移向量（**点**，`CGContext` 坐标：x 东正、y 下正）。
    init(tileOverlay: MKTileOverlay, shift: CGVector) {
        self.shiftX = shift.dx
        self.shiftY = shift.dy
        super.init(tileOverlay: tileOverlay)
    }

    // MARK: - 平移向量计算（**纯几何，MapKit 侧唯一入口**）

    /// 按平移档位算出应施加的平移向量（点）。
    ///
    /// ── 换算（与 `CoordinateTransform.pixelShiftProbe` 同一条链）────────────
    /// `点 = 米 × MKMapPointsPerMeterAtLatitude(lat) × MKZoomScale`
    /// 其中 `MKZoomScale` 由**瓦片层级 + 瓦片边长 + contentScaleFactor** 反推。
    ///
    /// ⚠️🔴 **诚实声明（三条，缺一不可）** ─────────────────────────────────
    /// 1. **方向未验证**：本函数只实现「沿/反纠偏方向」两种**符号约定**，
    ///    哪个约定对应"看起来对齐了"**只能真机确定**（R1）。故档位名里
    ///    直接写「方向未验证」，UI 也如实显示 —— **不得**写成"已纠偏"。
    /// 2. **平移量在 @1x/@2x 不足 1 设备像素**（实测 z7@2x 全中国境内最大
    ///    **0.933 设备像素** = 广州；552 瓦片 0 个 ≥ 1 px）⇒ 开了**也看不出**
    ///    差别。
    ///    ⚠️ **按倍率分档，不可无条件转述**：@3x + z7 有 3 个参考点越过 1 px
    ///    （广州 1.400 px），@3x 上是**看得见的**。
    /// 3. `zoomScale` 实际由**相机**决定，此处按「瓦片 1:1 显示」估算。
    ///    MapKit overzoom 时真实值会偏大，平移量同比例放大 ——
    ///    但方向这条结论不受影响；"看不见"那条**只对 @1x/@2x 成立**。
    ///
    /// - Parameters:
    ///   - center: 地图中心（WGS84），偏移量在此点上取。
    ///   - mode: 平移档位。
    /// - Returns: 平移向量（点）；`.off` / 参数非法 → `dx = dy = 0`。
    static func shiftVector(for center: CLLocationCoordinate2D,
                            mode: RadarPixelShiftMode) -> CGVector {
        let sign = mode.directionSign
        guard sign != 0 else { return CGVector(dx: 0, dy: 0) }
        // 直接取该纬度每米点数与 zoomScale，复用 Core 的换算（不在此处重写公式）。
        let probe = CoordinateTransform.pixelShiftProbe(
            longitude: center.longitude,
            latitude: center.latitude,
            zoom: RadarTileZoomRange.maximum,
            tileEdge: CGFloat(RadarTileURLBuilder.tileEdge),
            contentScaleFactor: Double(UIScreen.main.scale))
        let eastPoints = centerShiftComponent(probe: probe,
                                              center: center,
                                              eastward: true)
        let northPoints = centerShiftComponent(probe: probe,
                                               center: center,
                                               eastward: false)
        // 🔴 符号即"方向未验证"的落点：`shiftAlongCorrection` 往纠偏的反方向挪
        // （若 MapKit 真的已纠偏过瓦片，则不纠偏才是对的；反之亦然 —— 真机二选一）。
        return CGVector(dx: CGFloat(-sign * eastPoints),
                        dy: CGFloat(sign * northPoints))
    }

    /// 探针在地图中心处的单轴平移分量（点）。
    ///
    /// - Parameters:
    ///   - probe: 探针结果（提供偏移米数与该纬度每米点数）。
    ///   - center: 地图中心（取纬度）。
    ///   - eastward: `true` 取东向分量，`false` 取北向分量。
    /// - Returns: 分量（点）。
    private static func centerShiftComponent(probe: CoordinateTransform.PixelShiftProbe,
                                            center: CLLocationCoordinate2D,
                                            eastward: Bool) -> Double {
        let perMeter = CoordinateTransform.mapPointsPerMeter(atLatitude: center.latitude)
        // ⚠️ `zoomScale` 不收contentScaleFactor（2026-10-07 修正）：
        // `translateBy` 收的是**点**，缩放因子只在 `magnitudeDevicePixels` 施加一次。
        let scale = CoordinateTransform.zoomScale(
            atZoom: probe.zoom,
            tileEdge: CGFloat(RadarTileURLBuilder.tileEdge))
        return (eastward ? probe.eastMeters : probe.northMeters) * perMeter * scale
    }

    /// 平移绘制（Apple 文档指定的子类钩子）。
    ///
    /// - Parameters:
    ///   - mapRect: 待绘制区域。
    ///   - zoomScale: 当前缩放（点 / mapPoint）。
    ///   - context: 绘制上下文。
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard shiftX != 0 || shiftY != 0 else {
            // 未开启平移 → 走原生路径，**一个字节都不改变**（逐像素一致）。
            super.draw(mapRect, zoomScale: zoomScale, in: context)
            return
        }
        // ⚠️ **代价（如实记录）**：MapKit 只渲染与 `mapRect` 相交的瓦片，
        // 平移后边缘会露出与平移量等宽的空隙。实测 z7@2x 最大约 **0.93 设备像素**
        // （广州，见 `PixelShiftMagnitudeTests`；@3x 约 1.40 px）。
        // 该空隙由 `alpha`/底图透出，不是灰块 —— 但**确实是副作用**。
        context.saveGState()
        context.translateBy(x: shiftX, y: shiftY)
        super.draw(mapRect, zoomScale: zoomScale, in: context)
        context.restoreGState()
    }
}

// MARK: - MKMapView 包装

/// `MKMapView` 的 SwiftUI 包装（承载 `MKTileOverlay` 的唯一途径）。
///
/// ── 相机缩放上限（本轮新增，根因修复）────────────────────────────────
/// RainViewer 只有 z4–z7；一旦 MapKit 开始索取 z8，它就**不再取瓦片**
/// → 只剩底图。本视图据 `RadarZoomCap` 把相机最近距离钳在"刚好不触发
/// z8 索取"处，于是用户看到的最大范围**就是有回波的范围**。
/// ⚠️ 缩放上限**必须在这里、且只能在运行时实测**：`MKMapCamera` 没有
/// `distance` 属性（只有已废弃的 `altitude`），而距离 ↔ 层级隔着 Apple
/// 未公开的相机 FOV —— 详见 `RadarZoomCap` 文件头。
///
/// - Note: 本类型整体标`@MainActor`（与 `TyphoonTrackMapView` 同款判定：
///   `MKMapView` 是 `UIViewRepresentable`，`makeUIView` / `updateUIView`
///   均在主 actor 上执行，且本视图要读写 `RadarZoomCap` 这个 `@MainActor` 类型）。
@MainActor
struct RadarMapView: UIViewRepresentable {

    /// 当前要显示的帧路径；nil = 不叠回波。
    let framePath: String?
    /// 瓦片宿主。
    let host: String
    /// 纠偏模式。
    let mode: CoordinateTransformMode
    /// 像素级平移档位（R2；`.off` = 逐像素等价于原生渲染）。
    let pixelShift: RadarPixelShiftMode
    /// 缓存。
    let cache: RadarTileCache
    /// 地图中心（选中城市）。
    let center: CLLocationCoordinate2D

    /// 「用户已放大到回波精度上限」→ 由 Coordinator 写回，供本卡显示提示。
    ///
    /// ⚠️ 用`@Binding` 而非回调：Coordinator 是 `MKMapViewDelegate`，
    /// 在主线程上写 Binding 是 SwiftUI 的标准做法，且能让提示与地图
    /// 状态保持单一真源（不会出现"地图动了、提示没动"）。
    @Binding var isAtMaximumZoom: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        // 🆕 缩放上限：这里只设**兜底**值（此时 `bounds.width == 0`，
        // 视口未就绪 ⇒ `RadarZoomCap.calibration(of:)` 必然返回 nil）。
        // 真正的实测值由 `updateUIView` 在布局完成后装上。
        map.cameraZoomRange = MKMapView.CameraZoomRange(
            minCenterCoordinateDistance: RadarZoomCap.fallbackMinimumCenterDistance,
            maxCenterCoordinateDistance: RadarZoomCap.maximumCenterDistance
        )
        map.setRegion(MKCoordinateRegion(center: center,
                                         latitudinalMeters: 800_000,
                                         longitudinalMeters: 800_000),
                      animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        //⓪ 回写通道：把 Binding 交给 Coordinator（每次 update 幂等重设，
        //   因为 SwiftUI 可能在 Coordinator 存活期间重建 Binding）。
        context.coordinator.isAtMaximumZoom = $isAtMaximumZoom

        // ① 缩放上限（**每次 update 都重算**）：
        //   视口尺寸会随布局/旋转变化，而实测标定依赖 `bounds` 与
        //   `visibleMapRect` —— 只在 `makeUIView` 装一次会拿到兜底值。
        context.coordinator.installZoomCap(on: map)

        // ⚠️ **换帧必须重建overlay，不能只 `reloadData()`**：
        // `framePath` 与纠偏模式都是 overlay 的不可变初值，`reloadData()` 只会用
        // **同一个** framePath 重新取瓦片 —— 那样时间轴滑动会"看起来在动、底图不变"。
        // 判据：帧路径 / 纠偏模式 / 平移档位任一变化 → 换实例。
        let needsRebuild = context.coordinator.installedFramePath != framePath
            || context.coordinator.installedMode != mode
            || context.coordinator.installedPixelShift != pixelShift
        guard needsRebuild else { return }
        map.removeOverlays(map.overlays)
        if let framePath {
            let overlay = RadarTileOverlay(host: host,
                                           framePath: framePath,
                                           mode: mode,
                                           cache: cache)
            // 平移向量随 overlay 一起交给 Coordinator（renderer 由 delegate 回调时构造）。
            context.coordinator.shift = ShiftedTileOverlayRenderer.shiftVector(
                for: center, mode: pixelShift)
            map.addOverlay(overlay, level: .aboveRoads)
        }
        context.coordinator.installedFramePath = framePath
        context.coordinator.installedMode = mode
        context.coordinator.installedPixelShift = pixelShift
    }

    /// 渲染器工厂。
    final class Coordinator: NSObject, MKMapViewDelegate {
        /// 当前已装上的帧路径（nil = 无回波层）。
        var installedFramePath: String?

        /// 当前已装上的纠偏模式。
        var installedMode: CoordinateTransformMode?

        /// 当前已装上的平移档位。
        var installedPixelShift: RadarPixelShiftMode?

        /// 待施加的平移向量（点；`nil` = 不平移）。
        var shift: CGVector?

        /// 「已到放大上限」的回写通道（由 `RadarMapView` 注入）。
        var isAtMaximumZoom: Binding<Bool>?

        /// 本次生效的相机最近距离（米）；nil = 尚未装上任何上限。
        private(set) var installedMinimumCenterDistance: Double?

        /// 把实测出的缩放上限装到地图上，并把「是否触顶」写回 SwiftUI。
        ///
        /// ⚠️ **为什么 `isZoomEnabled` 一类"禁用缩放"的开关不用**：那会让用户
        /// 连正常的放大都做不了，体验更差。这里只**钳住上限**，放大手势照常
        /// 可用，只是到回波极限就不再生长 —— 这正是我们要的语义。
        ///
        /// - Parameter map: 活地图。
        func installZoomCap(on map: MKMapView) {
            let minimum = RadarZoomCap.minimumCenterDistance(
                calibration: RadarZoomCap.calibration(of: map))
                ?? RadarZoomCap.fallbackMinimumCenterDistance
            //⚠️ 用**相对阈值**而非 `!=` 比较：实测标定每次都带浮点噪声，
            //   `!=` 会让 `cameraZoomRange` 被反复重设，而重设会打断
            //   用户正在进行的缩放手势（地图会"黏手"）。
            //   变化不足 `capRecalibrationThreshold`（2%）就当作没变。
            if shouldApplyZoomCap(minimum) {
                map.cameraZoomRange = MKMapView.CameraZoomRange(
                    minCenterCoordinateDistance: minimum,
                    maxCenterCoordinateDistance: RadarZoomCap.maximumCenterDistance
                )
                installedMinimumCenterDistance = minimum
            }
            refreshMaximumZoomFlag(on: map)
        }

        /// 上限是否变化到值得重设 `cameraZoomRange`（相对阈值判定）。
        ///
        /// - Parameter minimum: 本次实测出的上限（米）。
        /// - Returns: 需要重设 → `true`。
        private func shouldApplyZoomCap(_ minimum: Double) -> Bool {
            guard let previous = installedMinimumCenterDistance else { return true }
            guard previous > 0 else { return true }
            let drift = abs(minimum - previous) / previous
            return drift >= RadarZoomCap.capRecalibrationThreshold
        }

        /// 区域变化后刷新「已触顶」标记。
        ///
        /// - Parameter map: 活地图。
        func refreshMaximumZoomFlag(on map: MKMapView) {
            guard let binding = isAtMaximumZoom else { return }
            let reached = RadarZoomCap.isAtMaximumZoom(
                mapView: map,
                minimumDistance: installedMinimumCenterDistance
                    ?? RadarZoomCap.fallbackMinimumCenterDistance)
            // ⚠️ 只在**值真的变了**时写 Binding：写 `State` 会触发一次
            // 视图更新，若无条件写就成"update → 写 State → update"的循环。
            if binding.wrappedValue != reached {
                binding.wrappedValue = reached
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                //
                // ⚠️ 平移**只能**在这里做 —— `MKTileOverlayRenderer` 没有平移 API
                // （实测查证，见 `Evidence.tileRendererExposesTranslationAPI`），
                // 唯一途径是覆写 `draw(_:zoomScale:in:)`。
                //
                // （另：此处曾注释「loadingPolicy 在 overlay 上设」——那是错的，
                //  该 API 不存在，见 `RadarTileOverlay.init` 里的详细更正。）
                guard let shift, shift.dx != 0 || shift.dy != 0 else {
                    // 不平移 → 用原生类，**完全不改渲染行为**。
                    return MKTileOverlayRenderer(tileOverlay: tileOverlay)
                }
                return ShiftedTileOverlayRenderer(tileOverlay: tileOverlay, shift: shift)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        /// 区域变化（缩放**或平移**）后回调。
        ///
        /// ⚠️ **平移也必须重算上限**：上限是一个标量距离，而"该距离对应哪一级"
        /// **随纬度变化**（见 `RadarZoomCap` 文件头的纬度归一化推导）。
        /// 用户从海口拖到哈尔滨，若不重算，边界就会偏 0.6 个层级。
        /// 故这里调`installZoomCap`（内部有 2% 防抖阈值，不会打断手势）。
        ///
        /// - Parameters:
        ///   - mapView: 活地图。
        ///   - animated: 是否动画过渡。
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            installZoomCap(on: mapView)
        }
    }
}

// MARK: - 雷达卡

/// 降水雷达卡（**主屏装配入口**，含降级四态）。
///
/// 装配契约：
///  · 状态由 `RadarCardModel` 提供（`@Observable`），本视图**只渲染，不判定**；
///  · 降级四态（含 `.radarUnavailable`）**必须完整渲染出可见内容**，
///    **绝不允许**出现空白地图页或无限转圈（硬要求）。
@MainActor
struct RadarMapCard: View {

    /// 状态容器（四态、时间轴、覆盖、纠偏档的唯一真源）。
    let model: RadarCardModel

    /// 时刻渲染时区（D-4 一致性：随选中城市时区）。
    var timeZone: TimeZone = .current

    /// 回放选中帧（受控：由本视图的 scrubber 写入）。
    @State private var selectedIndex: Int?

    /// 本卡折叠态（初值读持久化；点标题行右侧按钮翻转）。
    @State private var isCollapsed: Bool = CardVisibilityStore.isCollapsed(.radar)

    /// 用户是否已把雷达地图放大到**回波精度上限**（由 `RadarMapView` 回写）。
    ///
    /// ⚠️ 存在的理由：上限是**静默**的——手指继续张开但地图不再响应，
    /// 用户无从判断"到头了"还是"坏了"。故必须**如实告知为什么到头了**。
    @State private var isAtMaximumZoom: Bool = false

    /// 地图高度（pt）。
    private let mapHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            // 折叠态：只保留标题行，地图与时间轴等主体内容不渲染。
            //
            // ⚠️ **降级四态的硬要求不受影响**：`RadarMapCard` 要求「四态都必须
            // 渲染出可见内容、绝不允许空白页」。折叠是**用户主动**的操作
            // （非降级），标题行仍在、按钮仍可点回展开，故不违反该要求。
            if !isCollapsed {
                mapArea
                maximumZoomNote
                pixelShiftNote
                if availability.allowsScrubbing, let timeline {
                    timelineBar(timeline)
                }
                // `delayNote` 是 `@ViewBuilder -> some View`（内部自行判空并用
                // TimelineView 更新），**不是** Optional —— 用 `if let` 解它会
                // 让 `note` 变成 `some View`，而 `Text(_:)` 要的是 StringProtocol。
                delayNote(timeline)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(Theme.divider, lineWidth: 0.5)
        )
    }

    // MARK: - 🔴 缩放上限提示（如实告知"为什么到头了"）

    /// 已放大到回波精度上限时的一行提示；未触顶时**不渲染任何东西**。
    ///
    /// ── 为什么选「地图下方一行文字」而不是「地图上的小标记」────────────
    /// ① **冲突**：地图只有 220 pt 高，左下角被 RainViewer 署名**硬性**占着
    ///    （许可要求），左上角被降级说明占着（降级态硬要求）。再往地图上叠
    ///    第三个浮层 ⇒ 三者互相压字，而这三样**每一件都是硬要求**。
    ///    放在地图**下方**是唯一不与任何硬要求争夺像素的位置。
    /// ② **诚实性**：要解释"为什么到头了"，需要说清"数据源只到 z几"，
    ///    一行文字承载得下，一个 8 pt 的小图标承载不下。
    ///
    /// ⚠️ **只在触顶时出现**：未触顶时显示"你还能继续放大"是噪音。
    /// 触顶判定由 `RadarMapView` 实测回写（`RadarZoomCap.isAtMaximumZoom`），
    /// 本视图**不自行判定**。
    ///
    /// ⚠️ 文案里的 z 数字**由`RadarTileZoomRange.maximum` 生成**，不写死
    /// "7" —— 那个常量哪天变了，说明文字必须跟着变，否则就是**假话**。
    @ViewBuilder
    private var maximumZoomNote: some View {
        if isAtMaximumZoom {
            Text(Self.maximumZoomNoteText)
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.accentSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 触顶提示文案（`static let`）。
    ///
    /// ⚠️ **必须是 `static let` 而不是 ViewBuilder 里的内联拼接**：
    /// 多个 `+` 串起来的字符串表达式会让类型检查器指数爆炸
    /// （"unable to type-check this expression in reasonable time"）。
    /// 提到类型级常量上，语义完全不变。
    private static let maximumZoomNoteText: String = {
        let zoomLabel = String(RadarTileZoomRange.maximum)
        let source = "RainViewer 回波数据只提供到 z" + zoomLabel
        let reason = "更高层级无数据，再放大也不会更清晰"
        return "已到回波最高精度 · " + source + " · " + reason
    }()

    // MARK: - 🔴 像素级平移读数（如实显示，**不得写成"已纠偏"**）

    /// 平移档位的一行读数。
    ///
    /// ⚠️ 本行的存在理由：平移量在**@1x/@2x** 实测不足 1 设备像素，用户**看不出**
    /// 差别；而方向又**未验证**。若不显示，用户会以为"纠偏已生效"。故必须写出来：
    /// 「平移量 = N px · 纠偏方向未验证 · 切档不影响请求」。
    ///
    /// 🔴 **可辨性必须按倍率分档如实标注**（2026-10-07 修正）：本机
    /// `UIScreen.main.scale` 可能是 **3**，而 @3x + z7 的平移量确实越过 1 px
    /// （广州 1.400 px）⇒ 若此处无条件写"肉眼不可辨"就是**假话**。
    /// 故直接用探针的 `isVisuallyDetectable`（阈值 = 1 设备像素）分支。
    ///
    /// `.off` 时只显示"未平移"，**不**谎称任何纠偏状态。
    ///
    /// ⚠️ 文案**拆成局部变量**而非一个大三元表达式：
    /// 编译器在单个表达式里遇到两个多段 `+` 拼接的 String 分支时
    /// 会报 "unable to type-check this expression in reasonable time"
    /// （类型检查器在字符串运算符上指数爆炸）。这是编译期问题，
    /// **不是**性能问题 —— 拆开后语义完全不变。
    @ViewBuilder
    private var pixelShiftNote: some View {
        let mode = model.pixelShiftMode
        let probe = CoordinateTransform.pixelShiftProbe(
            longitude: model.center.longitude,
            latitude: model.center.latitude,
            zoom: RadarTileZoomRange.maximum,
            tileEdge: Double(RadarTileURLBuilder.tileEdge),
            contentScaleFactor: Double(UIScreen.main.scale))
        let amount = CoordinateTransform.decimal2(probe.magnitudeDevicePixels)
        let zoomLabel = String(RadarTileZoomRange.maximum)
        let suffix = " · " + mode.displayName + " · 纠偏方向未验证"
        // ⚠️ 同样受上面的类型检查器约束：可辨性单独成一个局部变量，
        // **不**把三元表达式嵌进 `+` 链里。
        let detectability = probe.isVisuallyDetectable
            ? "（已达 1 px，本机倍率下可能可辨）"
            : "（不足 1 px，肉眼不可辨）"
        let shiftedLine = "平移量 " + amount + " px@" + zoomLabel + detectability
        let line = mode.appliesShift ? shiftedLine : "未平移"
        Text(line + suffix)
            .font(.system(size: Theme.FontSize.caption))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 派生

    /// 降级四态（由 model 派生，本视图不自行判定）。
    private var availability: RadarAvailability { model.availability }

    /// 时间轴（由 model 提供）。
    private var timeline: RadarTimeline? { model.timeline }

    // MARK: - 标题

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "cloud.rain.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.accentSecondary)
            Text("降水雷达")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Spacer(minLength: 8)
            Text(availability.headline)
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            CardCollapseButton(card: .radar, isCollapsed: isCollapsed, onToggle: toggleCollapse)
        }
    }

    // MARK: - 折叠切换

    /// 翻转折叠态：落库 + 改本地状态（动画与图标统一由 `CardCollapseButton` 驱动）。
    private func toggleCollapse() {
        let next = CardCollapseButton.toggleCollapsed(.radar)
        withAnimation(.easeInOut(duration: 0.15)) {
            isCollapsed = next
        }
    }

    // MARK: - 地图区（**四态都不为空**）

    private var mapArea: some View {
        ZStack(alignment: .bottomLeading) {
            // ⚠️ **四态都渲染地图**（含 `.radarUnavailable`）——
            // 硬要求：地图页仍可进，**绝不允许**空白页 / 无限转圈。
            // 非 `.radar` 态只是**不叠回波层**（`currentFramePath` 返回 nil），
            // 底图照常显示，上方另有明确降级文案。
            ZStack {
                RadarMapView(
                    framePath: currentFramePath,
                    host: model.host,
                    mode: model.coordinateMode,
                    pixelShift: model.pixelShiftMode,
                    cache: model.tileCache,
                    center: model.center.mapCoordinate,
                    isAtMaximumZoom: $isAtMaximumZoom
                )
                .frame(height: mapHeight)

                // 首次加载：真实进度指示 + 明确说明。
                // ⚠️ 必须**由 isLoading 驱动、且有超时兜底**（见 model 的
                // loadTaskHasTimedOut）—— 否则取数失败时这里会永久转圈，
                // 那正是"转圈卡死"，是最容易被误认为功能正常的失败态。
                if model.isLoading && !model.hasTimedOut {
                    VStack(spacing: 6) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(Theme.accent)
                        Text("正在获取雷达回波…")
                            .font(.system(size: Theme.FontSize.footnote))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .frame(height: mapHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // 降级态说明放**左上角**：署名固定占左下角（许可硬要求），
            // 两者同角会互相压字（降级态恰好是最需要看清说明的时候）。
            if let overlayText = degradedOverlayText {
                Text(overlayText)
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }

            // 署名（许可硬要求：固定在**左下角**、底图之上）。
            attribution
                .padding(8)
        }
    }

    /// 非 `.radar` 态在地图上的补充说明。
    ///
    /// ⚠️ **`.radarUnavailable` 绝不能返回 nil**（否则地图上什么字都没有 =
    /// 用户看到一片空白）。每个降级态都必须有一句可读说明。
    private var degradedOverlayText: String? {
        switch availability {
        case .radar:
            return nil
        case .forecast(let kind):
            return kind == .domesticHourly
                ? "回波暂缺 · 见下方逐时概率"
                : "境外区域 · 见下方 2 小时概率条"
        case .radarUnavailable(let reason):
            // 三种原因**都**有文案（"本区域暂无实时回波 · 下方为模型概率"）。
            // 加载超时另给一句可操作提示，绝不空着。
            if model.isLoading && model.hasTimedOut {
                return "雷达加载超时 · 已显示底图，下方为模型概率"
            }
            return reason.headline
        }
    }

    // MARK: - 时间轴（仅 `.radar` 且帧数 ≥ 1）

    /// ⚠️ 刻意**不用** `@ViewBuilder` + `let` 开头：结果构造器里的局部 `let`
    /// 在不同 Swift 版本下行为不稳。本仓既有惯例（`MinutelyPrecipitationCard.bar`）
    /// 是「局部 let + 显式 `return`」，这里沿用同一写法。
    private func timelineBar(_ timeline: RadarTimeline) -> some View {
        let index = min(max(selectedIndex ?? timeline.count - 1, 0), timeline.count - 1)
        let isLatest = index == timeline.count - 1
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(isLatest ? "实况" : "回放中")
                    .font(.system(size: Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(isLatest ? Theme.accent : Theme.accentSecondary)
                Spacer(minLength: 8)
                Text(timeText(timeline.frames[index].time))
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            }
            Slider(
                value: Binding(
                    get: { Double(index) },
                    set: { selectedIndex = Int($0.rounded()) }
                ),
                in: 0...Double(max(timeline.count - 1, 1)),
                step: 1
            )
            .disabled(timeline.count <= 1)
            HStack {
                Text(timeText(timeline.frames[0].time))
                Spacer(minLength: 8)
                Text("10 分钟粒度 · 共 \(timeline.count) 帧")
                Spacer(minLength: 8)
                Text(timeText(timeline.frames[timeline.count - 1].time))
            }
            .font(.system(size: 9))
            .foregroundStyle(Theme.secondaryText)
        }
    }

    // MARK: - 数据延迟诚实提示

    /// 「数据延迟 N 分钟」——`now` 由 `TimelineView` 注入，**本文件不调 `Date()`**。
    @ViewBuilder
    private func delayNote(_ timeline: RadarTimeline?) -> some View {
        if let timeline {
            TimelineView(.everyMinute) { context in
                if let age = timeline.ageMinutes(now: context.date), age > 20 {
                    Text("数据延迟 \(age) 分钟 · 回波每 10 分钟更新")
                        .font(.system(size: Theme.FontSize.footnote))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    // MARK: - 署名（许可硬要求）

    /// "Weather data by RainViewer" + 链接。
    ///
    /// ⚠️ 这是 RainViewer 许可的**强制**要求，**不得**删减、不得挪到别处、
    /// 不得改成"数据来源"之类含糊措辞。
    private var attribution: some View {
        HStack(spacing: 4) {
            Text("Weather data by")
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
            Link("RainViewer", destination: URL(string: "https://www.rainviewer.com/")!)
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.accentSecondary)
        }
        .shadow(color: .black.opacity(0.5), radius: 2)
    }

    // MARK: - 私有

    /// 当前应显示的帧路径（仅 `.radar` 且帧存在时非 nil）。
    private var currentFramePath: String? {
        guard availability.showsRadarTiles, let timeline else { return nil }
        let index = min(max(selectedIndex ?? timeline.count - 1, 0), timeline.count - 1)
        guard timeline.frames.indices.contains(index) else { return nil }
        return timeline.frames[index].path
    }

    /// 「HH:mm」（按传入时区；复用既有格式器缓存）。
    private func timeText(_ date: Date) -> String {
        WeatherTimeFormatter.string(from: date, format: "HH:mm", timeZone: timeZone)
    }
}

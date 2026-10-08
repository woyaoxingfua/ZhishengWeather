//
//  RadarZoomCap.swift
//  ZhishengWeather（主 App target）
//
//  雷达地图的**相机缩放上限**：把用户能放到的最大层级钉在 RainViewer 的
//  实际上界（`RadarTileZoomRange.maximum` = z7），让"可看到的最大范围"
//  就是"有回波的范围"。
//
//  ── 为什么需要它（本文件存在的唯一理由）────────────────────────────────
//  Apple 官方文档 `MKTileOverlay.maximumZ` **原文**：
//    "The map doesn't attempt to load tiles for a zoom level greater than
//     the value that this property specifies."
//  ⇒ **超过 `maximumZ` 后 MapKit 根本不去取瓦片**（不是"取到灰图"）。
//  而 z8 起 RainViewer 只有 1370 B 灰阶占位图（见 `RainViewerService.swift`
//  文件头）⇒ 用户放大过 z7 → 无瓦片可画 → **只剩底图**。
//  这正是本次要修的现象。
//
//  ── 正确方向：限相机，**绝不**伪造瓦片 ──────────────────────────────────
//  ⚠️ **反面做法（本文件明确禁止）**：把 z8+ 的请求"补"成 z7 的图、
//  或自造瓦片。那只是把"没图"换成"糊图"，且违背 RainViewer 的数据事实——
//  RainViewer **没有** z8+ 的数据，谁也造不出来。
//  唯一正解是**让用户放不到那个层级**。
//
//  ── 🔴🔴 换算里最容易错的一环：`distance × zoomScale` **不是**常数 ──────
//  针孔模型（俯视，pitch = 0）下：
//     视野地面高度(米) = 2 · d · tan(fovY/2)
//     视野地面高度(米) = mpp(lat) · 视口高(点) / zoomScale
//  消去 fovY（Apple **从未公布**，P-24：不能编）⇒
//     d · zoomScale =视口高 · mpp(lat) / (2·tan(fovY/2))
//  右边**含 `mpp(lat)`**，而 `mpp(lat) = 40075016.686 / 世界宽 · |cos lat|`
//  ⇒ 不变量**随纬度变化**，`cos(lat)` 越大（纬度越低）值越大。
//
//  实测（本仓Python 复算，中国境内 18°N–53°N）：
//     mpp 比值 0.633倍 ⇒ 相当于 **0.66 个zoom 层级**的漂移。
//  ⇒ 若图省事直接用 `d × zoomScale` 当常数，**在海口标定、在哈尔滨用**
//     就会差0.66 级 —— 而"差一级"正是"要不要空白回波"的差别。
//
//  ✅ **本文件的做法**：把纬度**显式除出去**，只保留真正与设备有关的常数
//     `K = d · zoomScale / mpp(lat)`（= 视口高 / (2·tan(fovY/2))，同设备恒定），
//     再按**当前中心纬度**还原目标距离 ⇒ 纬度无关，用户走到哪都准。
//
//  ── 已核实的 Apple API（逐个查过官方文档，**非推理**）──────────────────
//  · `MKMapView.CameraZoomRange.init?(minCenterCoordinateDistance:maxCenterCoordinateDistance:)`
//    （iOS 13+，两参单位均为米）
//  · `MKMapView.cameraZoomRange: MKMapView.CameraZoomRange!`
//  · `MKMapView.camera: MKMapCamera` ／ `MKMapCamera.centerCoordinateDistance: CLLocationDistance`
//    🔴 **`MKMapCamera` 没有 `distance` 属性**（只有已废弃的 `altitude`）
//       —— 写 `camera.distance` 会直接编译失败。
//  · `MKMapView.visibleMapRect: MKMapRect`
//  · `MKMapViewDelegate.mapView(_:regionDidChangeAnimated:)`
//  · `MKMapSize.world: MKMapSize`（静态属性）＋ `MKMapSize.width: Double`
//
//  ⚠️ 本仓 `CoordinateTransform.MKMapSizeWorldWidth` 是**手抄常量**（其注释
//     已声明「MapKit 未公开该常量来源」）。本文件**改用真正的
//     `MKMapSize.world.width`**，不再依赖那份手抄值。
//
//  ── 与纠偏 / 平移那套东西的关系 ─────────────────────────────────────────
//  本文件**只**动相机缩放，**不碰** `correctedTileCoordinates`（瓦片请求索引）
//  与 `ShiftedTileOverlayRenderer`（绘制期平移）—— 二者与本问题无关：
//  实测证明前者是恒等变换、后者不足 1 设备像素。
//

import Foundation
import MapKit
import CoreLocation

// MARK: - 纯数学（刻意零 MapKit 依赖，可直接单测）

/// 缩放换算的**纯数学**部分。
///
/// ⚠️ 刻意**不 import MapKit**：这样单元测试可在无地图的环境下直接验证
/// 换算本身（含"纬度归一化"这条最容易错的规则），而把 MapKit 的
/// 不确定性（相机 FOV）隔离在 `RadarZoomCap` 内。
enum RadarZoomMath {

    /// 层级 → `MKZoomScale`（点 / mapPoint）。
    ///
    /// 依据：层级 `z` 的世界宽 `2^z` 个瓦片、每瓦片 `tileEdge` 点
    /// → 世界宽 `2^z × tileEdge` 点，除以世界 mapPoint 宽度。
    ///
    /// - Parameters:
    ///   - zoom: 层级（负数非法）。
    ///   - worldWidth: 世界宽度（mapPoint）。
    ///   - tileEdge: 瓦片边长（点）。
    /// - Returns: 点 / mapPoint；参数非法返回 0。
    static func zoomScale(forZoom zoom: Int, worldWidth: Double, tileEdge: Double) -> Double {
        guard zoom >= 0, worldWidth > 0, tileEdge > 0 else { return 0 }
        return Double(1 << zoom) * tileEdge / worldWidth
    }

    /// `MKZoomScale` → 层级（**向下取整**）。
    ///
    /// ⚠️ 取整方向必须与 MapKit 一致（**floor**）：MapKit 是按"当前层级能
    /// 覆盖视野"来挑瓦片的，取整方向若搞反，放大边界会差整整一级 ——
    /// 而差一级正是"要不要出现空白回波"的差别。
    ///
    /// - Returns: 层级；参数非法返回 0。
    static func zoomLevel(zoomScale: Double, worldWidth: Double, tileEdge: Double) -> Int {
        guard zoomScale > 0, worldWidth > 0, tileEdge > 0 else { return 0 }
        let ratio = zoomScale * worldWidth / tileEdge
        guard ratio >= 1 else { return 0 }
        return Int(floor(log2(ratio)))
    }

    /// 🔴 **纬度归一化**后的设备常数 `K = d · zoomScale / mpp(lat)`。
    ///
    /// 推导见文件头：`K = 视口高 / (2·tan(fovY/2))` —— **与纬度无关**，
    /// 只跟"这台设备的视口 + 相机 FOV"有关，故可跨纬度复用。
    /// （这正是把 `mpp(lat)` 除出去的理由；不除就会漂 0.66 级。）
    ///
    /// - Parameters:
    ///   - distance: 相机到视野中心的距离（米）。
    ///   - zoomScale: 点 / mapPoint。
    ///   - metersPerMapPoint: 该纬度上 1 mapPoint 覆盖的米数。
    /// - Returns: 设备常数；参数非法返回 0。
    static func deviceConstant(distance: Double,
                               zoomScale: Double,
                               metersPerMapPoint: Double) -> Double {
        guard distance > 0, zoomScale > 0, metersPerMapPoint > 0 else { return 0 }
        return distance * zoomScale / metersPerMapPoint
    }

    /// 由设备常数 `K` 还原「某纬度、某 `zoomScale` 对应的相机距离」。
    ///
    /// 这是 `deviceConstant` 的逆运算，**必须带上目标纬度** ——
    /// 少了纬度这一步就退化成那个错误的"常数不变量"。
    ///
    /// - Parameters:
    ///   - deviceConstant: `deviceConstant` 的实测值。
    ///   - metersPerMapPoint: 目标纬度上 1 mapPoint 覆盖的米数。
    ///   - targetZoomScale: 目标缩放比例（点 / mapPoint）。
    /// - Returns: 相机距离（米）；参数非法返回 0。
    static func distance(forDeviceConstant deviceConstant: Double,
                         metersPerMapPoint: Double,
                         targetZoomScale: Double) -> Double {
        guard deviceConstant > 0, metersPerMapPoint > 0, targetZoomScale > 0 else { return 0 }
        return deviceConstant * metersPerMapPoint / targetZoomScale
    }

    /// 某纬度上 1 mapPoint 覆盖多少米（= `CoordinateTransform.metersPerMapPoint`）。
    ///
    /// ⚠️ 这里**转发**到 Core 的既有实现而不是重写公式：那份实现有完整的
    /// `cos` 方向纠错史（曾把 `cos` 写反，见 `CoordinateTransform` 文件头），
    /// **绝不能**在UI 侧再抄一遍 —— 抄一遍就多一个会漂移的真相来源。
    ///
    /// - Parameter latitude: 纬度（度）。
    /// - Returns: 米 / mapPoint；纬度非法返回 0。
    static func metersPerMapPoint(atLatitude latitude: Double) -> Double {
        CoordinateTransform.metersPerMapPoint(atLatitude: latitude)
    }
}

// MARK: - 相机上限（MapKit 侧）

/// 雷达地图的相机缩放上限（**MainActor**：全程只碰 `MKMapView` / `MKMapCamera`）。
///
/// ⚠️ 本类型是 `@MainActor` 的，故其 `static` 方法**也是** MainActor 隔离的
/// —— 从 `async` 闭包里调用**必须 `await`**（本仓 P-06b 踩过的坑）。
@MainActor
enum RadarZoomCap {

    // MARK: 常量

    /// 视口尚未就绪（`bounds.width == 0`、读不到 `visibleMapRect`）时的
    /// **保守兜底下限**。
    ///
    /// ⚠️ 取值依据与诚实声明：这是**估出来的**，不是量出来的。
    /// z7 在 220 pt 高的视口下大约对应相机距离 5×10^5 ~ 6×10^5 m
    /// （数量级估算，**未经真机核实**）。取偏大的一侧 ⇒ 即便估算有偏差、
    /// 兜底路径先生效，也只会**少放一点**（回波略显模糊），
    /// **绝不会**放到 z8（空白回波）。方向上故意选保守的一边。
    static let fallbackMinimumCenterDistance: Double = 600_000

    /// 相机缩放上限的**上界**（最远可拉多远）。
    ///
    /// ⚠️ **沿用改动前雷达卡既有的 `24_000_000`**，本任务**不**改变
    /// 缩放范围的下端（拉远）行为 —— 只收紧了上端（放大）。
    static let maximumCenterDistance: Double = 24_000_000

    /// 🔴 允许的最大 `zoomScale` ——锚点是 **z8（第一个"取不到"层级）**，
    /// **不是 z7**。这是本任务最容易搞错的一格。
    ///
    /// ⚠️ **为什么锚 z8**：
    /// · 用户的诉求是"放大到**能看到的最清晰**"，而 z7 瓦片是**真实存在**的；
    /// · 真正导致"只剩底图"的是 MapKit **开始索取 z8**（Apple 文档：超出
    ///   `maximumZ` 就不取瓦片）——那一刻才 blank。
    /// · 所以上限要卡在"**刚好不让MapKit 开口要 z8**"的位置，
    ///   这样用户既能用到真z7 瓦片，又绝不会空白。
    ///
    /// ⚠️ **为什么不能直接锚 z7**：`zoomLevel` 用 `floor`（见上），
    /// 取整的边界在 `z` 与 `z+1` 的**中点**。若把上限设在 z7 的 zoomScale
    /// 再往下退一点，`floor` 会掉到 **6** ⇒ 白白浪费一整级清晰度。
    /// 实测（本仓 Python 复算）：
    ///     上限 = z7 × 2^-0.5  → floor = 6（**损失一级**）
    ///     上限 = z8 × 0.94    → floor = 7（**正好拿到真 z7，且永不触z8**）
    ///
    /// `zoomMarginLevels` 的作用因此变成"**在 z8 边界内退多少**"，
    /// 而不是"从 z7 退多少" —— 后者是错的。
    static let zoomMarginLevels: Double = 0.5

    /// 判定"已到上限"的相对容差。
    ///
    /// 相机被钳在上限上时 `centerCoordinateDistance` **恰好等于**上限值，
    /// 但浮点与 MapKit 内部的取整会带来微小偏差，故留 2% 容差，
    /// 让提示**在触顶时就能出现**，而不是差之毫厘才显示。
    static let atCapTolerance: Double = 0.02

    /// 上限重算的相对阈值：变化小于它就不动`cameraZoomRange`。
    ///
    /// ⚠️ 存在的原因**不是**省性能，而是**防抖**：改`cameraZoomRange`
    /// 会把正在进行的缩放/平移手势打断。若每帧都因测量噪声微调而重设，
    /// 用户会觉得"地图黏手"。只在**真的差了一截**时才重设。
    static let capRecalibrationThreshold: Double = 0.02

    // MARK: 派生量

    /// 世界宽度（mapPoint）——取**真正的** `MKMapSize.world`，不用手抄常量。
    static var worldWidth: Double { MKMapSize.world.width }

    /// 瓦片边长（点）。
    static var tileEdge: Double { Double(RadarTileURLBuilder.tileEdge) }

    /// 回波数据支持的最大层级（= `RadarTileZoomRange.maximum`，当前 7）。
    static var maximumEchoZoom: Int { RadarTileZoomRange.maximum }

    /// 允许的最大 `zoomScale`（= **z8** 的 zoomScale 再退 `zoomMarginLevels` 级）。
    ///
    /// ⚠️ 锚点是 z8 而非 z7，理由见 `zoomMarginLevels` 的注释（一整级的差别）。
    /// 用 `pow(2, -margin)` 而不是魔法小数：让"退半个层级"在代码里
    /// **可读**，且与 `zoomLevel(zoomScale:)` 的 `log2` 刚好互逆。
    static var maximumZoomScale: Double {
        // 锚点 = maximumEchoZoom + 1 = **第一个取不到的层级**（当前 8）。
        let anchorZoom = maximumEchoZoom + 1
        let base = RadarZoomMath.zoomScale(forZoom: anchorZoom,
                                          worldWidth: worldWidth,
                                          tileEdge: tileEdge)
        return base * pow(2, -zoomMarginLevels)
    }

    // MARK: 实测标定

    /// 一次**实测**标定结果（相机距离 + zoomScale + 中心纬度）。
    struct Calibration {
        /// 相机到视野中心的距离（米）。
        let distance: Double
        /// 点 / mapPoint。
        let zoomScale: Double
        /// 视野中心纬度（度）—— **必须带上**，见文件头的纬度归一化。
        let latitude: Double
    }

    /// 从**活的** `MKMapView` 实测一次标定。
    ///
    /// 🔴 **为什么必须实测、不能查表**：`MKMapCamera` **没有** `distance`
    /// 属性（只有已废弃的 `altitude`）；而"距离 ↔ 层级"隔着 Apple 未公开的
    /// 相机 FOV。这里改用两个**直接读得到**的量：地图自身的相机距离，
    /// 与由视图尺寸 / 可见范围算出的 `zoomScale`，再**显式除掉纬度**。
    ///
    /// - Returns: 标定值；视口未就绪（尺寸为 0）或读数非法 → `nil`。
    static func calibration(of mapView: MKMapView) -> Calibration? {
        let viewWidth = Double(mapView.bounds.width)
        let visibleWidth = mapView.visibleMapRect.size.width
        guard viewWidth > 0, visibleWidth > 0 else { return nil }
        // zoomScale（点/mapPoint）= 视图宽度（点）/ 可见宽度（mapPoint）。
        let zoomScale = viewWidth / visibleWidth
        // ⚠️ 只能取 `centerCoordinateDistance` —— 见文件头「没有 distance」。
        let distance = mapView.camera.centerCoordinateDistance
        let latitude = mapView.centerCoordinate.latitude
        guard zoomScale > 0, distance > 0 else { return nil }
        return Calibration(distance: distance, zoomScale: zoomScale, latitude: latitude)
    }

    /// 由实测标定推出「相机最近能到多远」（= 放大上限）。
    ///
    /// ⚠️ 纬度取**标定那一刻的中心纬度**：上限是一个标量 `CLLocationDistance`，
    /// 而"该距离对应哪一级"随纬度变化，所以每次重算都要带上当下纬度
    /// （平移后由 `regionDidChange` 再次重算，见 `Coordinator`）。
    ///
    /// - Returns: 相机距离（米）；标定/纬度非法返回 `nil`。
    static func minimumCenterDistance(calibration: Calibration?) -> Double? {
        guard let calibration else { return nil }
        let metersPerPoint = RadarZoomMath.metersPerMapPoint(atLatitude: calibration.latitude)
        let constant = RadarZoomMath.deviceConstant(distance: calibration.distance,
                                                   zoomScale: calibration.zoomScale,
                                                   metersPerMapPoint: metersPerPoint)
        let result = RadarZoomMath.distance(forDeviceConstant: constant,
                                            metersPerMapPoint: metersPerPoint,
                                            targetZoomScale: maximumZoomScale)
        return result > 0 ? result : nil
    }

    /// 当前是否**已到**放大上限。
    ///
    /// - Parameters:
    ///   - mapView: 活地图。
    ///   - minimumDistance: 本次生效的上限（米）。
    /// - Returns: 触顶 → `true`；上限非法 → `false`（不谎报）。
    static func isAtMaximumZoom(mapView: MKMapView, minimumDistance: Double) -> Bool {
        guard minimumDistance > 0 else { return false }
        let current = mapView.camera.centerCoordinateDistance
        guard current > 0 else { return false }
        return current <= minimumDistance * (1 + atCapTolerance)
    }

    /// 当前相机**实测**处在第几层（供诊断，不作判定依据）。
    ///
    /// - Returns: 层级；读数非法返回 `nil`。
    static func currentZoomLevel(of mapView: MKMapView) -> Int? {
        let viewWidth = Double(mapView.bounds.width)
        let visibleWidth = mapView.visibleMapRect.size.width
        guard viewWidth > 0, visibleWidth > 0 else { return nil }
        let zoomScale = viewWidth / visibleWidth
        let level = RadarZoomMath.zoomLevel(zoomScale: zoomScale,
                                            worldWidth: worldWidth,
                                            tileEdge: tileEdge)
        return level > 0 ? level : nil
    }
}

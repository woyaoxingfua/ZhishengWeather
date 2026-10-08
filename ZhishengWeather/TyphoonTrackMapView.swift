//
//  TyphoonTrackMapView.swift
//  ZhishengWeather（主 App target）
//
//  台风路径地图：MKMapView + **矢量** `MKPolyline`（路径线 / 预报线）
//  + `MKPolygon`（风圈）。
//
//  ── 为什么用 UIViewRepresentable 而非 SwiftUI `Map` ────────────────
//  与 `RadarMapCard` 同款理由（见该文件头）：`MKPolyline` / `MKPolygon` 必须经
//  `MKMapView.addOverlay(_:level:)` 注册，并由 `MKMapViewDelegate` 的
//  `rendererFor` 提供渲染器。SwiftUI `Map` + `MapOverlay` 承载不了这条
//  delegate 链（覆盖层的 `rendererFor` 是我们区分「实况线/ 预报线 / 风圈」
//  并各配一套样式的唯一途径）。
//  （MapKit 只在本文件与 `RadarMapCard` 出现，`Core/` 保持零 MapKit 依赖。）
//
//  ── 🔴 为什么**必须**用矢量而不是瓦片 ────────────────────────────────
//  台风路径是一条随时间变化的**折线**，雷达瓦片是固定分辨率的**位图**。
//  用瓦片画线的问题：
//  ① 缩小到一定层级后线会因瓦片分辨率不足而**消失或断折**；
//  ② 换台风需要重新取瓦片，而瓦片服务**并不提供「任意折线」这一图层**
//     （实测 RainViewer 只给回波位图；台风网更是**没有任何瓦片服务**）。
//  `MKPolyline` / `MKPolygon` 是矢量覆盖物：任意缩放都平滑、换台风零请求。
//
//  ── 🔴 坐标序：经度在前 ───────────────────────────────────────────
//  `TyphoonTrackPoint.longitude` / `.latitude` 的取值语义由
//  `NmcTyphoonMapper.resolveLongitudeLatitude` 保证（实测经度在前，
//  且经JMA 独立交叉验证 —— 见 `Typhoon.swift` 头）。
//  本文件把它交给 `CLLocationCoordinate2D(latitude:longitude:)` ——
//  ⚠️ **这个初始化器的参数序是「纬度在前」**（MapKit 的约定），
//  与上游数组的「经度在前」是**两回事**。若图省事写成
//  `CLLocationCoordinate2D(latitude: longitude, longitude: latitude)`
//  就把上游已定好的语义又推翻一遍。故此处一律**两行分开写**，
//  并在每处标注谁是谁。
//
//  ── 风圈的诚实处理 ───────────────────────────────────────────────
//  `TyphoonWindCircle.radii` 是 4 个半径但**象限语义无法确定**
//  （实测无法自洽，见该类型注释）。故本文件**只取 `maxRadiusKm` 画一个圆**，
//  **绝不**把 4 个半径当成 4 个象限去拼扇形 —— 那会画出方向错误的图形，
//  而用户在图上看不出错在哪。
//
//  ── 覆盖层种类为什么用**子类**而不是 `title` ──────────────────────
//  `MKOverlay.title` 在协议里是**只读**（`var title: String? { get }`），
//  直接赋值**编译不过**。故用三个 `MKPolyline` / `MKPolygon` 子类做类型标记，
//  由 delegate 用 `as?` 分派 —— 编译期即可保证分派正确。
//
//  ── 许可（硬要求，非可选）────────────────────────────────────────
//  与 `RadarMapCard` 同款：中央气象台要求显示署名 → 本卡固定显示
//  "台风数据 by 中央气象台台风网" + 可点链接（CC BY 4.0 署名义务）。
//

import SwiftUI
import CoreLocation
import MapKit
// `UIEdgeInsets` 属**UIKit**，SwiftUI / MapKit 都不保证 re-export
// （同款判断见 `RadarMapCard.swift` 文件头）→ 必须显式引入。
import UIKit

// MARK: - 覆盖层子类（类型标记）

/// 实况轨迹线。
final class TyphoonRealTrackPolyline: MKPolyline {}
/// 官方预报线。
final class TyphoonForecastPolyline: MKPolyline {}
/// 风圈（实测只画最大半径的**圆** —— 象限语义无法确定，见文件头）。
final class TyphoonWindCirclePolygon: MKPolygon {}

// MARK: - 台风路径地图

/// 台风路径地图（实况轨迹 + 官方预报 + 风圈）。
///
/// - Note: 本类型整体标 `@MainActor`（`MKMapView` 是 `UIViewRepresentable`，
///   其 `makeUIView` / `updateUIView` 均在主 actor 上执行）。
@MainActor
struct TyphoonTrackMapView: UIViewRepresentable {

    /// 已解析的台风详情（非nil = 有数据；nil 由外层决定不构造本视图）。
    let track: TyphoonTrack

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        // 台风路径跨越上千公里 → 相机范围比雷达卡宽一个量级。
        map.cameraZoomRange = MKMapView.CameraZoomRange(
            minCenterCoordinateDistance: 100_000,
            maxCenterCoordinateDistance: 40_000_000
        )
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // ⚠️ 换台风必须**重建覆盖层**，不能只 `reloadData()`：
        // 覆盖层集合与台风 id 绑定，重载只会重绘**同一个**台风。
        guard context.coordinator.installedTrackID != track.id else { return }
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)

        // ① 实况轨迹线。
        var realTrackCoordinates: [CLLocationCoordinate2D] = []
        for point in track.points {
            guard let latitude = point.latitude, let longitude = point.longitude else {
                continue
            }
            realTrackCoordinates.append(
                CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        }
        if realTrackCoordinates.count >= 2 {
            let polyline = TyphoonRealTrackPolyline(
                coordinates: realTrackCoordinates, count: realTrackCoordinates.count)
            map.addOverlay(polyline, level: .aboveRoads)
        }

        // ② 官方预报线（BABJ；实测时效逐条可选、**数量不固定**：可能是 8 个
        //    也可能只剩 1 个，故不按固定长度取）。
        var forecastCoordinates: [CLLocationCoordinate2D] = []
        // 预报线的起点接在**最新实况点**（预报是"从当前位置出发"的预报）。
        if let latest = track.latestPoint {
            if let coordinate = mapCoordinate(of: latest) {
                forecastCoordinates.append(coordinate)
            }
        }
        for point in track.latestForecast {
            guard let latitude = point.latitude, let longitude = point.longitude else {
                continue
            }
            forecastCoordinates.append(
                CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        }
        if forecastCoordinates.count >= 2 {
            let polyline = TyphoonForecastPolyline(
                coordinates: forecastCoordinates, count: forecastCoordinates.count)
            map.addOverlay(polyline, level: .aboveRoads)
        }

        // ③ 风圈（实测每点最多 3 层：七级 / 十级 / 十二级）。
        //    ⚠️ 只取**最新点**（当前风圈），且只用 `maxRadiusKm` 画**圆**。
        if let latest = track.latestPoint,
           let center = mapCoordinate(of: latest),
           let radiusKm = latest.windCircles.compactMap(\.maxRadiusKm).max(),
           radiusKm > 0 {
            // ⚠️ 上游风圈半径单位是**公里** → 必须 × 1000 换成米。
            //
            // ⚠️ **`MKPolygon` 没有 `init(center:radius:sides:)`**（也没有同名类方法）——
            // 逐页核对 Apple 官方文档确认：「Creating a polygon overlay」只有
            // `init(points:count:)` / `init(coordinates:count:)` 两族。
            // 原代码写的 `TyphoonWindCirclePolygon(center:radius:)` 编译不过：
            // `error: argument passed to call that takes no arguments`。
            // 故此处自家按**正多边形**算顶点（半径数百公里，64 边形近似圆的误差可忽略）。
            let circle = Self.circleCoordinates(center: center,
                                                radiusMeters: radiusKm * 1000,
                                                sides: 64)
            let polygon = TyphoonWindCirclePolygon(coordinates: circle, count: circle.count)
            map.addOverlay(polygon, level: .aboveRoads)
        }

        // ④ 最新位置标注（**只有一个点时也要标** —— 那是台风当前位置）。
        if let latest = track.latestPoint,
           let coordinate = mapCoordinate(of: latest) {
            let annotation = MKPointAnnotation()
            annotation.coordinate = coordinate
            annotation.title = track.summary.displayName
            map.addAnnotation(annotation)
        }

        // ⑤ 取景：把整条轨迹**连同预报**框进视野。
        var allCoordinates = realTrackCoordinates
        allCoordinates.append(contentsOf: forecastCoordinates)
        if allCoordinates.count >= 2 {
            map.setVisibleMapRect(
                boundingMapRect(of: allCoordinates),
                edgePadding: UIEdgeInsets(top: 32, left: 32, bottom: 32, right: 32),
                animated: false)
        } else if let only = allCoordinates.first {
            // 只有一个点 → 无从框选，退回以该点为中心（**不显示空白地球**）。
            map.setRegion(MKCoordinateRegion(center: only,
                                             latitudinalMeters: 800_000,
                                             longitudinalMeters: 800_000),
                          animated: false)
        }

        context.coordinator.installedTrackID = track.id
    }

    // MARK: - 取景辅助

    /// 路径点 → 地图坐标。
    ///
    /// ⚠️ `CLLocationCoordinate2D` 的参数序是 **(latitude, longitude)**
    /// （MapKit 约定），与上游数组「经度在前」是两回事 —— 此处逐字对应，
    /// 不要把两个实参对调。
    private func mapCoordinate(of point: TyphoonTrackPoint) -> CLLocationCoordinate2D? {
        guard let latitude = point.latitude, let longitude = point.longitude else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// 一组坐标的外接矩形（**自己求并集**，不依赖任何 MapKit 便捷 API）。
    ///
    /// ⚠️ 这里此前写的是 `MKMapPoint(coord).mapRect(using: .longitudeLatitude)` ——
    /// **`MKMapPoint` 没有 `mapRect` 成员**，`.longitudeLatitude` 也不是任何类型上
    /// 存在的符号（2026-10-08 逐页核对 Apple 官方文档确认，属编造 API）。
    /// 站得住的做法是：把坐标转 `MKMapPoint`，各造一个**零尺寸** `MKMapRect`，再 `union` 求并集。
    private func boundingMapRect(of coordinates: [CLLocationCoordinate2D]) -> MKMapRect {
        guard let first = coordinates.first else { return MKMapRect.world }
        var rect = MKMapRect(origin: MKMapPoint(first), size: MKMapSize(width: 0, height: 0))
        for coordinate in coordinates.dropFirst() {
            let pointRect = MKMapRect(origin: MKMapPoint(coordinate),
                                      size: MKMapSize(width: 0, height: 0))
            rect = rect.union(pointRect)
        }
        return rect
    }

    /// 以 `center` 为圆心、`radiusMeters` 为半径的正多边形顶点（单位：度）。
    ///
    /// ⚠️ **为什么自己算顶点**：`MKPolygon` 只有
    /// `init(points:count:)` / `init(coordinates:count:)` 两族，**没有**
    /// `init(center:radius:sides:)`，也没有同名类方法（逐页核对 Apple 文档）。
    /// （`center:radius:` 那个初始化器是 **`MKCircle`** 的 —— 容易被误记到 `MKPolygon` 上。）
    ///
    /// 用**等距圆柱近似**把米折成度：
    /// - 纬度：`1° ≈ 111_320 m`（常数）。
    /// - 经度：同样米数在经度方向占的度数随纬度收缩，故除以 `cos(latitude)`。
    ///
    /// 台风风圈半径达数百公里，多边形近似圆的形状误差远小于风圈本身的不确定性，
    /// 故不做任何球面精确投影，也**不做坐标纠偏** —— 风圈是气象意义的圆，
    /// 不是「地图上看起来圆」。
    ///
    /// - Returns: 逆时针均匀分布的顶点，闭口由 `MKPolygon` 自动完成（首尾自动相连）。
    private static func circleCoordinates(center: CLLocationCoordinate2D,
                                          radiusMeters: CLLocationDistance,
                                          sides: Int) -> [CLLocationCoordinate2D] {
        let earthRadius = 6_378_137.0  // WGS-84 赤道半径（米）
        let latitudeRadians = center.latitude * .pi / 180
        let latitudeDelta = (radiusMeters / earthRadius) * 180 / .pi
        // 高纬处 cos → 0；加下限避免经度跨度爆炸（画成环绕地球的条带）。
        let longitudeDelta = latitudeDelta / max(cos(latitudeRadians), 0.01)
        return (0..<sides).map { index in
            let angle = 2 * Double.pi * Double(index) / Double(sides)
            return CLLocationCoordinate2D(
                latitude: center.latitude + latitudeDelta * cos(angle),
                longitude: center.longitude + longitudeDelta * sin(angle))
        }
    }

    /// 渲染器工厂。
    final class Coordinator: NSObject, MKMapViewDelegate {

        /// 已装上的台风 id（换台风 → 重建覆盖层）。
        var installedTrackID: String?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            // ⚠️ 按**子类**分派（`MKOverlay.title` 是只读，不能用来打标记）。
            if let polyline = overlay as? TyphoonRealTrackPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor.systemRed
                renderer.lineWidth = 3
                return renderer
            }
            if let polyline = overlay as? TyphoonForecastPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                // 预报线：橙色 + 虚线，与实况（红色实线）**视觉可区分**。
                renderer.strokeColor = UIColor.systemOrange
                renderer.lineWidth = 2
                renderer.lineDashPattern = [6, 4]
                return renderer
            }
            if let polygon = overlay as? TyphoonWindCirclePolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.strokeColor = UIColor.systemYellow
                renderer.fillColor = UIColor.systemYellow.withAlphaComponent(0.15)
                renderer.lineWidth = 1
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - 地图卡片外壳（含署名）

/// 台风路径卡（地图 + 署名）。
///
/// ⚠️ **空态由外层（`TyphoonCardView`）负责**：本视图只在 `track` 非 nil 时
/// 被构造 ——「没有台风」与「取不到台风」都必须由外层**如实显示文字**，
/// 绝不靠「地图空白」来表达（空白地图会被读成"图加载不出来"）。
///
/// ⚠️ 类型级 `@MainActor`：本仓纪律（每个 `struct ... : View` 都带），
/// 且它内部构造 `@MainActor` 的 `TyphoonTrackMapView`。
@MainActor
struct TyphoonMapCard: View {

    /// 已解析的台风详情。
    let track: TyphoonTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TyphoonTrackMapView(track: track)
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius,
                                            style: .continuous))
            attribution
        }
    }

    /// 署名行（**CC BY 4.0 硬要求**：必须给出可追溯出处）。
    ///
    /// ⚠️ 与 `RainViewerService` 的署名同款处理：来源要**显示在数据旁边**。
    /// 只写在设置页的「数据来源」里不足以满足"giving appropriate credit"
    /// 的直观性要求（用户看地图时应当知道这是谁的数据）。
    private var attribution: some View {
        HStack(spacing: 4) {
            Image(systemName: "cloud")
                .font(.system(size: Theme.FontSize.footnote))
            // ⚠️ 链接地址取自 `NmcTyphoonEndpoint.websiteURLString`（单一真源）；
            // 解析失败时**如实显示来源名**而不是隐藏整行（隐藏 = 无署名）。
            if let url = URL(string: NmcTyphoonEndpoint.websiteURLString) {
                Link("台风数据 by 中央气象台台风网", destination: url)
                    .font(.system(size: Theme.FontSize.footnote))
            } else {
                Text("台风数据 by 中央气象台台风网")
                    .font(.system(size: Theme.FontSize.footnote))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.secondaryText)
    }
}
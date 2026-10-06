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
//  ── 许可（硬要求，非可选）─────────────────────────────────────────────
//  RainViewer 要求显示署名：本卡**左下角**固定显示
//  "Weather data by RainViewer" + 指向 rainviewer.com 的链接。
//

import SwiftUI
import MapKit
// `CLLocationCoordinate2D` 显式引入：MapKit 虽会连带 CoreLocation，
// 但不保证 Swift 侧可见（模块 re-export 不是语言保证）。显式引入零成本。
import CoreLocation

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
    }

    /// 纠偏后的瓦片请求坐标。
    ///
    /// 纠偏的落点（真机验证前是**未确认假设**）：
    /// 把 MapKit 要的瓦片中心点（`MKTileOverlayPath` → WGS84 经纬度）
    /// 正向纠偏到 GCJ-02，再换算回瓦片索引 → 即"反向纠偏请求索引"。
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

// MARK: - MKMapView 包装

/// `MKMapView` 的 SwiftUI 包装（承载 `MKTileOverlay` 的唯一途径）。
struct RadarMapView: UIViewRepresentable {

    /// 当前要显示的帧路径；nil = 不叠回波。
    let framePath: String?
    /// 瓦片宿主。
    let host: String
    /// 纠偏模式。
    let mode: CoordinateTransformMode
    /// 缓存。
    let cache: RadarTileCache
    /// 地图中心（选中城市）。
    let center: CLLocationCoordinate2D

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        // 双保险：覆盖层已设 maximumZ，相机范围再夹一层（R5）。
        // minCenterCoordinateDistance ≈ z4，maxCenterCoordinateDistance ≈ z6。
        map.cameraZoomRange = MKMapView.CameraZoomRange(
            minCenterCoordinateDistance: 200_000,
            maxCenterCoordinateDistance: 24_000_000
        )
        map.setRegion(MKCoordinateRegion(center: center,
                                         latitudinalMeters: 800_000,
                                         longitudinalMeters: 800_000),
                      animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // ⚠️ **换帧必须重建 overlay，不能只 `reloadData()`**：
        // `framePath` 与纠偏模式都是 overlay 的不可变初值，`reloadData()` 只会用
        // **同一个** framePath 重新取瓦片 —— 那样时间轴滑动会"看起来在动、底图不变"。
        // 判据：帧路径**或**纠偏模式任一变化 → 换实例。
        let needsRebuild = context.coordinator.installedFramePath != framePath
            || context.coordinator.installedMode != mode
        guard needsRebuild else { return }
        map.removeOverlays(map.overlays)
        if let framePath {
            let overlay = RadarTileOverlay(host: host,
                                           framePath: framePath,
                                           mode: mode,
                                           cache: cache)
            map.addOverlay(overlay, level: .aboveRoads)
        }
        context.coordinator.installedFramePath = framePath
        context.coordinator.installedMode = mode
    }

    /// 渲染器工厂。
    final class Coordinator: NSObject, MKMapViewDelegate {
        /// 当前已装上的帧路径（nil = 无回波层）。
        var installedFramePath: String?

        /// 当前已装上的纠偏模式。
        var installedMode: CoordinateTransformMode?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tileOverlay)
                // `.loadBeforeDisplay`：瓦片中位数仅 ~4 KB，预加载成本可接受；
                // `.loadAsync` 会让拖动时出现空白格子闪烁，对天气图观感伤害大。
                renderer.loadingPolicy = .loadBeforeDisplay
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - 雷达卡

/// 降水雷达卡（含降级四态）。
@MainActor
struct RadarMapCard: View {

    /// 降级态（由调用方经 `RadarAvailability.resolve` 裁定，本视图不自行判定）。
    let availability: RadarAvailability

    /// 时间轴；nil = 无有效帧（对应非 `.radar` 态，scrubber 禁用）。
    let timeline: RadarTimeline?

    /// 瓦片宿主。
    let host: String

    /// 纠偏模式（R1 开关；设置页可改）。
    let mode: CoordinateTransformMode

    /// 缓存。
    let cache: RadarTileCache

    /// 地图中心。
    let center: CLLocationCoordinate2D

    /// 时刻渲染时区（D-4 一致性）。
    var timeZone: TimeZone = .current

    /// 回放选中帧（受控：由本视图的 scrubber 写入）。
    @State private var selectedIndex: Int?

    /// 地图高度（pt）。
    private let mapHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            mapArea
            if availability.allowsScrubbing, let timeline {
                timelineBar(timeline)
            }
            if let note = delayNote(timeline) {
                Text(note)
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(Theme.divider, lineWidth: 0.5)
        )
    }

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
        }
    }

    // MARK: - 地图区（**四态都不为空**）

    private var mapArea: some View {
        ZStack(alignment: .bottomLeading) {
            RadarMapView(
                framePath: currentFramePath,
                host: host,
                mode: mode,
                cache: cache,
                center: center
            )
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

    /// 非 `.radar` 态在地图上的补充说明（`.radar` 态 → nil，不占位）。
    private var degradedOverlayText: String? {
        switch availability {
        case .radar: return nil
        case .forecast(let kind):
            return kind == .domesticHourly ? "回波暂缺 · 见下方逐时概率" : "境外区域 · 见下方 2 小时概率条"
        case .radarUnavailable(let reason):
            return reason.allowsRetry ? "加载失败 · 可下拉重试" : reason.headline
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

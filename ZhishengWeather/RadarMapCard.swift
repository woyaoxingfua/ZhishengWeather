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
        // `.loadBeforeDisplay`：瓦片中位数仅 ~4 KB，预加载成本可接受；
        // `.loadAsync` 会让拖动时出现空白格子闪烁，对天气图观感伤害大。
        //
        // ⚠️ `loadingPolicy` 声明在 **MKTileOverlay** 上，**不在**
        // `MKTileOverlayRenderer` 上 —— 设到 renderer 上编译不过。
        loadingPolicy = .loadBeforeDisplay
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
                // 注意：`loadingPolicy` 是在 `RadarTileOverlay.init` 里设的
                // （它属于 MKTileOverlay，不属于 renderer）。这里只造 renderer。
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            return MKOverlayRenderer(overlay: overlay)
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

    /// 地图高度（pt）。
    private let mapHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            mapArea
            if availability.allowsScrubbing, let timeline {
                timelineBar(timeline)
            }
            // `delayNote` 是 `@ViewBuilder -> some View`（内部自行判空并用
            // TimelineView 更新），**不是** Optional —— 用 `if let` 解它会
            // 让 `note` 变成 `some View`，而 `Text(_:)` 要的是 StringProtocol。
            delayNote(timeline)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(Theme.divider, lineWidth: 0.5)
        )
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
                    cache: model.tileCache,
                    center: model.center.mapCoordinate
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

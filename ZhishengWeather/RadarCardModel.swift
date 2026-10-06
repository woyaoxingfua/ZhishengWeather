//
//  RadarCardModel.swift
//  ZhishengWeather（主 App target）
//
//  雷达卡的主屏状态容器（`@Observable` + `@MainActor`）—— 与既有的
//  `SourceAttributionCoordinator` **同款**（`ContentView` 以 `@StateObject` 持有、
//  由 `.task(id: 城市 id)` 驱动），**不引入第二个刷新生命周期**。
//
//  ── 为什么独立于 `WeatherViewModel` ────────────────────────────────────
//  雷达是**第四条独立链路**（独立域名 + 独立失败域），失败只该写自己的状态。
//  塞进主 VM 会碰到两个问题：① 主 VM 正在被别的 worker 改动 → 冲突风险；
//  ② 雷达失败会污染主 `state` → 违反本仓「失败隔离」纪律。
//  故独立成类型，主屏只消费它的**派生四态**。
//
//  ── 城市来源：复用既有真源，绝不新建第二套 ──────────────────────────────
//  坐标取 `viewModel.directory.selectedCity`（"当前位置"项则用 VM 已解析的
//  `location` 覆盖，与 `WeatherViewModel` 自身取 `latitude/longitude` 的口径一致）。
//  本类型**只接收**坐标，不自己去查城市。
//
//  ── 纠偏偏好：单一真源 ────────────────────────────────────────────────
//  读 `RadarCoordinateModeStore.current()`（与 SettingsView 的 Picker **同一份**
//  App 本地偏好）。切档后由 `reload()` 重跑 `makeOverlay()` 重建覆盖层 → 立即生效。
//
//  Core 纪律：本文件在 App target，可 import MapKit；但**不含**任何取数/判据逻辑
//  （那些都在 Core/ 的纯函数里），本文件只做「状态 + 生命周期」。
//

import Foundation
import CoreLocation
import Observation

/// 雷达卡主屏状态。
@MainActor
@Observable
final class RadarCardModel {

    // MARK: - 对外状态

    /// 时间轴；nil = 无有效帧。
    private(set) var timeline: RadarTimeline?

    /// 覆盖态（基础设施事实，只探一次）。
    private(set) var coverage: RadarCoverage = .unknown

    /// 取数是否失败。
    private(set) var fetchFailed: Bool = false

    /// 是否正在首次加载（**只用于显示"正在加载"，不参与四态判定**）。
    private(set) var isLoading: Bool = false

    // ⚠️ `currentCityID` 的声明在**本文件下方**（`var currentCityID: String?`），
    // 不要在这里再加一个 —— 2026-10-06 曾因 grep 模式漏看 `var` 与 `private(set) var`
    // 的区别而重复声明，CI 报 `invalid redeclaration`（run 37463237543）。
    // 教训：**grep 到"一处声明"不等于"只有一处声明"**，加属性前要 grep 裸符号名。

    /// 加载是否已超时（秒）。
    ///
    /// ⚠️ **必须有超时兜底**：取数卡住时若一直转圈，用户看到的就是
    /// 「转圈卡死」—— 那是最容易被当成"功能正常只是慢"的失败态。
    /// 超时后 `hasTimedOut` 为 true，卡片改显"加载超时 · 已显示底图"，
    /// **底图与模型概率照常可用**（绝不空白）。
    static let loadTimeout: TimeInterval = 12

    /// 本次加载是否已超时。
    ///
    /// 判定式是 `Date().timeIntervalSince(now) > loadTimeout`（见 `load` 末尾）：
    /// `now` 是本次加载的**起点**（由调用方注入，单测可固定），
    /// `Date()` 取**完成时刻**，两者之差即真实耗时。
    ///
    /// ⚠️ 此处**必须**读完成时刻，不能用"注入的 now 自己减自己"
    /// ——那样永远等于 0、超时分支永不触发，正是本条要防的"转圈卡死"。
    /// App 侧调 `Date()` 是本仓既有惯例（如 `WeatherViewModel` 同样直接调）。
    private(set) var hasTimedOut: Bool = false

    /// 瓦片宿主（取自元数据）。
    private(set) var host: String = RadarTileURLBuilder.defaultHost

    /// 纠偏模式（**每次渲染都从偏好真源读**，不缓存副本）。
    ///
    /// ⚠️ 为什么是计算属性而不是 `@State` 副本：副本会在设置页改档后
    /// **滞留旧值**，表现为"切了档、回到主屏没变化"——正是 R1 验证时
    /// 最会让人误判"纠偏代码没生效"的一种假象。
    /// 计算属性 + `UserDefaults` 直读 → 设置页写完即生效（下次渲染即读新值）。
    var coordinateMode: CoordinateTransformMode {
        RadarCoordinateModeStore.current()
    }

    /// 地图中心（WGS84，来自选中城市）。
    private(set) var center: CLLocationCoordinate2Like = .beijing

    /// 瓦片缓存（与覆盖层共享同一实例，故切帧时缓存仍命中）。
    let tileCache: RadarTileCache = RadarTileCache()

    // MARK: - 依赖

    private let service: RainViewerService
    private let coverageService: RadarCoverageService

    /// PNG → RGBA 字节的解码器（**由 App 侧注入**）。
    ///
    /// 为什么不在 Core 里解码：Core/ 被主 App 与 Widget 两个 target 编译，
    /// 而 PNG 解码要 CoreGraphics —— SC-12 的 Core import 白名单不含它。
    /// 故「取字节 + 判读」在 Core，「解码」在 App，通过闭包注入。
    private let pngDecoder: @Sendable (Data) -> [UInt8]?

    // MARK: - 派生四态（**主屏消费这个，不自己判**）

    /// 当前降级四态。
    ///
    /// - `.notCovered` 覆盖 → `.radarUnavailable(.noEchoCoverage)`（服务盲区）；
    /// - 其余按 `RadarAvailability.resolve` 的既定顺序（取数失败优先）。
    var availability: RadarAvailability {
        if coverage.shouldSkipTileRequests {
            return .radarUnavailable(.noEchoCoverage)
        }
        return RadarAvailability.resolve(timeline: timeline,
                                         isOverseas: isOverseas,
                                         fetchFailed: fetchFailed)
    }

    /// 该坐标是否在中国境外（**唯一**的境外判定入口，主屏与卡片共用）。
    ///
    /// ⚠️ 复用 `CoordinateTransform.isInsideChinaBox` —— 即"是否需要 GCJ-02 纠偏"
    /// 那个判据。两者**必须**同源：若此处另写一套，会出现"境内显示回波、却按境外
    /// 不纠偏"这类自相矛盾（纠偏错 → 几百米错位）。
    private var isOverseas: Bool {
        !CoordinateTransform.isInsideChinaBox(longitude: center.longitude,
                                              latitude: center.latitude)
    }

    /// 是否应当让覆盖层去请求瓦片。
    ///
    /// **这是"内陆城市不请求"需求的正确落点** —— 判据是**覆盖**（地理/基础设施事实），
    /// 不是"内陆"（把天气当地理用，实测已证伪）。故：
    /// 只有真正的服务盲区才跳过；天气性无回波**照常请求**，
    /// 由 `availability` 走 `.radarUnavailable(.noEchoCoverage)` 显式说明。
    var shouldRequestTiles: Bool {
        availability.showsRadarTiles
    }

    // MARK: - 构造

    init(service: RainViewerService = RainViewerService(),
         coverageService: RadarCoverageService = RadarCoverageService(),
         pngDecoder: @escaping @Sendable (Data) -> [UInt8]? = RadarPNGDecoder.decodeRGBA) {
        self.service = service
        self.coverageService = coverageService
        self.pngDecoder = pngDecoder
    }

    // MARK: - 生命周期

    /// 主屏 `.task(id: 城市 id)` 调用。
    ///
    /// - Parameters:
    ///   - cityID: 城市稳定标识（用于 `.task(id:)` 去重 / 切城重载）。
    ///   - latitude: 选中城市纬度（WGS84，来自既有真源）。
    ///   - longitude: 选中城市经度（WGS84）。
    ///   - now: 当前时刻（**注入**，便于单测断言超时判定）。
    func load(cityID: String, latitude: Double, longitude: Double,
              now: Date = Date()) async {
        // 切城先清空：否则旧城的帧会短暂出现在新城的地图上（串号）。
        timeline = nil
        fetchFailed = false
        hasTimedOut = false
        currentCityID = cityID
        center = CLLocationCoordinate2Like(latitude: latitude, longitude: longitude)
        isLoading = true
        defer { isLoading = false }

        // 覆盖探测与元数据取数**并发**：二者互不依赖，串行会白等一轮 RTT。
        async let coverageResult = coverageService.coverage(latitude: latitude,
                                                             longitude: longitude,
                                                             decoder: pngDecoder)
        do {
            let loaded = try await service.fetchTimeline()
            // 切城守卫：结果回来时若已切到别的城市，丢弃本结果。
            guard currentCityID == cityID else { return }
            timeline = loaded
            fetchFailed = false
        } catch is CancellationError {
            return
        } catch {
            guard currentCityID == cityID else { return }
            timeline = nil
            fetchFailed = true
        }
        let resolvedCoverage = await coverageResult
        // 切城守卫（覆盖结果同样要复核）。
        guard currentCityID == cityID else { return }
        coverage = resolvedCoverage
        // 超时兜底：即便取数"成功"返回了，超过预算也如实标为超时
        // （宁可说"慢"，也不要让转圈停不下来）。
        hasTimedOut = Date().timeIntervalSince(now) > Self.loadTimeout
    }

    /// 当前城市 id（由主屏写入，仅用于上面的切城守卫）。
    ///
    /// **防串号的唯一守卫**：取数是 `async`，用户可能在等 A 城时切到 B 城；
    /// `load` 里写入本值，后到的 A 城结果必须 `guard currentCityID == cityID`
    /// 才能落地，否则会把旧城数据画到新城地图上。
    var currentCityID: String?

    /// 当前应显示的帧路径。
    ///
    /// - Parameter index: 用户选中的帧下标；nil = 取最新帧（实况）。
    /// - Returns: 帧路径；**非 `.radar` 态 / 无有效帧 / 下标越界 → nil**
    ///   （nil 表示"不叠回波层"，地图仍显示底图 —— 不是空白页）。
    func currentFramePath(index: Int?) -> String? {
        guard let timeline, availability.showsRadarTiles else { return nil }
        guard let frame = timeline.frame(at: index) else { return nil }
        return frame.path
    }
}

// MARK: - 轻量坐标值类型

/// 坐标值类型（`@Observable` 里存 `CLLocationCoordinate2D` 需另找 Equatable，
/// 故用本值类型 + 在视图层转成 `CLLocationCoordinate2D`）。
///
/// 为什么不用 `CLLocationCoordinate2D` 直接存：它是 C 结构体、`@Observable`
/// 的属性观察需要值语义可比较；用本类型可 `Equatable`，切城时能可靠判定"变了"。
struct CLLocationCoordinate2Like: Equatable, Sendable {

    /// 纬度（WGS84）。
    let latitude: Double
    /// 经度（WGS84）。
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// 北京（复用既有默认城市常量，不引入第二套默认坐标）。
    static let beijing = CLLocationCoordinate2Like(latitude: 39.9090, longitude: 116.3970)

    /// → MapKit / CoreLocation 坐标（App 侧唯一转换点）。
    /// ⚠️ 类型名是 **`CLLocationCoordinate2D`**（带尾 D）；曾误写成
    /// `CLLocationCoordinate2`（无尾 D，那不是任何真实类型），CI 报
    /// `cannot find type` （run 37460108230）。
    var mapCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

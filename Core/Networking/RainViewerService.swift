//
//  RainViewerService.swift
//  Core / Networking  [App + Widget 共用]
//
//  RainViewer 降水雷达：元数据取数 + 瓦片 URL 拼装 + 瓦片缓存（TTL/LRU/并发上限）。
//
//  ══════════════════════════════════════════════════════════════════════════
//  ⚠️⚠️ 三条实测基线（2026-10-06 独立复核，逐条附硬证据；**不要凭文档改回去**）
//  ══════════════════════════════════════════════════════════════════════════
//
//  ① 瓦片 URL 模板：**`{path}/{size}/{z}/{x}/{y}/{color}/{options}.png`**
//     —— `size` 必须在 `{z}` **之前**。
//     实测（同一张北京 z5 瓦片，两种拼法并排比对）：
//       · size 在前 → HTTP 200 / 536 B / 256×256 / 14 种可见颜色 / 非灰阶 = **真回波**
//       · size 在后 → HTTP 200 / 1370 B / 256×256 / 可见像素**全灰阶**
//                    / coverage=0.2033 → 与 z8 占位图 **md5 完全相同**
//                    （`2cc6649e1f2e…`）= 服务端静默返回 "Zoom Level Not Supported"
//     ⚠️ 错模板**不报错**（HTTP 200 + 合法 PNG），只会静默给灰图 ——
//        所以下面 `RadarTile` 的 PNG 头校验之外，还需灰阶占位图识别（见 TileCache）。
//
//  ② 真实最大 zoom = **7**（不是 5）。实测 z8 / z9 / z10 全球多点（北京/伦敦/东京）
//     **全部**返回 1370 B、md5 恒为 `2cc6649e1f2e…` 的同一张灰阶占位图；
//     z7 抽样 28 张仍有真回波（如 (21,41)=5515 B/48 色、(69,31)=18592 B/43 色）。
//     → 一律钳制到 `RadarTileZoomRange`，z8 绝不外泄（否则用户看到灰图 +
//        "Zoom Level Not Supported" 字样）。
//
//  ③ 投影 = **标准 EPSG:3857 Web Mercator / XYZ**（非 TMS），故
//     `isGeometryFlipped = false`，且纠偏**只能在请求侧做**（见 CoordinateTransform）。
//
//  ── 免 Key ────────────────────────────────────────────────────────────
//  RainViewer **不需要任何凭据**（实测 `weather-maps.json` 直接 200）。
//  故本链路**不得**引入 Keychain / 凭据读取 —— 静态守卫 SC-42a 会扫 Core/。
//
//  ── 配额实测 ──────────────────────────────────────────────────────────
//  · **12 并发会被掐**（大量连接被切、返回非 PNG）；
//  · **≤4 并发 + 最小间隔 0.12 s 稳定** → 故 `maxConcurrentRequests = 4`。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//  （瓦片图层的 MapKit 封装在 App 侧 `RadarMapCard.swift`，不进 Core。）
//

import Foundation

// MARK: - Zoom 钳制

/// 雷达瓦片的 zoom 钳制范围。
///
/// **下限 4 的理由**：z4 地面分辨率 ≈ 7505 m/px，一屏能覆盖半个中国，
/// 再低（z3 及以下）回波块已被插值得毫无对流结构，信息量为零。
/// **上限 7 的理由**：实测 z8 起返回 1370 B 灰阶占位图（md5 恒定），
/// 放大到 z8 用户会看到写着 "Zoom Level Not Supported" 的灰图 —— 绝不容许。
struct RadarTileZoomRange {

    /// 最小 zoom（含）。
    static let minimum = 4

    /// 最大 zoom（含）。**实测上界**，不得擅自调大。
    static let maximum = 7

    /// 任意 zoom 钳制到 `[minimum, maximum]`。
    ///
    /// 这是"占位图永不外泄"的**唯一**闸口 —— 即使 MapKit 违反 `maximumZ`
    /// 送来 z8+，请求也会被夹回 z7。
    ///
    /// - Parameter zoom: 原始 zoom。
    /// - Returns: 钳制后的 zoom。
    static func clamp(_ zoom: Int) -> Int {
        min(max(zoom, minimum), maximum)
    }

    /// 该 zoom 是否会触发服务端占位图（实测：≥ 8 会）。
    static func isPlaceholderZoom(_ zoom: Int) -> Bool {
        zoom > maximum
    }
}

// MARK: - 瓦片 URL 拼装（纯函数，可单测）

/// 瓦片 URL 拼装器。
///
/// **注意 `size` 在 `z` 之前**（见文件头实测①）。这不是笔误，**不要"修正"**。
enum RadarTileURLBuilder {

    /// RainViewer 瓦片宿主（取自 `weather-maps.json` 的 `host` 字段）。
    static let defaultHost = "https://tilecache.rainviewer.com"

    /// 色表 ID。实测 `0`–`9` 全部 200；`4` 为中性色表（不易误读为其它物理量）。
    static let defaultColorScheme = 4

    /// 平滑且不显示雪。`1_0` = 平滑 + 关闭雪图层
    /// （雪单独配色叠加在本仓既有降水语义上会误导用户，故关闭）。
    static let defaultOptions = "1_0"

    /// RainViewer 只接受 256 / 512 两种边长。
    static let tileEdge = 256

    /// 占位图字节长度（实测 z8–z10 恒为 1370 B，md5 `2cc6649e1f2e…`）。
    ///
    /// 用于**识别"服务端静默返回的灰图"** —— 错模板 / 超 zoom 都返回 HTTP 200
    /// + 合法 PNG，**不靠字节数无法察觉**，只会静默给用户一张灰图。
    static let placeholderByteCount = 1370

    /// 拼装单张瓦片 URL。
    ///
    /// - Parameters:
    ///   - host: 瓦片宿主；末尾斜杠会被去掉（避免拼出 `//`）。
    ///   - framePath: 帧路径（形如 `/v2/radar/cc4e98e720b0`）。
    ///   - zoom: 原始 zoom（**内部钳制**，调用方不必各自夹一次）。
    ///   - x: 瓦片列号。
    ///   - y: 瓦片行号（XYZ 约定，非 TMS）。
    ///   - colorScheme: 色表 ID。
    /// - Returns: 合法 URL；参数非法 → nil。
    static func url(host: String = defaultHost,
                    framePath: String,
                    zoom: Int,
                    x: Int,
                    y: Int,
                    colorScheme: Int = defaultColorScheme) -> URL? {
        guard !framePath.isEmpty, x >= 0, y >= 0 else { return nil }
        let root = host.hasSuffix("/") ? String(host.dropLast()) : host
        let z = RadarTileZoomRange.clamp(zoom)
        return URL(string: "\(root)\(framePath)/\(tileEdge)/\(z)/\(x)/\(y)/\(colorScheme)/\(defaultOptions).png")
    }

    /// 缓存键（与 URL 一一对应，但**不把 `framePath` 直接当文件名**：它含 `/`）。
    static func cacheKey(framePath: String, zoom: Int, x: Int, y: Int, colorScheme: Int = defaultColorScheme) -> String {
        "\(framePath)|\(RadarTileZoomRange.clamp(zoom))|\(x)|\(y)|\(colorScheme)"
    }
}

// MARK: - 占位图识别

/// 灰阶占位图识别（**"HTTP 200 但内容是灰图"的唯一防线**）。
enum RadarPlaceholderDetector {

    /// 合法 PNG 魔数（8 字节签名）。
    private static let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// 是否为合法 PNG（用于把"服务端返回 HTML 错误页"挡在缓存外）。
    static func isPNG(_ data: Data) -> Bool {
        guard data.count >= pngMagic.count else { return false }
        return Array(data.prefix(pngMagic.count)) == pngMagic
    }

    /// 是否为"Zoom Level Not Supported"占位图。
    ///
    /// 判据（实测反推）：字节数 == 1370 **且** 是合法 PNG。
    ///
    /// ⚠️ 字节数判据不是契约，只是**当前线上载荷**的指纹；因此本函数只用于
    /// **"不缓存 + 不上屏"**（宁可这一帧失败，也不能给用户灰图），
    /// 一旦 RainViewer 换了占位图，最坏结果是"该帧加载失败"→ 走降级态，
    /// 而**不是**把灰图当正常回波显示。
    ///
    /// - Parameter data: 瓦片字节。
    static func isPlaceholder(_ data: Data) -> Bool {
        isPNG(data) && data.count == RadarTileURLBuilder.placeholderByteCount
    }
}

// MARK: - 缓存 TTL（纯判定，可单测）

/// 缓存新鲜度策略。
///
/// 取值依据（实测）：帧步长 600 s。
///  · JSON TTL = **240 s（4 分钟）**= 步长的一半 —— 避免刚刷新就拿到边缘帧，
///    同时保证 10 分钟粒度下最多滞后半步。
///  · 瓦片 TTL = **1800 s（30 分钟）**= 覆盖 3 帧，回放时不重复回源。
enum RadarCacheTTL {

    /// 元数据 TTL（秒）。
    static let metadata: TimeInterval = 240

    /// 瓦片 TTL（秒）。
    static let tile: TimeInterval = 1800

    /// 判定是否仍在 TTL 内。
    ///
    /// 边界裁定：**恰好等于 TTL 视为过期**（严格小于才算新鲜），
    /// 便于边界用例逐点断言（沿用 `StalePolicy.isStale` 的同款口径）。
    ///
    /// - Parameters:
    ///   - storedAt: 写入时刻。
    ///   - now: 当前时刻（**注入**；Core 禁内部 `Date()`）。
    ///   - ttl: TTL 秒数。
    static func isFresh(storedAt: Date, now: Date, ttl: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(storedAt)
        return age >= 0 && age < ttl
    }
}

// MARK: - 缓存容量（实测驱动）

/// 瓦片缓存的容量与并发上限（**全部有实测依据**，非拍脑袋）。
enum RadarTileCachePolicy {

    /// 内存缓存上限：48 MB。
    static let memoryBytes = 48 * 1024 * 1024

    /// 内存缓存条目数上限。
    static let memoryCount = 60

    /// 磁盘缓存上限：64 MB（LRU 淘汰）。
    static let diskBytes = 64 * 1024 * 1024

    /// 并发请求上限：**实测 12 并发会被掐断**，≤4 稳定。
    static let maxConcurrentRequests = 4

    /// 两次请求之间的最小间隔（秒）→ 约 8 req/s 上限。
    static let minimumRequestInterval: TimeInterval = 0.12
}

// MARK: - 元数据响应 DTO

/// `weather-maps.json` 响应（只解构本链路需要的字段）。
///
/// ⚠️ `nowcast` **实测恒为空数组**，但**仍然解码**它 ——
///    解码它是为了**如实反映服务端现状**（万一将来有值，不会静默丢弃），
///    而**不用它**是产品裁定（见 `RadarTimeline` 只吃 past）。
struct RainViewerWeatherMapsResponse: Decodable {

    /// 顶层结构。
    struct Root: Decodable {
        let host: String
        /// `generated` 为 **epoch 秒**（实测 `1791283820`），非 ISO 字符串。
        let generated: Int
        let radar: Radar?
        let satellite: Satellite?
    }

    /// `radar` 块。
    struct Radar: Decodable {
        let past: [Frame]?
        /// 实测恒为 `[]`。保留字段但**不参与**时间轴构造。
        let nowcast: [Frame]?
    }

    /// `satellite` 块（本链路不用，仅避免未知键导致的解码脆弱）。
    struct Satellite: Decodable {
        let infrared: [Frame]?
    }

    /// 单帧。
    struct Frame: Decodable {
        /// UTC epoch 秒。
        let time: Int
        let path: String
    }
}

// MARK: - 取数服务

/// 雷达元数据取数（actor，自带隔离）。
///
/// 只负责元数据；瓦片由 App 侧 `RadarTileOverlay` 经 `RadarTileCache` 拉取
/// （MapKit 的取数回调不在本服务内）。
actor RainViewerService {

    /// 元数据端点（**免 Key、免注册**，实测 200）。
    static let metadataURLString = "https://api.rainviewer.com/public/weather-maps.json"

    private let session: URLSession

    /// 注入 session（测试可换 `URLSessionConfiguration`）。
    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 元数据请求 URL。
    static func metadataURL() -> URL? {
        URL(string: metadataURLString)
    }

    /// 拉取元数据并构造时间轴。
    ///
    /// ⚠️ **不接收 `now`**：本方法不做任何"相对当前时刻"的判断
    /// （时间轴的年龄由调用方用注入的 `now` 自行计算），故不需要时钟。
    /// 保留一个用不到的参数只会诱使后来者在里面偷偷调 `Date()`。
    ///
    /// - Returns: 时间轴；**无一有效帧 → 抛 `.dataMissing`**（调用方据此降级，
    ///            绝不渲染空 scrubber）。
    /// - Throws: `WeatherError.badURL` / `.network` / `.badStatus` / `.decodingDetail` / `.dataMissing`。
    func fetchTimeline() async throws -> RadarTimeline {
        guard let url = Self.metadataURL() else { throw WeatherError.badURL }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw WeatherError.timeout(urlError.localizedDescription)
        } catch {
            throw WeatherError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw WeatherError.network("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WeatherError.badStatus(http.statusCode)
        }

        // 统一解码入口（失败携带 codingPath，不静默）。
        let root = try ResponseDecoding.decode(RainViewerWeatherMapsResponse.Root.self, from: data)

        // ⚠️ **只取 past**；`nowcast` 实测恒空，不参与（硬要求）。
        let past = root.radar?.past ?? []
        let frames = past.map { RadarFrame(epochSeconds: $0.time, path: $0.path) }
        guard let timeline = RadarTimeline.make(from: frames) else {
            // 有响应但零有效帧 —— 这是"无回波"，不是"取数失败"。
            throw WeatherError.dataMissing("radar.past 为空")
        }
        return timeline
    }

    /// 瓦片宿主（取自最近一次元数据；缺省回落到官方默认值）。
    ///
    /// - Parameter root: 已解码的元数据。
    static func host(from root: RainViewerWeatherMapsResponse.Root) -> String {
        root.host.isEmpty ? RadarTileURLBuilder.defaultHost : root.host
    }

    /// 元数据的新鲜度参考时刻（`generated`，epoch 秒）。
    ///
    /// 暴露出来是为了让"数据延迟"文案有个**真实**依据，而不是拿本地 `Date()`
    /// 假装新鲜（Core 禁内部 `Date()`，此处由调用方注入 `now` 做差）。
    static func generatedDate(from root: RainViewerWeatherMapsResponse.Root) -> Date {
        Date(timeIntervalSince1970: Double(root.generated))
    }

    /// 供 App 侧判定"元数据是否已过期需要重取"用。
    static func isMetadataFresh(generated: Date, now: Date) -> Bool {
        RadarCacheTTL.isFresh(storedAt: generated, now: now, ttl: RadarCacheTTL.metadata)
    }
}

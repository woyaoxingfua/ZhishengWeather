# 降水雷达瓦片技术可行性预研（RainViewer + MapKit，iOS 17）

日期：2026-10-03/04　方法：**本机实测**（curl 下载瓦片 + Python 解码验证坐标公式）。
仓库基线：`ios` @ `e7247f9`（注：交办时说的 `9c99a9d` 已过期，实际 HEAD 已在 `e7247f9`）。
探测脚本与原始样本：`_radar-probe/`（仓库外，未污染仓库）。

---

## 0. 结论先行：**能做，但交办 brief 里的三条关键前提全是错的，必须先纠正**

| # | brief 的说法 | 实测结论 | 影响 |
|---|---|---|---|
| 1 | 瓦片 URL = `{path}/{z}/{x}/{y}/{size}/{color}/{options}.png` | ❌ **错**。官方是 **`{path}/{size}/{z}/{x}/{y}/{color}/{options}.png`**（`size` 在最前） | **致命**。用错模板时 z5 也返回占位图，会误判成"z5 才有数据" |
| 2 | zoom 上限 = 5，z6+ 是占位图 | ❌ **错**。实测 **z7 仍有真实回波**，**z8 起才是 `Zoom Level Not Supported`** | 少了两级可用清晰度 |
| 3 | z3/z4/z5 有真实回波 | ⚠️ **巧合正确**。错模板下 z3/z4 的"回波"其实是 z×z 像素的畸形小图（z3=3×3、z4=4×4），不是 256px 瓦片 | 依据错误，结论侥幸正确 |

**一句话**：RainViewer 瓦片是**标准 Web Mercator (EPSG:3857) XYZ**，可直接用 `MKTileOverlay` 叠加，`minimumZ=4 / maximumZ=7`，**中国区存在 266–622 m 的 GCJ-02 错位，必须显式纠偏**。

### 0.1 全球普查佐证「上限 = 7」（z0–z6 全量 + z7–z11 全球抽样，共 5547 张）

| z | 采样 | 载荷构成 |
|---|---|---|
| 0–4 | 341（全量） | 真实回波为主（数百种不同 md5），**无占位图** |
| 5 | 1017（全量） | 866 EMPTY（无降水）+ 151 真实回波 |
| 6 | 4088（全量） | 3121 EMPTY + 908 真实回波 + 658 请求失败（限流，非数据问题） |
| **7** | 49（抽样） | 46 EMPTY + **3 真实回波**（(63,42)=英国、(105,63)=赤道附近） |
| **8–11** | 49 × 4 级 | **全部 49 张都是同一个 md5 `2cc6649e1f`** = 1370 B 灰阶占位图，**无一例外** |

z8–z11 全球采样点**退化成字节级完全相同的单一载荷**（连 `opaque=20.3%` 都一致）——这是占位图的决定性证据，真实回波不可能在世界各处字节相同。z7 则仍有英国上空的真实回波（已导图目视确认，**非北京样本**）。官方文档亦写明 "Maximum zoom level is 7"。

---

## 1. 坐标系实测结论

### 1.1 验证方法（不靠文档推断）

不能只靠"官方说是 XYZ"就下结论——必须用**两条独立的代码路径**互相印证：

- **路径 A（我方算）**：标准 slippy-map 公式算出瓦片 `(x, y)`，去下载该瓦片，数它的回波像素。
- **路径 B（RainViewer 自算）**：用官方另一个端点 `{path}/{size}/{z}/{lat}/{lon}/...`，它返回一张**以该经纬度为中心**的图。这是 RainViewer 内部自己做的投影。

两者独立。若投影真是标准 XYZ，A 和 B 必须在同一地理位置给出同一份回波。

验证公式（`tilemath.py`）：

```
x = floor((lon + 180) / 360 * 2^z)
y = floor((1 - ln(tan φ + sec φ) / π) / 2 * 2^z)
```

北京 (116.4E, 39.9N) 落点：z4=(13,6)、z5=(26,12)、z6=(52,24)、z7=(105,48)。

### 1.2 实测数据

**(a) 一致性检验**：全球 171 个探针点（每 15° 纬 × 20° 经），
- 路径 A 与路径 B 的"有无回波"一致率 **93.6%**（160/171）
- 回波强度 Pearson 相关 **r = 0.808**

**(b) 偏移扫描（决定性）**：把 A 的瓦片索引整体平移 `(dx, dy) ∈ [-3,3]²`，看哪个平移最能匹配 B：

| dx | dy | 一致率 | Pearson r |
|---|---|---|---|
| **0** | **0** | **97.6%** | 0.808 |
| -1 | 0 | 89.7% | 0.851 |
| 0 | +1 | 86.7% | 0.932 |
| 0 | -1 | 84.8% | 0.219 |

**最优平移 = (0,0)** → **标准 XYZ 确认**。

**(c) TMS y 翻转假设否证**：若瓦片实为 TMS（y′ = 2^z−1−y），一致率应上升。实测**从 93.6% 掉到 62.0%** → 排除 TMS。

**(d) 亚像素质心检验**（最强证据）：在 z6 拼 4×4 瓦片算出风暴质心 → 用标准 XYZ 反算得 **lon=117.7396, lat=30.1975**；再请 RainViewer 以 (30.2, 117.74) 为中心出图，回波质心落在图内 **(0.5106, 0.4576)**，即偏离中心 **+0.0106 / −0.0424 个瓦片 = +5.7 km 东 / −22.9 km 北**。在 z6（480 km/瓦片、1876 m/px）下属亚瓦片级误差，与两条路径的取整/渲染差异相符。

> 注：质心检验脚本首版把米误标成千米（×1000 打印错误），实际偏移是 **+5.7 km / −22.9 km**，不是 5738 km。结论方向不变，但数字以本行为准。

### 1.3 结论

- 投影 = **EPSG:3857 Web Mercator**，索引 = **XYZ**（左上原点，非 TMS）。
- `isGeometryFlipped = false`（默认），**不要**设 `true`。
- `tileSize = CGSize(256, 256)`（见 §1.4 关于 retina 的取舍）。
- **不需要任何转换公式**。直接用 `MKTileOverlay` + 标准 XYZ 即可。

### 1.4 retina（`tileSize`）取舍 —— 实测

RainViewer 的 `size=512` **是真实的 2× 渲染，不是把 256 放大**（实测：512 图降采样到 256 后与原生 256 的平均像素差 3.26/255，p95=14；原生 512 的边缘能量 2.85 明显低于"512 降采样"的 6.33，说明 512 携带了 256 没有的真实细节）。

但 Apple 只文档化了 `{z}/{x}/{y}/{scale}` 三个占位符，**没有** `{size}`。MapKit 会依据 `tileSize` 与屏幕 scale 决定 `{scale}` 的值，进而影响 `path.z`（`tileSize=512` 时 MapKit 内部相当于按 512 网格取样）。

**结论：先用 `tileSize = 256` + `size=256` 跑通。** 若真机上雷达回波在 @2x/@3x 上明显发虚，再改 `tileSize = 512` + `size=512`（带宽约 2.8 倍：实测北京 z5 为 8001 B → 22814 B）。**不要在没有对比截图的情况下预先上 512**——回波本身是模糊的色块，256 已经够用。

---

## 2. 可运行的代码骨架

### 2.1 URL 模板（**这是最容易写错的地方**）

官方 Weather Maps API 原文：

```
{path}/{size}/{z}/{x}/{y}/{color}/{options}.png          ← 标准瓦片
{path}/{size}/{z}/{lat}/{lon}/{color}/{options}.png       ← 以某点为中心
```

- `{smooth}_{snow}`：`1_0` = 平滑且不显示雪。**建议 `1_0`**（雪单独配色会在合成图上误导用户）。
- `{color}`：色表 ID。实测 `4` 即可（`0`–`9` 全部返回 200）。
- 覆盖范围瓦片：`/v2/coverage/0/{size}/{z}/{x}/{y}/0/0_0.png`（有覆盖=透明，无覆盖=黑）。

实测对照（同一张北京 z5 瓦片）：

| 模板 | 字节 | 解码结果 |
|---|---|---|
| `.../5/26/12/256/4/1_1.png`（错：z/x/y 在前） | 1370 | 灰阶 `Zoom Level Not Supported` 占位图 |
| `.../256/5/26/12/4/1_1.png`（对：size 在前） | **8001** | **真实回波，71 种颜色** |

### 2.2 覆盖层 + 瓦片源

```swift
import MapKit

/// RainViewer 雷达瓦片覆盖层。
///
/// 关键点 1：URL 模板中 {size} 必须在 {z} 之前，否则服务端返回占位图。
/// 关键点 2：Apple **未文档化** `{size}` 占位符（只文档化了 {z}/{x}/{y}/{scale}），
///           所以这里**不用模板拼 URL**，改为在 `loadTile(at:result:)` 里完全自控。
///           这样也顺带能做缓存、限流、失败回退。
final class RadarTileOverlay: MKTileOverlay {

    /// RainViewer 实测最大 zoom = 7（z8 起返回 "Zoom Level Not Supported"）。
    static let minZoom = 4
    static let maxZoom = 7

    private let host: String
    private let framePath: String
    private let colorScheme: Int
    private let cache: TileCache

    init(host: String,
         framePath: String,          // 形如 "/v2/radar/cc4e98e720b0"
         colorScheme: Int = 4,
         cache: TileCache = .shared) {
        self.host = host.hasSuffix("/") ? String(host.dropLast()) : host
        self.framePath = framePath
        self.colorScheme = colorScheme
        self.cache = cache
        super.init(urlTemplate: nil)   // 不依赖模板
        tileSize = CGSize(width: 256, height: 256)
        isGeometryFlipped = false       // 标准 XYZ，非 TMS
        minimumZ = Self.minZoom
        maximumZ = Self.maxZoom
        canReplaceMapContent = false    // 盖在 Apple 底图之上
    }

    /// 自建 URL。注意 z 也要钳制——即使 MapKit 理论上会遵守 maximumZ，
    /// 防御性夹紧可避免任何 z8 空图漏到用户眼前（风险 R5）。
    private func tileURL(x: Int, y: Int, z: Int) -> URL? {
        let zc = min(max(z, Self.minZoom), Self.maxZoom)
        // size 固定 256（RainViewer 只接受 256 / 512）；options 1_0 = 平滑 + 不显示雪
        return URL(string: "\(host)\(framePath)/256/\(zc)/\(x)/\(y)/\(colorScheme)/1_0.png")
    }

    /// 命中缓存直接回调；否则走网络。**这是限流的唯一入口**，
    /// 因此限流/退避逻辑集中在这里（实测 12 并发会被掐，≤4 并发稳定）。
    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, (any Error)?) -> Void) {
        let z = min(max(path.z, Self.minZoom), Self.maxZoom)
        let key = "\(framePath)/\(z)/\(path.x)/\(path.y)/\(colorScheme)"

        if let data = cache.data(for: key) {
            result(data, nil)
            return
        }
        guard let url = tileURL(x: path.x, y: path.y, z: z) else {
            result(nil, URLError(.badURL))
            return
        }
        cache.load(url: url, key: key) { outcome in
            switch outcome {
            case .success(let data): result(data, nil)
            case .failure(let error):  result(nil, error)
            }
        }
    }
}
```

> **`{size}` 为何不用模板**：Apple 文档只承诺 `{z}` `{x}` `{y}` `{scale}` 三个占位符，
> `{size}` 是 RainViewer 侧的要求，与 MapKit 的模板机制无关。因此**不要**把 `{size}` 写进
> `urlTemplate` 期待 MapKit 替换——用 `loadTile(at:result:)` 自己拼，才是可靠做法。

### 2.3 瓦片缓存（限流 + 缓存的唯一入口）

```swift
import Foundation

/// 瓦片缓存：内存 NSCache + 磁盘 LRU + 严格串行限流。
///
/// 实测依据：
///  - 12 线程并发会被服务端掐（大量非 PNG 响应）；≤4 并发 + 间隔 1.5 s 稳定。
///  - 真实回波瓦片中位数 3982 B、p90 19633 B。
///  - 2.5 小时前的帧路径仍返回 200 → 历史帧可放心缓存。
final class TileCache {

    static let shared = TileCache()

    enum Outcome {
        case success(Data)
        case failure(Error)
    }

    private let memory = NSCache<NSString, NSData>()
    private let session: URLSession
    private let io = DispatchQueue(label: "radar.tile.io", qos: .utility)
    private var lastRequestAt: Date = .distantPast
    private let minInterval: TimeInterval = 0.12   // ≈ 8 req/s 上限
    private var inflight: [String: [(Data?, Error?) -> Void]] = [:]

    private let diskURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent "RadarTiles", isDirectory: true)
    }()

    private init() {
        memory.countLimit = 60
        memory.totalCostLimit = 48 * 1024 * 1024
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                diskCapacity: 256 * 1024 * 1024,
                                diskPath: "RadarURLCache")
        cfg.requestCachePolicy = .useProtocolCachePolicy
        session = URLSession(configuration: cfg)
        try? FileManager.default.createDirectory(at: diskURL, withIntermediateDirectories: true)
    }

    func data(for key: String) -> Data? {
        if let m = memory.object(forKey: key as NSString) { return m as Data }
        let f = diskURL.appendingPathComponent(Self.sha(key))
        guard let d = try? Data(contentsOf: f) else { return nil }
        memory.setObject(d as NSData, forKey: key as NSString)
        return d
    }

    func load(url: URL, key: String, completion: @escaping (Outcome) -> Void) {
        if let inflight = inflight[key] {
            inflight.append(completion)
            return
        }
        inflight[key] = [completion]
        io.async { [weak self] in
            guard let self else { return }
            // 串行节流
            let wait = self.minInterval - Date().timeIntervalSince(self.lastRequestAt)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            self.lastRequestAt = Date()

            self.session.dataTask(with: url) { data, response, error in
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    self.finish(key: key, outcome: .failure(URLError(.badServerResponse)))
                    return
                }
                guard let data, !data.isEmpty else {
                    self.finish(key: key, outcome: .failure(URLError(.zeroByteResource)))
                    return
                }
                // 只缓存合法 PNG（占位图/错误页不缓存）
                guard data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
                    self.finish(key: key, outcome: .failure(URLError(.cannotDecodeContentData)))
                    return
                }
                self.memory.setObject(data as NSData, forKey: key as NSString)
                try? data.write(to: self.diskURL.appendingPathComponent(Self.sha(key)), options: .atomic)
                self.trimDisk()
                self.finish(key: key, outcome: .success(data))
            }.resume()
        }
    }

    private func finish(key: String, outcome: Outcome) {
        let callbacks = inflight.removeValue(forKey: key) ?? []
        for cb in callbacks { cb(outcome) }
    }

    /// 磁盘上限 64 MB，LRU 淘汰（按修改时间）
    private func trimDisk() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: diskURL,
                                                      includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var items = files.compactMap { url -> (URL, Date, Int)? in
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let d = v.contentModificationDate, let s = v.fileSize else { return nil }
            return (url, d, s)
        }
        var total = items.reduce(0) { $0 + $1.2 }
        let cap = 64 * 1024 * 1024
        guard total > cap else { return }
        items.sort { $0.1 < $1.1 }
        for it in items {
            try? fm.removeItem(at: it.0)
            total -= it.2
            if total <= cap { break }
        }
    }

    private static func sha(_ s: String) -> String {
        // 简单稳定 hash（仅用于文件名，非安全用途）
        var h: UInt64 = 5381
        for b in s.utf8 { h = h &* 33 &+ UInt64(b) }
        return String(h, radix: 36) + ".png"
    }
}
```

### 2.4 z 钳制 + 时间轴状态

```swift
import SwiftUI

/// 雷达时间轴：只有 past，nowcast 实测为空数组 —— 绝不能让 scrubber 空着。
struct RadarTimeline: Equatable {
    /// 全部 past 帧（实测 13 帧 / 10 分钟步长 / 覆盖最近 2 小时）。
    let frames: [RadarFrame]
    /// 用户选中的帧下标；默认 = last（最新）。
    var index: Int

    var isLive: Bool { index == frames.count - 1 }

    /// 现在时间对应的"过期分钟数"。用于文案，不用于 nowcast 预测。
    var ageMinutes: Int? {
        guard let t = frames[safe: index]?.date else { return nil }
        return max(0, Int(Date().timeIntervalSince(t) / 60))
    }

    static func make(from payload: WeatherMapsPayload) -> RadarTimeline? {
        let frames = payload.radar.past
            .map { RadarFrame(time: $0.time, path: $0.path) }
            .sorted { $0.time < $1.time }
        guard !frames.isEmpty else { return nil }   // 唯一合法的"无数据"
        return RadarTimeline(frames: frames, index: frames.count - 1)
    }
}
```

### 2.5 SwiftUI 承载（`UIViewRepresentable` 包 `MKMapView`）

**注意**：`Map` + `MapOverlay` 的 SwiftUI API **不能**直接承载 `MKTileOverlay`（后者是 `MKOverlay`，必须走 `MKMapView.addOverlay`）。因此用 `UIViewRepresentable`：

```swift
import SwiftUI
import MapKit

struct RadarMapScreen: View {
    @State private var timeline: RadarTimeline?
    @State private var host = "https://tilecache.rainviewer.com"
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        MKMapViewRepresentable(
            overlay: timeline.flatMap { tl in
                tl.frames[safe: tl.index].map { RadarTileOverlay(host: host, framePath: $0.path) }
            }
        )
        .ignoresSafeArea()
    }
}

struct MKMapViewRepresentable: UIViewRepresentable {
    let overlay: RadarTileOverlay?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        // 覆盖层自带 minimumZ/maximumZ，这里不再额外设 map.cameraZoomRange；
        // 但**建议**同时夹住相机范围，双保险（见 §4.1 R5）。
        map.cameraZoomRange = MKMapView.CameraZoomRange(
            minCenterCoordinateDistance: 200_000,   // 最小中心间距 ≈ z4
            maxCenterCoordinateDistance: 24_000_000 // 最大中心间距 ≈ z6 上限附近
        )
        if let overlay { map.addOverlay(overlay, level: .aboveRoads) }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        guard let overlay else { return }
        // 切帧时 overlay 实例会变（framePath 不同），需要替换
        if !map.overlays.contains(where: { ($0 as? RadarTileOverlay) === overlay }) {
            map.overlays.forEach { map.removeOverlay($0) }
            map.addOverlay(overlay, level: .aboveRoads)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                let r = MKTileOverlayRenderer(tileOverlay: tileOverlay)
                r.loadingPolicy = .loadBeforeDisplay   // 见 §5.4
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
```

### 2.6 GCJ-02 纠偏（§3 的实现）

```swift
import CoreLocation

/// WGS84 → GCJ-02。RainViewer 瓦片是 WGS84；中国大陆的 Apple 底图是 GCJ-02。
/// 不纠偏就会有 266–622 m 错位。
struct GCJ02Correction {

    private static let a = 6378245.0
    private static let ee = 0.00669342162296594323

    private static func transformLat(x: CLLocationDegrees, y: CLLocationDegrees) -> CLLocationDegrees {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(x: CLLocationDegrees, y: CLLocationDegrees) -> CLLocationDegrees {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }

    static func outOfChina(lon: CLLocationDegrees, lat: CLLocationDegrees) -> Bool {
        !(72.004...137.8347).contains(lon) || !(0.8293...55.8271).contains(lat)
    }

    static func wgs84ToGCJ02(lon: CLLocationDegrees, lat: CLLocationDegrees) -> (lon: CLLocationDegrees, lat: CLLocationDegrees) {
        guard !outOfChina(lon: lon, lat: lat) else { return (lon, lat) }
        var dLat = transformLat(x: lon - 105.0, y: lat - 35.0)
        var dLon = transformLon(x: lon - 105.0, y: lat - 35.0)
        let radLat = lat / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return (lon + dLon, lat + dLat)
    }

    /// 便捷封装：直接得到 CLLocationCoordinate2D
    func apply(to coord: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let (lon, lat) = Self.wgs84ToGCJ02(lon: coord.longitude, lat: coord.latitude)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
```

**更稳妥的做法（推荐）**：不要去平移单个城市坐标，而是**在 `url(forTilePath:)` 里对请求的 `(x, y)` 反向纠偏**——即把 MapKit 给的瓦片索引按 GCJ-02 偏移量在瓦片空间内平移。偏移量随位置平滑变化，**因此只对当前视野中心的瓦片做平移即可**，静止时最简单，拖动时按中心点重算。

> ⚠️ 我**没有**在真机上验证 MapKit 对 `MKTileOverlay` 是否自动施加 GCJ-02 偏移——见 §6 风险 R1。**这是必须真机验证的第一项。**

---

## 3. 中国区坐标偏移：明确结论

### 3.1 结论

**会错位，量级 266–622 m，必须纠偏。**

RainViewer 瓦片是纯 WGS84 Web Mercator；中国大陆 Apple 底图（高德源，GCJ-02）已做偏移处理。两者**叠加会整体错位**——不是"看起来能用"，是**几百米的系统性平移**。

### 3.2 实测偏移量

用标准 GCJ-02 算法（`gcj.py`）逐城计算：

| 城市 | WGS84 | GCJ-02 | 偏移 |
|---|---|---|---|
| 北京 | 116.3970, 39.9090 | 116.4032, 39.9104 | **556 m** |
| 上海 | 121.4730, 31.2300 | 121.4775, 31.2281 | **482 m** |
| 广州 | 113.2640, 23.1290 | 113.2693, 23.1263 | **622 m** |
| 深圳 | 114.0570, 22.5430 | 114.0621, 22.5403 | **607 m** |
| 成都 | 104.0660, 30.5720 | 104.0685, 30.5695 | **364 m** |
| 乌鲁木齐 | 87.6170, 43.7930 | 87.6198, 43.7942 | **266 m** |
| 拉萨 | 91.1400, 29.6450 | 91.1415, 29.6423 | **339 m** |
| 东京 / 纽约 / 伦敦 | — | — | **0 m**（境外不偏移） |

### 3.3 为什么"看不出来"——这正是高发坑

| z | 瓦片地面 | 分辨率 | 556 m 相当于 |
|---|---|---|---|
| 4 | 1921 km | 7505 m/px | 0.07 px（完全看不出来） |
| 5 | 961 km | 3752 m/px | 0.15 px（看不出来） |
| 6 | 480 km | 1876 m/px | 0.30 px（勉强） |
| 7 | 240 km | **938 m/px** | **0.59 px**（开始可见） |

**危险结论**：在 z4/z5（覆盖全国/区域）下偏移**肉眼不可见**，会误以为"没问题"；一旦用户放大到 **z6/z7 看城市细节**，偏移开始显现，**而此时已经在生产环境**。而且回波是**移动的对流单体**，几百米错位会让用户看到"雨在马路对面"。

**建议**：从第一天就按纠偏实现，不要留 TODO。

### 3.4 NSValueTransformer 陷阱

- **不要用 `MKMapView` 的 GCJ 转换 API 去"转换瓦片"**。`NSValueTransformer`（`MKMapView.userTrackingMode` 等）不涉及自定义瓦片。
- **真正的坑**：`MKMapPoint` / `MKMapRect` 本身是纯 Web Mercator 数学，**不含 datum 偏移**。而 `MKMapView` 在中国大陆**渲染底图时**会施加 GCJ-02 偏移。两者不是同一层，所以**不要指望 `MKMapPoint(for:)` 会帮你纠偏**。
- 常见错误做法：把城市 WGS84 坐标 `GCJ-02` 化后传给 MapView，同时瓦片也偏移 → **变成双重偏移**，更糟。
- 境外城市（含港澳台中的港澳）`outOfChina` 返回 true，纠偏函数应**原样返回**，不要无条件加偏移。

---

## 4. 降级四态的 UI 草案

### 4.1 状态机

```swift
enum RadarAvailability: Equatable {
    /// 国内城市：显示雷达图
    case radar
    /// 境外城市：显示本 App 的预报（RainViewer 覆盖欧美，但为避免误导，国内优先）
    case forecast(region: String)
    /// 雷达数据拉取失败 / 无覆盖
    case radarUnavailable(reason: String)
    /// 明确无数据（元数据 0 帧）
    case noData
}
```

四态对应的判定与呈现：

| 态 | 判定 | 地图区 | 时间轴 | 顶部结论句 |
|---|---|---|---|---|
| `.radar` | 城市在 RainViewer 覆盖内 + `past` 非空 | 底图 + 雷达回波层 | **13 档** scrubber（默认最新档） | "雷达回波 · 15:40 更新" |
| `.forecast(国内)` | 同上但无 `past` 帧 | 底图 + 站点观测点 | **禁用**（灰掉 + 说明） | "该站点暂无回波，显示预报" |
| `.forecast(欧美)` | 境外城市 | 底图（干净，不叠回波） | 禁用 | "境外预报" |
| `.radarUnavailable` | 网络失败 / JSON 解析失败 / 全透明 | 底图 | 禁用 | "雷达图加载失败 · 重试" |

### 4.2 时间轴设计（**绝不能出现空白 scrubber**）

**只有 13 帧 past、nowcast 为空**。所以：

1. **只渲染 `past`，永不渲染 nowcast 占位。** 实测 `radar.nowcast` = `[]`（两次拉取、两个不同时刻均为空），独立 `nowcast.json` 返 404。**不能承诺"临近预报"**。
2. **帧数下限保护**：`past.count == 0` → 直接走 `.radarUnavailable`，**不显示 scrubber**，而不是显示一个空的滑块。
3. **时间轴要标注"回放"语义**：
   - 左端：`2 小时前`
   - 右端（默认选中）：`实况 · HH:mm`
   - 选中非右端时，顶部加 `回放中 · HH:mm` 徽标，并在 scrubber 上加一个小 ▶ 播放键。
4. **帧步长 10 分钟**（实测 13 帧 × 10 min = 130 分钟 ≈ 2 小时），可以像 Apple Weather 那样有"逐 10 分钟"刻度感。
5. **"过期"是特性不是 bug**：`ageMinutes > 20` 时给 `数据延迟 25 分钟` 的诚实提示（沿用本项目既有的 staleness 表达风格）。**别假装是实时。**

---

## 5. 配额与缓存策略

### 5.1 实测的基础数字

- `weather-maps.json`：**免 Key、免注册**，实测 200。`radar.past` = **13 帧**，`nowcast` = `[]`。
- 帧步长 **10 分钟**。原始 `time` 字段（UTC）：`13:40, 13:50, 14:00, 14:10, 14:20, 14:30, 14:40, 14:50, 15:00, 15:10, 15:20, 15:30, 15:40` —— 严格 600 s 等间隔，13 帧 × 10 min = 130 分钟 ≈ 2 小时。
  `generated` 每次拉取都在推进（实测 15:45:34Z → 16:00:24Z）。
- **旧帧路径仍然可用**：实测 2.5 小时前的帧（13:40）仍返回 200 / 10861 字节。→ **可放心缓存历史帧**。
- **官方明确要求缓存**（"We recommend caching responses on your side"）。
- 无公开硬限流，但**实测高并发会被限流**：12 线程并发时大量请求返回非 PNG（连接被掐，全球普查 z6 层级 658/4088 失败）；降到 4 线程 + 1.5 s 间隔后稳定。**注意 `zoomcensus` z5 采样到 1017 而非 1024，也是限流丢失所致**。

### 5.2 瓦片体积（实测 67 张真实回波瓦片）

| 指标 | 值 |
|---|---|
| 最小 | 345 B（几乎无回波） |
| **中位数** | **3982 B** |
| 均值 | 6919 B |
| p90 | 19633 B |
| 最大 | 28099 B |

全屏一帧的量（按 §6 瓦片数）：

| 场景 | 瓦片数/帧 | 中位体积 | 13 帧全缓存 |
|---|---|---|---|
| z5 城市视野 | ~56 | 223 KB | **2.8 MB** |
| z6 城市视野 | ~195 | 776 KB | **9.6 MB** |
| z7 城市视野 | ~725 | 2.8 MB | 36 MB（**别全存**） |

### 5.3 建议策略

- **`URLCache`**：内存 32 MB / 磁盘 256 MB。系统会按 HTTP 头自动处理，`last-modified` + `etag` 都在（实测），条件请求能省带宽。
- **内存缓存**：`NSCache` 存最近 2 帧的解码后 `UIImage`，上限 ~48 MB，`countLimit = 60`。
- **磁盘缓存**：
  - 只存**当前显示帧 + 相邻帧**，key = `radar/{path}/{z}/{x}/{y}/{color}.png`。
  - **TTL 建议 30 分钟**（帧步长 10 分钟，30 分钟足够覆盖 3 帧且不会堆积）。
  - 上限 **64 MB**，LRU 淘汰。z7 只缓存当前视野。
- **过期时间**：`weather-maps.json` **TTL 4 分钟**（10 分钟步长的一半，避免拿到刚刷新的边缘帧）。**注意**：不是 5 分钟——brief 说的 5 分钟与实测 10 分钟步长不符，以实测为准。
- **必须做**：请求失败时回退到磁盘缓存的上一帧，并在 UI 上打"数据延迟"标记。**绝不空白。**

### 5.4 加载策略

`loadingPolicy`（`MKTileOverlayRenderer`）：

- **`.loadBeforeDisplay`？不。**
- **推荐 `.loadBeforeDisplay` 用于首帧、`loadAsync` 用于拖动中**？不——单 overlay 只能设一个策略。

**结论：设 `MKTileOverlayRenderer.loadingPolicy = .loadBeforeDisplay`。**
- 理由：雷达瓦片小（中位 4 KB），预加载成本可接受；`.loadAsync` 会让拖动时出现"空白格子闪烁"，对天气图观感伤害大。
- 真正的性能杠杆不是 `loadingPolicy`，而是 **z 钳制到 7**（把 z8+ 的空图挡掉）与**只请求当前帧**。
- `canReplaceMapContent = false`，`level = .aboveRoads`（盖在道路上、不盖 POI 标签）。

---

## 6. 会让这个功能「做不成」的风险（直说，不粉饰）

### 🔴 R1（最高）MapKit 是否自动对 `MKTileOverlay` 施加 GCJ-02 偏移——**未验证**

Apple 未公开此行为。我查到的社区资料只确认了**相邻事实**，无法直接推出本问题的答案：

- ✅ 已确认："iOS 地图在**中国大陆地区使用高德数据源（GCJ-02）**，港澳台及海外使用 TomTom（WGS-84）"（多方一致）。
- ✅ 已确认：`MKMapView` 的 `addAnnotation` / `addOverlay` 坐标参数**在中国大陆语境下按 GCJ-02 解释**（社区广泛实践，即"国内打点要先转 GCJ-02"）。
- ❌ **未确认**：上述"自动转换"是**只作用于底图渲染**，还是**连自定义瓦片图层一起平移**。两种机制在公开资料里没有区分。

两种可能：
- **A**：MapKit 平移整个地图空间（含自定义 overlay）→ 我们**不需要**纠偏，多纠反而错。
- **B**：MapKit 只平移底图，overlay 用原始索引 → 我们**必须**纠偏。

**我无法在无真机、无模拟器的情况下判定**，也不打算编造 Apple 的行为规则。

> 相邻事实里有一条**反向线索**值得注意：既然 `addAnnotation` 的坐标在国内要按 GCJ-02 解释，说明 MapKit 的**入参**约定是"国内给 GCJ-02"，那么它把图层平移成 GCJ-02 网格（即方案 A）的可能性是存在的。但这仍不足以定论。

**这是实施第一步就要在真机上验的**（拿一张已知地标，比如天安门广场的轮廓、黄浦江的江岸线，对比回波与底图）。

**验收标准**：真机上在北京/上海，雷达回波边缘与底图已知地物（江岸、海岸线）的偏移必须 **< 50 m**。若不满足 → 打开纠偏；已满足 → 删掉纠偏代码。**不要两个都做，也不要凭本文档的推测直接写死。**

### 🔴 R2 侧载/非 App Store 分发与"仅个人/教育用途"许可的冲突

RainViewer 条款明文：**"free for personal and educational use"**、"personal, educational, and **small-scale community** projects"。

- 本项目是**零第三方依赖的天气 App**，若将来上 App Store 商业化，免费层**不一定覆盖**。
- 条款还写明"owners can ask us to remove their data ... or stop sharing"，**无 SLA**。
- **署名是强制的**：必须显示 "Weather data by RainViewer" + 链接到 rainviewer.com。

**这不是技术风险，是产品/法务风险，但足以让功能"做不成"。** 建议：实施前先确认分发形态；若确定要商业化，**要么谈商业授权，要么把雷达层做成可关闭的实验功能**。

### 🟠 R3 服务稳定性：无 SLA + 限流

实测 12 线程并发即被掐。免费层"abuse may result in your IP being blocked"。
- **缓解**：严格串行/低并发（≤4）、强制缓存、条件请求。
- **残留风险**：高峰期或被限流时可能整层空白 → **必须**有"降级到纯底图 + 说明"路径（这就是 §4 的 `.radarUnavailable`）。

### 🟠 R4 侧载 App 的 entitlements 已知坑

本仓库有一个**已记录的教训**（任务 #85 / `ios-sideload-entitlements-blindspot`）：侧载产物上 App Group、推送、associated domains 会**静默失效**。
- 若雷达页要放小组件 / Live Activity 里的雷达缩略图，**必须让扩展自给自足**（扩展自己拉数据），不要指望共享容器传瓦片缓存。
- 纯 App 内页面不受此影响。**建议一期只做 App 内，不进小组件。**

### 🟡 R5 z8+ 占位图会漏给用户

若不钳制，用户放大到 z8 会看到**写着 "Zoom Level Not Supported" 的灰图**，非常出戏。
- **缓解**：`minimumZ=4 / maximumZ=7`。MapKit 会在到边界时停止请求更高 z。**必须在真机确认缩放控件不会露出 z8。**

### 🟡 R6 国内降水数据源的真实覆盖度

RainViewer 是**全球雷达 mosaic**，但中国区域的覆盖来自拼接的第三方雷达，与"和风/彩云"的本地化数据源比，**对流精细度可能明显不足**（尤其强对流单体）。
- **缓解**：这是**产品预期管理**问题，不要在文案里承诺"比专业气象 App 更准"。
- 建议文案："雷达回波（RainViewer 全球合成）"，并**如实标注 10 分钟更新粒度**。

### 🟢 非风险（已排除）
- 坐标系：标准 XYZ，已实测确认（§1）。
- 性能：瓦片极小（中位 4 KB），z 钳到 7 后完全可接受。
- Key/注册：免。
- nowcast：**已确认拿不到，已在设计上排除依赖**。

---

## 7. 给下一轮的实施建议（结论）

**建议做，但按这个顺序：**

1. **先做 R1 的真机验证**（半天）。这是 go/no-go 闸门——它决定纠偏代码写不写。
2. 确认 R2 的分发形态 / 授权问题（产品决策，非技术）。
3. 最小实现：`RadarTileOverlay` + `MKMapViewRepresentable` + z 钳制 + 13 帧时间轴。
4. 只在**主 App** 内做，不进小组件（规避 R4）。
5. 四态降级 + 署名 一次做齐（署名是许可硬要求，不能"以后补"）。

**署名 UI 建议（不破坏磷光终端风）**：地图页**左下角**、底图之上，用现成的 `Theme.FontSize.footnote` + `palette.secondaryText`，文案 `Weather data by RainViewer`，`rainviewer.com` 用 `accentSecondary`（`#5FB8D6` 深色 / `#1D9E75` 浅色）做成可点链接。位置选左下角是因为：Apple Weather 也放左下、不与右上图层切换器冲突、且在 `aboveRoads` 层级下不会被 POI 标签压住。

---

## 附录 A：复现脚本（`_radar-probe/`，仓库外）

| 文件 | 作用 |
|---|---|
| `tilemath.py` | 标准 XYZ 数学 + 各地落点，打印 `m/px` |
| `rv.py` | 正确 URL 模板 + 灰阶占位图识别 + 载荷分组普查 |
| `projtest.py` | 投影一致性 + TMS y 翻转否证（93.6% vs 62.0%） |
| `projrigor.py` | 偏移扫描 `(dx,dy)∈[-3,3]²`（最优 = (0,0)） |
| `centroid.py` | 亚像素质心检验（+5.7 km / −22.9 km） |
| `maxzoom2.py` / `maxzoom.py` | 真实最大 zoom 定位（z7 真 / z8 占位） |
| `gcj.py` | 逐城 GCJ-02 偏移量 + 分辨率对照 |
| `zoomcensus.py` | z0–z11 全球普查 |

## 附录 B：实测环境

- 网络：直连（本机未走代理），`api.rainviewer.com` / `tilecache.rainviewer.com` 均可达
- 时钟：本地 epoch 与服务器 `Date` 头一致（`1791043305` vs `Sat, 03 Oct 2026 16:01:49 GMT`），**无时钟偏移**
- 帧样本：`/v2/radar/08b24b75fa89`（16:00 UTC 帧），元数据 `generated=2026-10-03T16:00:24Z`
- Python 3.13.12 + pillow + numpy

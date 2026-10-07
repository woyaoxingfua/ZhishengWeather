//
//  SatelliteImageService.swift
//  Core / Networking  [App + Widget 共用]
//
//  风云四号真彩卫星云图取数：**帧回溯探测 + 内存/磁盘缓存 + 坏帧拒收**。
//
//  ═══════════════════════════════════════════════════════════════════════
// 实测基准：2026-10-07（当次真实 curl / Pillow 统计；逐条数字见
// `SatelliteImageEndpoint.swift` 与 `SatelliteFrameValidator.swift` 文件头）
// ═══════════════════════════════════════════════════════════════════════
//
// ── 🔴 为什么必须「回溯探测」而不是「只取当前时刻」────────────────────
// 实测保留窗口是**锯齿状**（日内有洞），非整段截断：
//   2026-10-06 的 00/06/10 UTC → **404**；12/15/22/23 UTC → 200
//   2026-10-07 的 12/14/16 UTC → **404**（未来时刻，尚未产出）
// → 故本服务从「最近一个已过去的 15 分钟栅格」起，**向前最多回溯 48 帧**，
//   命中第一个「200 + 通过坏帧校验」的帧即返回。
//   ⚠️ 探测**串行**且每步 `try? await Task.sleep` 让出执行权，
//   绝不并发轰炸（最坏 48 次请求）。
//
// ── 缓存：为什么必须有 ───────────────────────────────────────────────
// · 单帧实测 **122 603 … 163 863 B**（约 130 KB）——不缓存则每次滚动重下；
// · 帧间隔 15 分钟 → 同一帧会被反复用到，故TTL 取「帧间隔 × 2」
//   （= 30 分钟）既避免重复下载、又不会把用户钉死在过期帧上超过一帧。
//
// ── 🔴 磁盘目录：**不用 App Group**（侧载自用时恒为空，见任务书）────
// 与 `RadarTileCache` 同款：`.cachesDirectory`，缺失时回退临时目录。
//
// ── 坏帧拒收（核心纪律）──────────────────────────────────────────────
// 任何一帧若未通过 `SatelliteFrameValidator`，**一律不返回给UI**。
//
// 🔴 **两层缺一不可（本批修复的核心）**：
//  ·字节层拦**404 的 openresty HTML 错误页**（本轮实测 4/4 恒为 552 B，
//    逐字含 `<center>openresty</center>`；若只判「有数据」就会把 HTML 当图）。
//  · **像素层拦纯黑占位图** —— 这是字节层**完全拦不住**的那种坏帧：
//    纯黑图状态码 200、字节数与真图无异，只有像素统计能区分。
//    此前服务只调`validateByteCount`（字节层），
//    导致 `validate(byteCount:statistics:)` 零调用 → `pureBlackFrame` 是死代码。
//    现已改为：像素统计由 App 侧经 `statisticsProvider` 注入，两层都真跑。
//
// Core 纪律：仅 import Foundation；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 卫星云图取数结果。
enum SatelliteImageOutcome: Equatable {

    /// 成功：拿到一帧**已通过校验**的图片。
    ///
    /// ⚠️ `observationDate` 是**UTC 观测时刻**；UI 按时区渲染。
    ///
    /// - Parameter pixelValidation: **像素层到底跑没跑**（如实上报）。
    ///   ⚠️ 这个字段存在的唯一理由：`.success` 只说明「拿到了字节」，
    ///   若不区分「纯黑检测跑过且通过」与「像素层没跑（统计为 nil）」，
    ///   上层就会把后者当成「纯黑也验过了」——
    ///   而实际上**纯黑帧会被漏掉**。这与「只看字节数 100% 误判可用」
    ///   是同一个错误的两种写法。
    case success(data: Data,
                 url: URL,
                 observationDate: Date?,
                 pixelValidation: SatellitePixelValidation)

    /// 取不到（网络失败 / 全部候选帧都不存在）。
    case unavailable(String)

    /// 拿到了字节但**不是可用图**（HTML 错误页 / 纯黑 / 解码失败）。
    ///
    /// ⚠️ 与 `.unavailable` **必须分开**：前者是「这一帧坏了」，
    /// 后者是「一段时次都取不到」—— 用户看到的提示不同。
    case rejectedFrame(SatelliteFrameVerdict)
}

/// 云图帧缓存策略（纯判定，可单测）。
enum SatelliteImageCachePolicy {

    /// 内存缓存字节上限。
    ///
    /// 实测单帧最大 163 863 B；取 4 MiB ≈ 25 帧，足够覆盖一屏回看。
    static let memoryBytes = 4 * 1_024 * 1_024

    /// 内存缓存条数上限。
    static let memoryCount = 8

    /// 磁盘缓存字节上限（约 40 帧 ≈ 5 MB）。
    static let diskBytes = 5 * 1_024 * 1_024

    /// 帧 TTL（秒）= 帧间隔 × 2。
    ///
    /// 实测帧间隔 15 分钟 → TTL 30 分钟。
    static var ttlSeconds: TimeInterval { SatelliteImageEndpoint.frameStepSeconds * 2 }

    /// TTL 判定（**注入 `now`**，Core 禁内部 `Date()`）。
    static func isFresh(storedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(storedAt) < ttlSeconds
    }
}

/// 卫星云图取数服务（`actor`：缓存字典是未加锁共享可变状态）。
actor SatelliteImageService {

    /// 单次请求超时（秒）。
    ///
    /// 实测 48 帧全部下载完成约 7.2 MB，单帧 130 KB 级，
    /// 20 s 足够宽松；超时按「该帧不存在」处理并继续回溯。
    static let requestTimeout: TimeInterval = 20

    /// 帧探测之间的让出间隔（秒）。
    ///
    /// ⚠️ 不是「限速」而是**让出执行权**：回溯最坏 48 步，
    /// 每步都 `await Task.sleep` 才能让 UI 保持响应、不出现「转圈卡死」。
    static let probeInterval: UInt64 = 120_000_000  // 120 ms

    /// 注入的 session（测试可换）。
    private let session: URLSession

    /// 内存缓存。
    private let memory: NSCache<NSString, NSData>

    /// 磁盘缓存目录。
    private let diskDirectory: URL

    /// 磁盘写入时刻（键 → 时刻），用于 TTL 判定。
    private var storedAt: [String: Date] = [:]

    /// 磁盘占用字节（用于 LRU 淘汰）。
    private var diskBytesUsed: Int = 0

    /// 回溯探测的最大帧数（**可注入**：单测只需探几帧，不必真打 48 次）。
    private let probeLimit: Int

    /// 构造。
    ///
    /// ⚠️ **不用 App Group**：侧载自用时共享容器恒为空，
    /// 走 `.cachesDirectory` 才有实际收益（与 `RadarTileCache` 同款判据）。
    ///
    /// - Parameters:
    ///   - session: 注入的 session（测试换`URLProtocol` 桩）。
    ///   - diskDirectory: 磁盘缓存目录；`nil` → `.cachesDirectory`。
    ///   - probeLimit: 回溯探测上限；`nil` → `maxProbeFrames`（48）。
    ///     ⚠️ 存在理由不是「配置项」，而是**可测性**：
    ///     48 帧 × 每步 120 ms 让出 ≈ 5.8 s，单测无法承受；
    ///     且探测次数不该被硬编码在业务逻辑里。
    init(session: URLSession = .shared,
         diskDirectory: URL? = nil,
         probeLimit: Int? = nil) {
        self.session = session
        self.probeLimit = probeLimit ?? SatelliteImageEndpoint.maxProbeFrames
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = SatelliteImageCachePolicy.memoryBytes
        cache.countLimit = SatelliteImageCachePolicy.memoryCount
        self.memory = cache
        if let diskDirectory {
            self.diskDirectory = diskDirectory
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.diskDirectory = base.appendingPathComponent("SatelliteImages", isDirectory: true)
        }
    }

    // MARK: - 对外

    /// 取最新可用云图（回溯探测 + 缓存 + **两层坏帧校验**）。
    ///
    /// ── 参数`statisticsProvider`：像素统计注入点 ──────────────────────
    /// ⚠️ **必须有它，纯黑判定才真正生效。** 本批之前的实现里
    /// `SatelliteFrameValidator.validate(byteCount:statistics:)` 的
    /// **外部调用点为 0**（服务只调 `validateByteCount`），
    /// 于是 `pureBlackFrame` 在运行期**永远不可能被产生** —— 死代码。
    /// 而纯黑占位图恰恰是字节层**零判别力**的那种坏帧。
    /// → 故服务签名**接受闭包**，由App 侧（唯一持有 UIKit 的 target）
    ///   解码后把统计注入回来（见 `SatelliteStatisticsProvider`）。
    ///
    /// ⚠️ **统计为 nil 时的降级语义（如实，不装作通过）**：
    ///   统计为 nil → **只判字节层**，并在 `.success` 里带
    ///   `pixelValidation: .unavailable` 明说「像素层没跑」。
    ///   →此状态下**确实会漏掉纯黑帧**（判据没执行，无从谈起）。
    ///   这是**已知且被如实上报的缺口**，不是「已通过纯黑检测」。
    ///
    /// - Parameters:
    ///   - now: 注入的「现在」（**UTC 栅格对齐的唯一依据**；单测可固定）。
    ///   - statisticsProvider: 像素统计注入点；`nil` → 像素层**完全没跑**。
    /// - Returns: 结果（**绝不含未过校验的字节**）。
    func fetchLatest(now: Date,
                     statisticsProvider: SatelliteStatisticsProvider? = nil) async -> SatelliteImageOutcome {
        let stamps = SatelliteImageEndpoint.probeStamps(now: now, limit: probeLimit)
        guard !stamps.isEmpty else {
            return .unavailable("未能推导出任何候选时次")
        }
        var lastRejection: SatelliteFrameVerdict?
        for stamp in stamps {
            if let url = url(forStamp: stamp) {
                // 缓存命中优先（键 = 时戳）。
                let key = cacheKey(stamp)
                // `fromCache` 只用于决定**要不要写缓存**（已缓存的不必重写）。
                var candidate: Data?
                var fromCache = false
                if let cached = data(forKey: key, now: now) {
                    candidate = cached
                    fromCache = true
                } else {
                    switch await loadFrame(url: url) {
                    case .downloaded(let data):
                        candidate = data
                    case .rejected(let verdict):
                        // 传输层就能判定的坏帧（如响应体根本不是图片）。
                        lastRejection = verdict
                        candidate = nil
                    case .miss:
                        candidate = nil
                    }
                }
                // 🔴 **两层校验集中在这里**（缓存与新下载走**同一条**判定路径）。
                //
                // ⚠️ 必须放在 `loadFrame` 之后、由本方法统一做，
                //   这样「缓存命中的帧」与「新下载的帧」判据完全一致——
                //   否则会出现「坏帧从缓存绕过像素层」这种最难查的漏洞。
                // ⚠️ 且**校验通过前不写缓存**（见下方 `store` 的位置）。
                if let data = candidate {
                    let stats = statisticsProvider?(data)
                    if let bad = SatelliteFrameValidator.validate(byteCount: data.count,
                                                                 statistics: stats) {
                        lastRejection = bad
                    } else {
                        // 只有过了两层校验才落缓存（坏帧永不入缓存）。
                        if !fromCache { store(data, forKey: key, now: now) }
                        return .success(
                            data: data,
                            url: url,
                            observationDate: observationDate(forStamp: stamp),
                            pixelValidation: stats == nil ? .unavailable : .passed
                        )
                    }
                }
            }
            // 让出执行权：最坏 48 步，必须给 UI 留响应机会。
            try? await Task.sleep(nanoseconds: Self.probeInterval)
        }
        if let lastRejection {
            return .rejectedFrame(lastRejection)
        }
        return .unavailable("未找到可用时次（保留窗口内全部缺失）")
    }

    // MARK: - 私有：单帧

    /// 取单帧字节（不含回溯、**不做像素判定**）。
    ///
    /// ⚠️ 这里**只做字节层的粗判**（拦住「响应体根本不是图片」），
    ///   **两层完整判定由 `fetchLatest` 统一做**。
    ///   原因：缓存与新下载必须走**同一条**判定路径；
    ///   若把判定分散在「缓存分支」与「下载分支」两处，
    ///   极易出现「坏帧从缓存绕过像素层」这种最难查的漏洞。
    ///
    /// ⚠️ 本方法**不写缓存** —— 写缓存必须由调用方在**校验通过后**触发。
    private func loadFrame(url: URL) async -> FrameResult {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = Self.requestTimeout
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                // 本轮实测 404 → 552 B openresty HTML；非 2xx 一律按「该帧不存在」。
                return .miss
            }
            // 字节层粗判：8 KiB 下界 / 8 MiB 上界。
            if let bad = SatelliteFrameValidator.validateByteCount(data.count) {
                return .rejected(bad)
            }
            return .downloaded(data)
        } catch {
            return .miss
        }
    }

    /// 单帧取数结果。
    private enum FrameResult {
        /// 下载成功（**尚未做任何像素判定**）。
        case downloaded(Data)
        /// 传输层即可判定的坏帧。
        case rejected(SatelliteFrameVerdict)
        /// 该帧不存在（404 / 网络错误）。
        case miss
    }

    // MARK: - 私有：URL / 键 / 时刻

    /// 由时戳构造 URL。
    ///
    /// 🔴 **参数 `now` 已删除（本批修复的编译错误之一）**：
    /// 原签名是 `url(forStamp:now:)`，但函数体内**从未使用 `now`**，
    /// 而调用处只传了 1 个参数 → 编译失败。
    /// 且从原理上它**不该**存在：年月日必须来自**时戳本身**，
    /// 否则回溯跨日时 `now` 的日期会错 → 404（详见下方注释）。
    private func url(forStamp stamp: String) -> URL? {
        // ⚠️ 年月日必须来自**时戳本身**，不能来自 `now`
        //（回溯跨日时 `now` 的日期会错 → 404）。
        guard let observation = observationDate(forStamp: stamp) else { return nil }
        return SatelliteImageEndpoint.productURL(
            stamp: stamp,
            date: observation,
            calendar: SatelliteImageEndpoint.utcGregorian
        )
    }

    /// 时戳 → 观测时刻（UTC）。
    private func observationDate(forStamp stamp: String) -> Date? {
        var comps = DateComponents()
        let chars = Array(stamp)
        guard chars.count == SatelliteImageEndpoint.stampDigits else { return nil }
        func num(_ range: Range<Int>) -> Int? { Int(String(chars[range])) }
        guard let y = num(0..<4), let mo = num(4..<6), let d = num(6..<8),
              let h = num(8..<10), let mi = num(10..<12), let sec = num(12..<14) else {
            return nil
        }
        comps.year = y; comps.month = mo; comps.day = d
        comps.hour = h; comps.minute = mi; comps.second = sec
        return SatelliteImageEndpoint.utcGregorian.date(from: comps)
    }

    /// 缓存键（= 时戳，天然按帧隔离）。
    private func cacheKey(_ stamp: String) -> String { "satellite_" + stamp }

    // MARK: - 私有：缓存读写

    /// 读缓存（内存优先，其次未过期的磁盘）。
    private func data(forKey key: String, now: Date) -> Data? {
        if let hit = memory.object(forKey: key as NSString) {
            return hit as Data
        }
        let file = diskDirectory.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: file) else { return nil }
        // TTL 以内存记录的时刻为准；无记录（进程重启后）视为已过期 → 回源。
        guard let stamp = storedAt[key],
              SatelliteImageCachePolicy.isFresh(storedAt: stamp, now: now) else {
            return nil
        }
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }

    /// 写缓存（内存 + 磁盘，超限则按最旧淘汰）。
    ///
    /// ⚠️ `now` **注入**而非内部 `Date()`：Core 纪律（见文件头）。
    private func store(_ data: Data, forKey key: String, now: Date) {
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        storedAt[key] = now
        // 磁盘
        try? FileManager.default.createDirectory(at: diskDirectory,
                                                 withIntermediateDirectories: true)
        let file = diskDirectory.appendingPathComponent(key)
        if let existing = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int {
            diskBytesUsed -= existing
        }
        if (try? data.write(to: file, options: .atomic)) != nil {
            diskBytesUsed += data.count
        }
        evictDiskIfNeeded()
    }

    /// 磁盘超限 → 删最旧（**用 `storedAt` 判龄**，不依赖文件系统 mtime）。
    private func evictDiskIfNeeded() {
        guard diskBytesUsed > SatelliteImageCachePolicy.diskBytes else { return }
        let ordered = storedAt.sorted { $0.value < $1.value }
        for (key, _) in ordered {
            guard diskBytesUsed > SatelliteImageCachePolicy.diskBytes else { break }
            let file = diskDirectory.appendingPathComponent(key)
            if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int {
                diskBytesUsed -= size
            }
            try? FileManager.default.removeItem(at: file)
            storedAt[key] = nil
            memory.removeObject(forKey: key as NSString)
        }
    }
}

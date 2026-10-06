//
//  RadarTileCache.swift
//  Core / Networking  [App + Widget 共用]
//
//  雷达瓦片缓存：内存 NSCache + 磁盘 LRU + 并发闸 + 占位图拒收。
//
//  为什么缓存必须在这里（而不是交给 URLCache）：
//  实测 12 并发会被服务端掐断 → 必须有一个**单一收口**做并发闸；
//  而错模板 / 超 zoom 返回的是 **HTTP 200 + 合法 PNG 的灰图**，
//  URLCache 会照单全收 → 必须有人把它挡下来（`RadarPlaceholderDetector`）。
//
//  纯判定逻辑（`RadarCacheTTL` / `RadarTileCachePolicy` / `LRU 淘汰顺序`）
//  都在可单测的边界内；本文件的 IO 部分保持薄。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//  （注意：磁盘目录写入用 `try?`，**不用 try! / fatalError**。）
//

import Foundation

// MARK: - 磁盘 LRU 淘汰顺序（纯函数，可单测）

/// 磁盘 LRU 淘汰的**纯判定**部分（便于单测，不碰文件系统）。
enum RadarDiskEviction {

    /// 一个候选文件（URL + 修改时刻 + 字节数）。
    struct Candidate: Equatable {
        let url: URL
        let modifiedAt: Date
        let size: Int
    }

    /// 计算需要淘汰的文件（**最旧的先删**，直到降到上限内）。
    ///
    /// 纯函数：给定候选清单与上限，返回"应当删除"的那批 —— 不含任何 IO，
    /// 故 LRU 顺序可被确定性断言（文件系统 mtime 在真机上不可复现）。
    ///
    /// - Parameters:
    ///   - candidates: 全部缓存文件。
    ///   - capacityBytes: 磁盘上限字节。
    /// - Returns: 需删除的文件 URL（按删除顺序 = 最旧优先）。
    static func filesToEvict(_ candidates: [Candidate], capacityBytes: Int) -> [URL] {
        guard candidates.reduce(0, { $0 + $1.size }) > capacityBytes else { return [] }
        // 最旧优先；同一时刻用 URL 字典序做确定性 tie-break。
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
            return lhs.url.path < rhs.url.path
        }
        var total = candidates.reduce(0) { $0 + $1.size }
        var evicted: [URL] = []
        for item in ordered {
            guard total > capacityBytes else { break }
            evicted.append(item.url)
            total -= item.size
        }
        return evicted
    }
}

// MARK: - 并发闸（纯判定，可单测）

/// 并发闸的**纯判定**部分。
enum RadarConcurrencyGate {

    /// 获得许可（登记一次在途请求）。
    /// - Parameter active: 当前在途数。
    /// - Returns: 允许发起 → true。
    static func admits(active: Int) -> Bool {
        active < RadarTileCachePolicy.maxConcurrentRequests
    }

    /// 是否需要为本次请求**额外等待**。
    ///
    /// - Parameters:
    ///   - active: 当前在途数。
    ///   - secondsSinceLastStart: 距上次发起请求的秒数（**由调用方注入**，Core 禁内部 `Date()`）。
    static func needsDelay(active: Int, secondsSinceLastStart: TimeInterval) -> Bool {
        if !admits(active: active) { return true }
        return secondsSinceLastStart < RadarTileCachePolicy.minimumRequestInterval
    }
}

// MARK: - 瓦片缓存

/// 瓦片缓存（actor，串行化所有状态变更）。
///
/// 对外只暴露 `data(forKey:)` 与 `load(...)`：
///  - 命中内存 / 未过期磁盘 → 直接返回；
///  - 否则经**并发闸 + 最小间隔**拉取，成功且非占位图才写缓存。
///
/// 失败一律返回 `.failure`，由调用方（MapKit overlay）决定降级 —— 本层
/// **不返回占位图**，这是"用户绝不看到灰图"的最后一道闸。
actor RadarTileCache {

    /// 取数结果。
    enum Outcome: Sendable {
        case success(Data)
        case failure
    }

    private let session: URLSession
    private let memory: NSCache<NSString, NSData>
    private let diskDirectory: URL

    /// 磁盘写入时刻（键 → 时刻），用于 TTL 判定。
    private var storedAt: [String: Date] = [:]
    /// 在途请求数（并发闸状态）。
    private var activeRequests = 0
    /// 上次发起请求的 epoch 秒（最小间隔闸状态）。
    private var lastRequestEpoch: TimeInterval = -.infinity
    /// 同键在途去重：键 → 等待者。
    private var waiters: [String: [CheckedContinuation<Outcome, Never>]] = [:]

    /// 注入 session 与磁盘目录（测试可指到临时目录）。
    ///
    /// - Parameters:
    ///   - session: URLSession。
    ///   - diskDirectory: 磁盘缓存目录；默认取 Caches/RadarTiles。
    init(session: URLSession = .shared, diskDirectory: URL? = nil) {
        self.session = session
        let memory = NSCache<NSString, NSData>()
        memory.totalCostLimit = RadarTileCachePolicy.memoryBytes
        memory.countLimit = RadarTileCachePolicy.memoryCount
        self.memory = memory
        if let diskDirectory {
            self.diskDirectory = diskDirectory
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.diskDirectory = base.appendingPathComponent("RadarTiles", isDirectory: true)
        }
    }

    // MARK: - 读

    /// 读取缓存（内存优先，其次未过期的磁盘）。
    ///
    /// - Parameters:
    ///   - key: 缓存键。
    ///   - now: 当前时刻（**注入**；Core 禁内部 `Date()`）。
    /// - Returns: 未过期的瓦片字节；无 / 已过期 → nil。
    func data(forKey key: String, now: Date) -> Data? {
        if let hit = memory.object(forKey: key as NSString) {
            return hit as Data
        }
        let file = fileURL(for: key)
        guard let data = try? Data(contentsOf: file) else { return nil }
        // TTL 以内存记录的时刻为准；无记录（进程重启后）视为已过期 → 回源。
        guard let stamp = storedAt[key],
              RadarCacheTTL.isFresh(storedAt: stamp, now: now, ttl: RadarCacheTTL.tile) else {
            return nil
        }
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }

    // MARK: - 取（含并发闸 / 去重 / 占位图拒收）

    /// 取一张瓦片：命中则直接返回，否则经并发闸拉取。
    ///
    /// - Parameters:
    ///   - url: 瓦片 URL（调用方须已用 `RadarTileURLBuilder` 钳制 zoom）。
    ///   - key: 缓存键。
    ///   - now: 当前时刻（注入）。
    /// - Returns: 成功即瓦片字节；占位图 / 失败 → `.failure`（**绝不返回灰图**）。
    func load(url: URL, key: String, now: Date) async -> Outcome {
        if let cached = data(forKey: key, now: now) {
            return .success(cached)
        }
        // 同键在途 → 挂到已有请求上，避免重复回源（也顺带压低并发）。
        if waiters[key] != nil {
            return await withCheckedContinuation { continuation in
                waiters[key]?.append(continuation)
            }
        }
        return await withCheckedContinuation { continuation in
            waiters[key] = [continuation]
            Task { await self.startRequest(url: url, key: key, now: now) }
        }
    }

    /// 真正发起一次网络请求（内部：`waiters` 已就绪）。
    private func startRequest(url: URL, key: String, now: Date) async {
        // 并发闸 + 最小间隔：超限时**排队等待**，而不是硬发（实测会被掐）。
        while !RadarConcurrencyGate.admits(active: activeRequests) {
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50 ms
        }
        let sinceLast = now.timeIntervalSince(lastRequestEpoch)
        if sinceLast < RadarTileCachePolicy.minimumRequestInterval {
            // `max(0, ·)`：UInt64(负 Double) 会**trap 崩溃**，而时钟回拨 / 注入
            // 的 now 早于上次发起时刻都可能让差值为负 —— 故显式夹紧。
            let waitSeconds = max(0, RadarTileCachePolicy.minimumRequestInterval - sinceLast)
            try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
        }
        activeRequests += 1
        lastRequestEpoch = now.timeIntervalSince1970

        var outcome: Outcome = .failure
        if let data = await fetchData(url: url) {
            // 占位图（错模板 / 超 zoom 的灰图）→ 判失败，**不写缓存、不返回**。
            if !RadarPlaceholderDetector.isPlaceholder(data), RadarPlaceholderDetector.isPNG(data) {
                store(data, forKey: key, now: now)
                outcome = .success(data)
            }
        }

        activeRequests -= 1
        finish(key: key, outcome: outcome)
    }

    /// 网络取字节（非 2xx / 非 PNG 一律 nil）。
    private func fetchData(url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              data.isEmpty == false else { return nil }
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            return nil
        }
        return data
    }

    /// 广播结果给所有等待者并清理在途登记。
    private func finish(key: String, outcome: Outcome) {
        let pending = waiters.removeValue(forKey: key) ?? []
        for continuation in pending {
            continuation.resume(returning: outcome)
        }
    }

    // MARK: - 写

    /// 写入缓存（内存 + 磁盘 + TTL 时刻）。
    private func store(_ data: Data, forKey key: String, now: Date) {
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        storedAt[key] = now
        let file = fileURL(for: key)
        // `try?`：写失败（磁盘满 / 目录不存在）不应让整条瓦片链路失败，
        // 内存已缓存，最坏只是下次多回源一次。
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        trimDisk()
    }

    /// 磁盘 LRU 淘汰。
    private func trimDisk() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: diskDirectory.path) else { return }
        var candidates: [RadarDiskEviction.Candidate] = []
        for name in names {
            let url = diskDirectory.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate,
                  let size = values.fileSize else { continue }
            candidates.append(RadarDiskEviction.Candidate(url: url, modifiedAt: modified, size: size))
        }
        for url in RadarDiskEviction.filesToEvict(candidates,
                                                  capacityBytes: RadarTileCachePolicy.diskBytes) {
            try? fm.removeItem(at: url)
        }
    }

    /// 缓存文件名（键含 `framePath` 的 `/`，必须哈希，不能直接拼）。
    private func fileURL(for key: String) -> URL {
        diskDirectory.appendingPathComponent(Self.stableHash(key) + ".png")
    }

    /// 稳定哈希（djb2，仅用于文件名，**非安全用途**）。
    ///
    /// 用自定义实现而非 `Hasher`：Swift 的 `hashValue` **每个进程都不同**，
    /// 会让磁盘缓存跨启动全部失效。djb2 逐字确定 → 跨启动稳定命中。
    static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return String(hash, radix: 36)
    }
}

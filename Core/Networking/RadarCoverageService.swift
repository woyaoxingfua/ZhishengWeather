//
//  RadarCoverageService.swift
//  Core / Networking  [App + Widget 共用]
//
//  雷达**覆盖范围**探测 —— 「该不该对这个城市发瓦片请求」的**唯一判据真源**。
//
//  ══════════════════════════════════════════════════════════════════════════
//  ⚠️ 为什么不按「内陆 / 沿海」做条件接入（实测推翻的错误前提）
//  ══════════════════════════════════════════════════════════════════════════
//  交办时的前提是「内陆城市返回全 null（北京无回波），所以内陆不该发请求」。
//  **实测不成立**（2026-10-06 帧 `/v2/radar/0633024d43f5`，10 城实测）：
//
//  | 城市 | 覆盖端点 | z6 一屏 3×3 内有回波的瓦片数 | 最大色彩数 |
//  |------|---------|----------------------------|-----------|
//  | 北京（内陆） | **有覆盖**（全透明） | 1 | 17 |
//  | 成都（内陆） | 有覆盖 | 5 | 56 |
//  | 西安（内陆） | 有覆盖 | 4 | 43 |
//  | 兰州（内陆） | 有覆盖 | 4 | 43 |
//  | 乌鲁木齐（内陆） | 有覆盖 | 6 | 46 |
//  | 青岛 / 上海 / 广州 / 东京 / 纽约 | 有覆盖 | 5 / 6 / 9 / 5 / 5 | 33–64 |
//
//  **10/10 城全部「有覆盖」，5 个内陆城市全部有真实回波。**
//
//  原因：「有没有回波」是**天气事实**（随当日对流变化），不是**地理事实**。
//  用经纬度/是否沿海当判据 = 把天气状态硬编码成地理常量，后果是：
// 内陆恰恰是强对流（雷暴/冰雹）最高发处 —— 按该判据，北京/成都/西安会在
// **夏季雷暴时（用户最需要雷达的时刻）静默无雷达**，且 CI 全绿、测试全过、
// 功能看似存在。这是典型的**静默功能缺失**，比"多发几个请求"危险得多。
//
//  ✅ 正确判据：RainViewer **官方覆盖端点**（基础设施事实，稳定不变）：
//    `/v2/coverage/0/{size}/{z}/{x}/{y}/0/0_0.png`
//    语义（官方）：**有覆盖 = 全透明，无覆盖 = 黑**。
//  故只有 `.notCovered`（真盲区）才跳过瓦片请求；天气性无回波交给
//  `RadarAvailability.resolve` → `.radarUnavailable(.noEchoCoverage)`，
//  **地图页仍可进并显式说明**，不静默隐藏。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

// MARK: - 覆盖三态

/// 某坐标处的雷达覆盖状态。
enum RadarCoverage: Equatable, Sendable {

    /// 有覆盖（官方语义：覆盖瓦片**全透明**）。
    case covered

    /// 无覆盖（官方语义：覆盖瓦片为**黑**）—— 服务盲区，**不该反复回源**。
    case notCovered

    /// 未知（探测失败 / 非 2xx / 解码失败）。
    ///
    /// ⚠️ **必须与 `notCovered` 严格区分**：`unknown` 时**照常请求**瓦片
    /// （宁可多请求一次，也不能因探测失败而让功能静默消失）。
    case unknown

    /// 是否应跳过瓦片请求。
    ///
    /// **只有确定无覆盖才跳过** —— 这是"防静默功能缺失"的关键：
    /// 把 `unknown` 也算成"跳过"会让一次网络抖动永久关掉一个城市的雷达。
    var shouldSkipTileRequests: Bool {
        self == .notCovered
    }

    /// 覆盖态 → 展示文案（供诊断；nil = 无需展示）。
    var diagnosticText: String? {
        switch self {
        case .covered:   return "有覆盖"
        case .notCovered: return "服务盲区（无覆盖）"
        case .unknown:   return "覆盖探测未成功（按有覆盖处理）"
        }
    }
}

// MARK: - 覆盖瓦片判读（纯函数，可单测）

/// 覆盖瓦片的**纯判读**部分（不含网络、不含解码，便于逐点单测）。
///
/// ⚠️ 判据只能用**黑色像素占比**，**不能**用字节数 —— 字节数已被实测证伪：
/// 北京（有覆盖）914 B 与南太平洋中部（无覆盖）**同为 914 B**，
/// 而里约（有覆盖，1592 B）比它们大得多。字节数与覆盖**无单调关系**。
enum RadarCoverageTileReader {

    /// 判读阈值（不透明黑色像素占比）。
    ///
    /// 实测分布（16 个有覆盖点 + 10 个远海点，z6）：
    ///  · 有覆盖：0.0 – 0.8897（北京 0.0、纽约 0.0、悉尼 0.0、开罗 0.8897、
    ///            秘鲁高原 0.5185）
    ///  · 无覆盖：**全部恰为 1.0**（10/10 远海点，精确 1.0）
    ///
    /// 取 **0.95**：唯一可靠的分离信号是"纯黑 = 1.0"。0.95 距有覆盖上界
    /// （开罗 0.8897）留有余量，又不会把 1.0 判成有覆盖。
    ///
    /// 为什么不用 0.5：开罗 0.8897、秘鲁 0.5185 都是**有覆盖**的（服务存在，
    /// 只是覆盖稀疏），按 0.5 会把它们误判成盲区 → 静默关掉埃及/秘鲁的雷达。
    static let blackRatioThreshold = 0.95

    /// 「黑」的判据：`max(r, g, b) <= 32`（覆盖纯黑 0，也容忍压缩噪点到 30）。
    static let blackChannelCeiling: UInt8 = 32

    /// 「不透明」的 alpha 下限。
    static let alphaThreshold: UInt8 = 8

    /// 判读 → 覆盖态。
    ///
    /// - Parameters:
    ///   - totalPixels: 瓦片总像素数。
    ///   - blackRatio: 不透明黑色像素占比（0–1）。
    ///   - decoded: 是否成功解码（false → nil 语义）。
    /// - Returns: 覆盖态；无法判读 → `.unknown`（**不**误判为无覆盖）。
    static func coverage(totalPixels: Int, blackRatio: Double, decoded: Bool) -> RadarCoverage {
        guard decoded, totalPixels > 0, blackRatio.isFinite else { return .unknown }
        return blackRatio >= blackRatioThreshold ? .notCovered : .covered
    }

    /// 像素判读辅助：给定 RGBA 字节数组，数出「不透明且黑」的像素数与总像素数。
    ///
    /// 放 Core 是因为它**只是数数**（无图像库依赖）；真正的 PNG 解码在 App 侧
    /// （Core 内不得 import CoreGraphics/UIKit，见 SC-12 白名单）。
    ///
    /// - Parameter rgba: 连续的 RGBA 字节（长度 = 像素数 × 4）。
    /// - Returns: (总像素数, 不透明黑色像素数)；长度非 4 倍数 → (0, 0) 表示不可判读。
    static func countOpaqueBlack(rgba: [UInt8]) -> (total: Int, black: Int) {
        guard rgba.count >= 4, rgba.count % 4 == 0 else { return (0, 0) }
        var black = 0
        var index = 0
        let alphaCut = Int(alphaThreshold)
        let blackCut = Int(blackChannelCeiling)
        while index + 3 < rgba.count {
            let a = Int(rgba[index + 3])
            if a > alphaCut {
                let r = Int(rgba[index])
                let g = Int(rgba[index + 1])
                let b = Int(rgba[index + 2])
                let peak = max(r, max(g, b))
                if peak <= blackCut { black += 1 }
            }
            index += 4
        }
        return (rgba.count / 4, black)
    }

    /// 由像素统计得出占比（四舍五入到 5 位小数，便于逐点断言）。
    static func blackRatio(total: Int, black: Int) -> Double {
        guard total > 0 else { return 0 }
        return (Double(black) / Double(total) * 100_000).rounded() / 100_000
    }
}

// MARK: - 覆盖探测服务

/// 覆盖探测（actor）。
///
/// 只在**进入雷达页 / 切城市**时探测一次（结果进内存三态），
/// **不随瓦片请求重复打** —— 覆盖是基础设施事实，没必要反复问。
actor RadarCoverageService {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 覆盖端点 URL 拼装（纯函数，便于单测）。
    ///
    /// 官方模板：`/v2/coverage/0/{size}/{z}/{x}/{y}/0/0_0.png`
    /// （`0_0` = 不平滑 + 不显示雪；覆盖图只需形状，无需美化。）
    static func coverageURL(host: String = RadarTileURLBuilder.defaultHost,
                            zoom: Int,
                            x: Int,
                            y: Int) -> URL? {
        guard x >= 0, y >= 0 else { return nil }
        let root = host.hasSuffix("/") ? String(host.dropLast()) : host
        let z = RadarTileZoomRange.clamp(zoom)
        return URL(string: "\(root)/v2/coverage/0/\(RadarTileURLBuilder.tileEdge)/\(z)/\(x)/\(y)/0/0_0.png")
    }

    /// 探测某坐标的覆盖状态。
    ///
    /// - Parameters:
    ///   - latitude: 纬度（WGS84）。
    ///   - longitude: 经度（WGS84）。
    ///   - host: 瓦片宿主。
    ///   - decoder: PNG → RGBA 字节的解码闭包（**由 App 侧注入**）。
    /// - Returns: 覆盖态；**任何失败都返回 `.unknown`**（绝不因探测失败
    ///            而判定"无覆盖" —— 那会让雷达静默消失）。
    ///
    /// ⚠️ `decoder` 由调用方注入而非本类型自带：PNG 解码要 CoreGraphics，
    /// 而 Core/ 被双 target 编译且 SC-12 白名单不含 CoreGraphics/UIKit。
    /// 纯判读（数黑像素）留在本文件的 `RadarCoverageTileReader` 里，可单测。
    func coverage(latitude: Double,
                  longitude: Double,
                  host: String = RadarTileURLBuilder.defaultHost,
                  decoder: @escaping @Sendable (Data) -> [UInt8]?) async -> RadarCoverage {
        // 探测用 z6：分辨率足够判定"是否有覆盖"，又不会太粗。
        let z = 6
        let x = Self.tileX(longitude: longitude, z: z)
        let y = Self.tileY(latitude: latitude, z: z)
        guard let url = Self.coverageURL(host: host, zoom: z, x: x, y: y) else {
            return .unknown
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            return .unknown
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return .unknown
        }
        guard RadarPlaceholderDetector.isPNG(data) else { return .unknown }
        guard let rgba = decoder(data) else { return .unknown }

        let counts = RadarCoverageTileReader.countOpaqueBlack(rgba: rgba)
        let ratio = RadarCoverageTileReader.blackRatio(total: counts.total, black: counts.black)
        return RadarCoverageTileReader.coverage(totalPixels: counts.total,
                                                blackRatio: ratio,
                                                decoded: true)
    }

    /// 经度 → 瓦片列号（标准 XYZ）。
    static func tileX(longitude: Double, z: Int) -> Int {
        let n = Double(1 << z)
        let raw = (longitude + 180.0) / 360.0 * n
        return min(max(Int(floor(raw)), 0), Int(n) - 1)
    }

    /// 纬度 → 瓦片行号（标准 XYZ）。
    static func tileY(latitude: Double, z: Int) -> Int {
        let n = Double(1 << z)
        let clamped = min(max(latitude, -85.05112878), 85.05112878)
        let rad = clamped * .pi / 180.0
        let raw = (1.0 - asinh(tan(rad)) / .pi) / 2.0 * n
        return min(max(Int(floor(raw)), 0), Int(n) - 1)
    }
}

//
//  RadarFrame.swift
//  Core / Models  [App + Widget 共用]
//
//  降水雷达帧 + 时间轴 + **降级四态**（全部为纯值类型 / 纯函数，可直接单测）。
//
//  ── 实测基线（2026-10-06 独立复核，非引用预研报告）────────────────────────
//  · `radar.past` = **13 帧**，`radar.nowcast` = **`[]`（实测空，两次拉取两次空）**。
//    → 设计上**只渲染 past**；nowcast 永远不画（官方文档与实际不符）。
//  · 帧步长 **严格 600 s**（实测步长集合 = {600}），13 帧 × 10 min = **120 分钟**跨度。
//    ⚠️ 预研报告称"130 分钟"，实测为 120（= (13-1)×10）。跨度按实测写。
//  · 瓦片真实最大 zoom = **7**；z8 起返回 1370 B 灰阶占位图。
//  · `weather-maps.json` **免 Key、免注册** → 本文件链路**不引入任何凭据读取**
//    （静态守卫 SC-42 会扫 Keychain；RainViewer 不需要，故不得引入）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

// MARK: - 单帧

/// 一张雷达回波帧。
struct RadarFrame: Identifiable, Equatable, Sendable {

    /// 帧时刻（UTC epoch 秒 → `Date`）。
    let time: Date

    /// 帧资源路径，形如 `/v2/radar/cc4e98e720b0`。
    ///
    /// ⚠️ **不得拼进缓存文件名**：含 `/`，会被当成子目录。缓存键由
    /// `RadarTileCache` 统一做哈希（见该文件）。
    let path: String

    /// 稳定标识（时刻的 epoch 秒字符串；同一帧路径不变）。
    var id: String { String(Int(time.timeIntervalSince1970)) }

    /// 由元数据项构造。
    /// - Parameters:
    ///   - epochSeconds: `time` 字段（UTC epoch 秒）。
    ///   - path: `path` 字段。
    init(epochSeconds: Int, path: String) {
        self.time = Date(timeIntervalSince1970: Double(epochSeconds))
        self.path = path
    }
}

// MARK: - 时间轴

/// 雷达时间轴：**只含 past 帧**（nowcast 实测为空，绝不渲染）。
///
/// 帧数为 0 时本类型**不存在**（构造返回 nil），调用方据此**禁用 scrubber**，
/// 而非显示一个空的滑块（硬要求：绝不能出现空白 scrubber）。
struct RadarTimeline: Equatable, Sendable {

    /// 全部 past 帧，按时刻**升序**（最早在前）。
    let frames: [RadarFrame]

    /// 当前选中帧的下标。
    ///
    /// 约定：**指向"最旧"的那一端为回放中**，指向 `frames.count - 1` 为实况。
    /// 构造时默认取最新帧（`frames.count - 1`）。
    var index: Int

    /// 帧数（0 不可能 —— 构造已保证非空）。
    var count: Int { frames.count }

    /// 选中的帧。
    ///
    /// - 注意: `index` 越界时返回 nil 而不是崩溃（Core 禁 `fatalError`/强制解包）。
    var selected: RadarFrame? {
        guard frames.indices.contains(index) else { return nil }
        return frames[index]
    }

    /// 是否停在最新帧（= 实况，非回放）。
    var isLive: Bool { index == frames.count - 1 }

    /// 取指定下标的帧（**越界安全**）。
    ///
    /// - Parameter index: 目标下标；nil = 最后一帧（实况，即最新帧）。
    /// - Returns: 帧；下标越界 / 时间轴为空 → nil。
    ///
    /// 为什么不直接用 `frames[index]`：Swift 的数组下标越界会**崩溃**，
    /// 而 UI 的 scrubber 在切换城市/帧数变化时会短暂给出越界下标。
    func frame(at index: Int?) -> RadarFrame? {
        guard !frames.isEmpty else { return nil }
        let resolved = index ?? (frames.count - 1)
        guard frames.indices.contains(resolved) else { return nil }
        return frames[resolved]
    }

    /// 当前帧距今多少分钟（用于"数据延迟 N 分钟"的诚实提示）。
    ///
    /// - Parameter now: 当前时刻（**由调用方注入**；Core 禁内部 `Date()`）。
    /// - Returns: 分钟数；无可选帧 → nil。
    func ageMinutes(now: Date) -> Int? {
        guard let frame = selected else { return nil }
        let seconds = now.timeIntervalSince(frame.time)
        guard seconds > 0 else { return 0 }
        return Int(seconds / 60)
    }

    /// 总跨度（分钟）——用于时间轴两端文案。
    ///
    /// - Parameter now: 当前时刻（注入）。
    /// - Returns: 首末帧之间的分钟数；不足 2 帧 → 0。
    func spanMinutes(now: Date) -> Int {
        guard let first = frames.first, let last = frames.last else { return 0 }
        let seconds = now.timeIntervalSince(first.time) - now.timeIntervalSince(last.time)
        guard seconds > 0 else { return 0 }
        return Int(seconds / 60)
    }

    /// 切换选中帧（**自动夹紧**到合法范围，绝不越界）。
    /// - Parameter newIndex: 目标下标。
    mutating func select(_ newIndex: Int) {
        guard !frames.isEmpty else { return }
        index = min(max(newIndex, 0), frames.count - 1)
    }

    // MARK: - 构造（含排序与去重）

    /// 由元数据帧列表构造时间轴：**排序 + 去重 + 丢弃非法项**。
    ///
    /// 去重口径：同一 `time` 只保留**首次出现**者（实测元数据本身无重复，
    /// 但这是"外部输入"的防御，不能假设服务端永远干净）。
    ///
    /// - Parameter raw: 元数据里的 past 帧（顺序不保证）。
    /// - Returns: 排序去重后的时间轴；**无一有效帧 → nil**（调用方须降级，
    ///            绝不可拿空数组去渲染 scrubber）。
    static func make(from raw: [RadarFrame]) -> RadarTimeline? {
        // 丢弃空路径（无路径 = 无从请求瓦片）。
        let usable = raw.filter { !$0.path.isEmpty }
        guard !usable.isEmpty else { return nil }

        // 按时刻升序；同一时刻按路径字典序做**确定性** tie-break，
        // 避免 `sorted(by:)` 在等值元素下返回不同顺序（可测性要求）。
        let sorted = usable.sorted { lhs, rhs in
            if lhs.time != rhs.time { return lhs.time < rhs.time }
            return lhs.path < rhs.path
        }
        // 按时刻去重（相邻去重即可，因为已排序）。
        var deduped: [RadarFrame] = []
        deduped.reserveCapacity(sorted.count)
        for frame in sorted {
            if let last = deduped.last, last.time == frame.time { continue }
            deduped.append(frame)
        }
        guard !deduped.isEmpty else { return nil }
        // 默认停在最新帧。
        return RadarTimeline(frames: deduped, index: deduped.count - 1)
    }
}

// MARK: - 降级四态

/// 雷达卡的**降级四态**（穷尽，**绝不允许出现空白地图页**）。
///
/// 四态与判定的对应关系（判定入口唯一：`RadarAvailability.resolve`）：
///
/// | 态 | 判定 | 地图区 | 时间轴 |
/// |---|---|---|---|
/// | `.radar` | `past` 非空 | 底图 + 回波层 | 13 档 scrubber |
/// | `.forecast`(.domesticHourly) | 境内城市但 `past` 为空 | 底图 | **禁用** |
/// | `.forecast`(.overseasTwoHour) | 境外城市（不展示回波） | 底图 | **禁用** |
/// | `.radarUnavailable` | 取数失败 / 全透明 | 底图 + 说明 | **禁用** |
enum RadarAvailability: Equatable, Sendable {

    /// 有真实回波。
    case radar

    /// 降级为模型概率（**仍给出可看的替代内容**，不是空白页）。
    case forecast(RadarForecastKind)

    /// 雷达不可用（网络失败 / 解码失败 / 全透明）——**地图页仍可进**。
    case radarUnavailable(RadarUnavailableReason)

    /// 是否应叠加回波图层（只有 `.radar` 为 true）。
    var showsRadarTiles: Bool { self == .radar }

    /// 时间轴是否可交互。
    ///
    /// **只有 `.radar` 为 true** —— 其余三态一律禁用 scrubber
    /// （硬要求：帧数 0 时禁用，而不是显示空滑块）。
    var allowsScrubbing: Bool { self == .radar }

    /// 顶部结论句（**文案单一真源**，视图不拼字符串；不含时刻，时刻由 UI 按时区渲染）。
    var headline: String {
        switch self {
        case .radar:
            return "雷达回波 · RainViewer 全球合成"
        case .forecast(.domesticHourly):
            return "本区域暂无实时回波 · 显示逐时降水概率"
        case .forecast(.overseasTwoHour):
            return "境外区域 · 显示未来 2 小时降水概率条"
        case .radarUnavailable(let reason):
            return reason.headline
        }
    }
}

/// `.forecast` 的两种口径。
enum RadarForecastKind: Equatable, Sendable {

    /// 境内：逐时降水概率（来自既有的国内预报链路）。
    case domesticHourly

    /// 境外：未来 2 小时概率条。
    case overseasTwoHour

    /// 用户可见的短标签。
    var label: String {
        switch self {
        case .domesticHourly:  return "逐时概率"
        case .overseasTwoHour: return "2 小时概率条"
        }
    }
}

/// 雷达不可用的原因（**穷尽**，每种都有对应文案，绝不出现"原因不明"）。
enum RadarUnavailableReason: Equatable, Sendable {

    /// 取数失败（网络 / 非 2xx / 解码失败）。
    case fetchFailed

    /// 元数据里一帧都没有（`past` 为空数组）。
    case noFrames

    /// 该区域不在纠偏/覆盖判定内，或回波层全透明。
    case noEchoCoverage

    /// 顶部结论句。
    var headline: String {
        switch self {
        case .fetchFailed:      return "雷达图加载失败 · 下方为模型预报"
        case .noFrames:         return "本区域暂无实时回波 · 下方为模型概率"
        case .noEchoCoverage:   return "本区域暂无实时回波 · 下方为模型概率"
        }
    }

    /// 是否值得给"重试"入口（网络类失败才值得；无回波重试无意义）。
    var allowsRetry: Bool {
        self == .fetchFailed
    }
}

// MARK: - 四态判定（纯函数，唯一入口）

extension RadarAvailability {

    /// 由「是否境外」+「取数结果」+「现在时刻」裁定四态。
    ///
    /// 判定顺序（**不可调换**，短路语义）：
    /// 1. 取数失败 → `.radarUnavailable(.fetchFailed)`；
    /// 2. `past` 为空 → 境外给 `.forecast(.overseasTwoHour)`，
    ///    境内给 `.forecast(.domesticHourly)`；
    /// 3. 取数成功且有帧 → `.radar`。
    ///
    /// ⚠️ 境外城市**即便取到帧也走 `.forecast`** —— 一期产品裁定：境外优先展示
    /// 本 App 的模型概率，不叠回波（避免"境外回波精度不如本地源"的误导，
    /// 也避免用户拿它和当地官方雷达比）。这是**产品取舍**，不是数据能力问题。
    ///
    /// - Parameters:
    ///   - timeline: 时间轴；nil = 无有效帧。
    ///   - isOverseas: 城市是否在中国境外。
    ///   - fetchFailed: 取数是否失败。
    /// - Returns: 四态之一（**恒有值**，不含"加载中"—— 加载中由 UI 用 ProgressView 表达）。
    static func resolve(timeline: RadarTimeline?,
                        isOverseas: Bool,
                        fetchFailed: Bool) -> RadarAvailability {
        if fetchFailed {
            return .radarUnavailable(.fetchFailed)
        }
        guard let timeline, !timeline.frames.isEmpty else {
            return .forecast(isOverseas ? .overseasTwoHour : .domesticHourly)
        }
        if isOverseas {
            return .forecast(.overseasTwoHour)
        }
        return .radar
    }
}

//
//  WidgetDiagnostics.swift
//  Core / Logic  [App + Widget 共用]
//
//  小组件时间线的**可诊断性**设施：让真机能区分「系统没调我们」/「调了但取数失败」
//  /「取到了但渲染不出来」三种情况。
//
//  ── 为什么此前判不了（这是本文件存在的唯一理由）────────────────────────────
//  docs/handover/DEVICE-VERIFICATION.md §8.3 第3 条白纸黑字写着：
//    「系统是否真调用过 `timeline(for:)` —— 无日志、无埋点、无计数器。」
//  用户在真机上只能看到「没数据」，**无法区分**问题出在哪一层：
//    · 系统根本没调timeline（系统侧 / AppIntents 侧问题，不是我们的代码）；
//    · 调了但取数失败（网络 / 解码 / 城市解析）；
//    · 取到了但渲染不出来（视图层）。
//  故本文件提供**每条 timeline 必有**的成对日志（enter / exit），
//  中间各层各自补一行，使三态在 Console 里可直接读出。
//
//  ── 为什么不写进 AppDiagnosticsStore ────────────────────────────────────────
//  `AppDiagnosticsStore` 落在**主 App target**（`ZhishengWeather/`，见 project.yml
//  的 sources），**Widget target 编译不到它**；而反过来 widget 进程写自己的
//  `UserDefaults.standard` 落在**扩展自己的沙盒**，主 App **永远读不到**
//  ——这与App Group 可用性**无关**，是沙盒边界本身。
//  ⇒ 故小组件侧一律走 `os_log`（subsystem 固定，见 `WeatherLog`），
//  主 App 侧能自己观察到的部分（系统登记了几个实例）另落`AppDiagnosticsStore`。
//  **绝不为此引入 App Group**（侧载产物上恒为空，见 AppGroupStore.swift:200）。
//
//  ── 凭据纪律（本文件的首要硬约束）──────────────────────────────────────────
//  本仓数据源带 CC BY 4.0 署名要求，且**任何**端点都可能在 URL 上挂 key。
//  故 `redactedEndpoint(_:)` 采用**白名单式**脱敏（不是黑名单式）：
//    · URL 的 **query value 只有名字在 `diagnosticQueryKeys` 里时才输出**；
//    · 其余 query 参数**一律只输出参数名，值无条件丢弃**（不判断是否敏感，
//      因为「未来新增一个带 key 的参数」这件事无法靠黑名单防住）；
//    · `URLComponents` 解析失败 → 返回 "-"，**绝不退回 `absoluteString`**
//      （那会把整条 query 连key 一起打出来）。
//  ⇒ 结构性保证：**任何 query value 都不可能出现在日志里**，除非它的参数名
//  显式列进了白名单，而白名单里只有经纬度两项。
//  单测见 `ZhishengWeatherTests/WidgetTraceRedactionTests.swift`。
//
//  ── 另一条纪律：不打 localizedDescription ───────────────────────────────────
//  `URLError` / `DecodingError` 的 `localizedDescription` 可能回显请求 URL。
//  故本文件的所有错误标记**只打自定义 token**，绝不打原始描述文本。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

// MARK: - 状态 token（进日志的稳定口径）

extension WidgetPayloadStatus {

    /// 日志 token（稳定短串；文档里的判读表按这一列查）。
    var traceToken: String {
        switch self {
        case .available: return "available"
        case .stale: return "stale"
        case .missing: return "missing"
        case .unavailable: return "unavailable"
        }
    }
}

extension WidgetDataSource {

    /// 日志 token（稳定短串）。
    var traceToken: String {
        switch self {
        case .sharedContainer: return "container"
        case .selfFetched: return "selfFetched"
        case .none: return "none"
        }
    }
}

extension WidgetEmptyReason {

    /// 日志 token（稳定短串）。
    ///
    /// ⚠️ 判读表里最关键的一列：`fetchFailed` 与 `cityHasNoData` 都发生在
    /// 「已经调了timeline」之后，二者的用户动作完全不同（查网络 vs 换城市），
    /// 故必须能在日志里分开。
    var traceToken: String {
        switch self {
        case .noCity: return "noCity"
        case .noCachedData: return "noCachedData"
        case .sharedContainerDown: return "containerDown"
        case .fetchFailed: return "fetchFailed"
        case .cityHasNoData: return "cityHasNoData"
        case .locationNotAuthorized: return "locNotAuthorized"
        case .locationUnavailable: return "locUnavailable"
        }
    }
}

extension WidgetCityOutcome {

    /// 日志 token（稳定短串）。
    var traceToken: String {
        switch self {
        case .resolved: return "resolved"
        case .needsConfiguration: return "needsConfig"
        case .locationNotAuthorized: return "locNotAuthorized"
        case .locationUnavailable: return "locUnavailable"
        }
    }
}

extension WidgetCityResolver.Mode {

    /// 日志 token（稳定短串；`.fixed` 额外带出城市 id —— 「配置读回成什么」的唯一证据）。
    var traceToken: String {
        switch self {
        case .followApp: return "followApp"
        case .currentLocation: return "currentLocation"
        case .fixed(let cityID): return "fixed(\(cityID))"
        }
    }
}

extension WeatherError {

    /// 日志 token（稳定短串；**不含 `localizedDescription`**，见文件头纪律）。
    ///
    /// `decodingDetail` 带出 `path`（字段路径，如 `hourly.time`）——这是 run37
    /// 真机事故复盘里唯一有用的线索（见 `ResponseDecoding`），必须保留。
    /// 其余 case 一律只给类型名。
    var traceToken: String {
        switch self {
        case .badURL: return "badURL"
        case .badStatus(let code): return "badStatus(\(code))"
        case .network: return "network"
        case .decoding: return "decoding"
        case .timeout: return "timeout"
        case .decodingDetail(let path, _): return "decodeFail(path=\(path))"
        case .dataMissing: return "dataMissing"
        case .appGroup: return "appGroup"
        }
    }
}

// MARK: - 日志出口

/// 小组件时间线追踪（`os_log`，两个 target 都编）。
///
/// ⚠️ 日志量的克制：本类型**每个 timeline 调用固定产出 5~6 行**
/// （enter / city / fetch-start / fetch-status / fetch-outcome / exit），
/// 其中 fetch 三行**仅在真的发请求时**才出现（L0 命中 / 无城市时不发）。
/// 系统对每实例的刷新预算是每小时数次量级，故此量级不构成刷屏。
enum WidgetTrace {

    /// query 参数值**允许**出现在日志里的白名单（仅经纬度，二者均非凭据）。
    ///
    /// ⚠️ 新增条目前必须确认它**不是**凭据；本白名单是「白名单式脱敏」的唯一出口。
    static let diagnosticQueryKeys: Set<String> = ["latitude", "longitude"]

    // MARK: 序号传播

    /// 当前这轮时间线的关联序号（供**拿不到 seq 参数的深层调用**取用）。
    ///
    /// ── 为什么需要它 ──────────────────────────────────────────────────────
    /// `WeatherService.fetch(latitude:longitude:)` 是 `WeatherProviding` 的协议签名，
    /// **塞不进 seq**（改协议会波及全部5 条数据链路与既有单测桩）。
    /// 而「HTTP 状态码」只在它的函数体内拿得到 —— 这恰恰是判读表里最关键的一行。
    /// ⇒ 用 `TaskLocal` 把 seq 顺着调用链带下去（Swift 结构化并发会自动传播到
    /// 子任务，故 `WidgetDataResolver.fetchWithBudget` 的 `group.addTask` 里也读得到）。
    ///
    /// 默认 0 = 「不在小组件时间线上下文中」（例如主 App 自己取数），
    /// 此时状态码那行仍会打，只是序号为 0 —— 不会误导，也不会丢。
    @TaskLocal static var seq: Int = 0

    /// 当前关联序号（`@TaskLocal` 的只读入口）。
    static var currentSeq: Int { seq }

    // MARK: 计数器（线程安全）

    /// 自增计数器（`NSLock` 保护；`timeline` 可能被并发调用）。
    private static let counter = TraceCounter()

    // MARK: - timeline 生命周期（成对，必须都有）

    /// `timeline(for:)` / `snapshot(for:)` 被系统调用（**每次必有一条**）。
    ///
    /// 这是「系统到底有没有调我们」的唯一判据 —— 它缺失即意味着
    /// 问题在系统侧 / AppIntents 侧，不在我们的代码里。
    ///
    /// - Parameters:
    ///   - call: `"timeline"` / `"snapshot"` / `"placeholder"`。
    ///   - family: 尺寸（`context.family` 的真实值）。
    ///   - isPreview: 是否画廊预览（`context.isPreview`）。
    ///   - mode: 城市配置模式（`.fixed(id)` 会带出城市 id）。
    /// - Returns: 本次调用的序号（供调用方拼进后续日志行做关联）。
    @discardableResult
    static func enter(call: String,
                      family: String,
                      isPreview: Bool,
                      mode: WidgetCityResolver.Mode) -> Int {
        let seq = counter.next()
        emit("#\(seq) \(call) ENTER family=\(family) preview=\(isPreview ? 1 : 0) mode=\(mode.traceToken)")
        return seq
    }

    /// `placeholder(in:)` 被系统调用（画廊/ 首屏占位）。
    ///
    /// ⚠️ 此处**不带城市配置**：`placeholder(in:)` 的签名里没有 Intent 参数
    /// （对比 `timeline(for:in:)` 的第一个参数），系统此时尚未把用户配置交给我们。
    /// 故本行只有 family / preview —— 这本身就是判读信息。
    ///
    /// - Parameters:
    ///   - family: 尺寸。
    ///   - isPreview: 是否画廊预览。
    static func placeholder(family: String, isPreview: Bool) {
        let seq = counter.next()
        emit("#\(seq) placeholder ENTER family=\(family) preview=\(isPreview ? 1 : 0) mode=none")
    }

    /// 在给定序号的作用域内执行 `body`（使 `currentSeq` 在整条调用链上可读）。
    ///
    /// 所有真正需要打关联日志的入口（`timeline` / `snapshot`）都**必须**经此包装，
    /// 否则深层（如 `WeatherService`）读到的仍是默认 0。
    ///
    /// - Parameters:
    ///   - seq: 本轮序号。
    ///   - body: 工作体。
    /// - Returns: `body` 的返回值。
    static func withSeq<T>(_ seq: Int, _ body: () async throws -> T) async rethrows -> T {
        try await WidgetTrace.$seq.withValue(seq) {
            try await body()
        }
    }

    /// 时间线组装完毕（**每次必有一条**，与 enter 成对）。
    ///
    /// - Parameters:
    ///   - seq: `enter` 返回的序号。
    ///   - call: `"timeline"` / `"snapshot"`。
    ///   - resolution: 收敛值。
    static func exit(seq: Int,
                     call: String,
                     resolution: WidgetEntryResolution) {
        emit("#\(seq) \(call) EXIT status=\(resolution.status.traceToken)"
             + " source=\(resolution.dataSource.traceToken)"
             + " empty=\(resolution.emptyReason?.traceToken ?? "-")"
             + " hasPayload=\(resolution.hasPayload ? 1 : 0)")
    }

    /// 城市阶梯产出（每次一条）。
    static func city(seq: Int, outcome: WidgetCityOutcome, cityID: String?) {
        emit("#\(seq) CITY outcome=\(outcome.traceToken) cityID=\(cityID ?? "-")")
    }

    /// 进入 L1 取数（含脱敏后的请求地址）。
    static func fetchStart(seq: Int, url: URL?) {
        emit("#\(seq) FETCH start endpoint=\(redactedEndpoint(url))")
    }

    /// 拿到 HTTP 响应（状态码 + 字节数）。
    ///
    /// - Parameters:
    ///   - seq: 关联序号。
    ///   - statusCode: HTTP 状态码（**这是「取数失败」最重要的一条判据**：
    ///     403/429 与 5xx 与「非 HTTP 响应」的处置完全不同）。
    ///   - byteCount: 响应体字节数（0 字节 + 200 = 上游返回空体，是个真实故障形态）。
    static func fetchResponse(seq: Int, statusCode: Int, byteCount: Int) {
        emit("#\(seq) FETCH http=\(statusCode) bytes=\(byteCount)")
    }

    /// L1 取数终局（成功 / 失败原因 token）。
    static func fetchOutcome(seq: Int, error: WeatherError?) {
        emit("#\(seq) FETCH end result=\(error?.traceToken ?? "ok")")
    }

    // MARK: - 出口

    /// 唯一日志出口。
    ///
    /// ⚠️ 用的是 `Logger.notice(_: String)` 这个重载（**不是** `OSLogMessage` 那个）：
    /// 后者要求传**字面量插值**，且 `privacy:` 只能标在字面量的插值上，
    /// 无法接受一个已经拼好的 `String` 变量。故此处走 String 重载。
    ///
    /// ⚠️ 该重载**不做** os_log 脱敏（它按「调用者已自担脱敏」处理）——
    /// 这正是这里想要的：所有字段都已在各调用点脱敏完毕
    /// （URL 走 `redactedEndpoint`、错误走 `traceToken`），**无凭据可泄漏**。
    /// 代价：日志不会显示 `<private>` 占位，真机 Console 里**看得见全文**
    ///（这与 `ResponseDecoding` 走`privacy: .public` 的目的一致，见 WeatherLog 文件头）。
    ///
    /// ⚠️ 这也是本文件**唯一**允许构造日志文本的地方 —— 纪律：
    /// 任何新日志都必须经 `emit`，不得直接调 `WeatherLog.widget`，
    /// 否则「内容已脱敏」这个前提就失效了。
    ///
    /// - Parameter message: 已脱敏的单行文本。
    private static func emit(_ message: String) {
        WeatherLog.widget.notice(message)
    }

    // MARK: - 脱敏

    /// 脱敏后的请求地址（**白名单式**，见文件头「凭据纪律」）。
    ///
    /// 行为规格：
    ///   · 形如 `https://host/path?latitude=30.28&longitude=120.16&current&hourly`；
    ///   · 白名单参数输出 `名=值`，其余参数**只输出名**；
    ///   · 无 query → `https://host/path`；
    ///   · `url` 为 nil 或 `URLComponents` 解析失败 → `"-"`。
    ///
    /// ⚠️ 解析失败**不退回 `url.absoluteString`** —— 那会把整条 query 连同
    /// 可能存在的 key 原样打出，是本文件唯一能想到的凭据泄漏路径。
    ///
    /// - Parameter url: 原始请求地址（可nil）。
    /// - Returns: 脱敏后的可读地址。
    static func redactedEndpoint(_ url: URL?) -> String {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "-"
        }
        var text = "\(components.scheme ?? "https")://\(components.host ?? "-")\(components.path)"
        let items = components.queryItems ?? []
        guard !items.isEmpty else { return text }
        let rendered = items.map { item -> String in
            guard let value = item.value, diagnosticQueryKeys.contains(item.name) else {
                // 值无条件丢弃：只留参数名。
                return item.name
            }
            return "\(item.name)=\(value)"
        }
        text += "?" + rendered.joined(separator: "&")
        return text
    }
}

// MARK: - 计数器实现

/// 自增计数器（`NSLock` 保护，故可安全地被多个 timeline 并发调用）。
///
/// `@unchecked Sendable`：临界区内的可变状态由 `lock` 保护，语义上等价于
/// 串行；但 Swift 无法表达「一把锁保护的计数器是 Sendable」，故显式标注。
/// ⚠️ 本仓 `SWIFT_STRICT_CONCURRENCY: minimal`（project.yml:73），此标注不是
/// 编译必需，而是让未来上调到 strict 时不必回头补。
private final class TraceCounter: @unchecked Sendable {

    private let lock = NSLock()
    private var value: Int = 0

    /// 取下一个序号（从 1 开始）。
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

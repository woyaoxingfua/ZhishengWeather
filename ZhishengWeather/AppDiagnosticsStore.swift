//
//  AppDiagnosticsStore.swift
//  ZhishengWeather（主 App target）
//
//  App 侧诊断记录的**统一读写层**（换图标 / 实时活动 / 小组件时间线共用一份）。
//
//  为什么必须有这一层：本 App 走**未签名 / 免签重签**分发，真机上的失败
//  （换图标被系统拒、实时活动起不来）在屏幕上只「闪一下」就没了 —— 用户既
//  看不清内容，也复现不了，更没法截图反馈。诊断记录把每一次**成功与失败**
//  都留在本地，设置页随时可读；失败记录**必带 NSError 的 domain + code**
//  （侧载场景里 `localizedDescription` 常是一句泛化的「操作无法完成」，
//  只有 domain + code 是可判定的信息）。
//
//  ⚠️ 存储位置必须是 **App 本地 `UserDefaults.standard`**，绝不能走 App Group
//  共享容器：本分发渠道的 entitlements 不生效 → 共享容器恒不可用（判据见
//  `AppGroupStore.isSharedContainerAvailable`），写进共享容器等于什么都没写。
//
//  纪律：
//  - **单 key 单值**：整份日志是**一个** Codable 结构、落在**一个** key 上；
//    按来源各保留最近**一条**（换图标的实时记录不会被小组件重载挤掉）。
//  - **绝不拖累主流程**：读写全在 `do/catch` 内，编解码失败只打印日志，
//    绝不抛出、绝不 `try!`；诊断写失败不允许改变换图标 / 实时活动的返回值。
//  - **不伪造**：没有 error 出口的调用只记成功，绝不为凑「失败分支」编造。
//  - **可注入**：`defaults` 可注入，单测用独立 suite，不污染 standard。
//  - 仅 import Foundation（不引 UIKit），与偏好层同款纯度。
//

import Foundation

/// 诊断记录的来源（落盘用 `rawValue` 作字典键，新增来源只改这一处）。
enum AppDiagnosticSource: String, Codable, Sendable, CaseIterable {

    /// 换图标（`UIApplication.setAlternateIconName`）。
    case appIcon
    /// 实时活动（ActivityKit 的 request / update / end）。
    case liveActivity
    /// 小组件时间线重载（`WidgetCenter.reloadAllTimelines()`）。
    case widgetTimeline

    /// 面向用户的来源名（设置页展示用）。
    var displayName: String {
        switch self {
        case .appIcon:
            return "换图标"
        case .liveActivity:
            return "实时活动"
        case .widgetTimeline:
            return "小组件时间线"
        }
    }
}

/// 一次诊断结果（结构化、Codable 落盘）。
struct AppDiagnosticEntry: Codable, Equatable, Sendable {

    /// 来源。
    let source: AppDiagnosticSource
    /// 这次调用是成功还是失败。
    let succeeded: Bool
    /// 操作对象（换图标 = 目标图标资源名；实时活动 = 城市标识；时间线重载 = 方法名）。
    let target: String
    /// 完整描述（失败时为面向用户的短句，**含 NSError 的 domain + code**）。
    let message: String
    /// 失败时的错误域（成功为 nil）。
    let errorDomain: String?
    /// 失败时的错误码（成功为 nil）。
    let errorCode: Int?
    /// 发生时刻（跨来源比较「最近一次」用）。
    let occurredAt: Date
    /// 发生时刻的 HH:mm:ss 文本（**落盘时**格式化一次，读取侧不再依赖时区与格式器）。
    let timeText: String

    /// - Parameters:
    ///   - source: 来源。
    ///   - succeeded: 是否成功。
    ///   - target: 操作对象（见同名属性的语义）。
    ///   - message: 完整描述（失败句由各调用方的文案单一真源给出）。
    ///   - error: 失败时的错误（桥接为 NSError 取 domain / code）；成功传 nil。
    ///   - occurredAt: 发生时刻（默认当前时刻）。
    init(source: AppDiagnosticSource,
         succeeded: Bool,
         target: String,
         message: String,
         error: Error? = nil,
         occurredAt: Date = Date()) {
        let nsError: NSError? = error.map { $0 as NSError }
        self.source = source
        self.succeeded = succeeded
        self.target = target
        self.message = message
        self.errorDomain = nsError?.domain
        self.errorCode = nsError?.code
        self.occurredAt = occurredAt
        self.timeText = Self.timeString(from: occurredAt)
    }

    /// 结果词（「成功」/「失败」）。
    var outcomeText: String {
        succeeded ? "成功" : "失败"
    }

    /// HH:mm:ss 文本（落盘前与「已请求重载」文案共用的同一个格式化入口）。
    ///
    /// 固定 POSIX 地区 + 24 小时制：诊断文本要能跨设备比对，不该随系统的
    /// 12/24 小时设置变形。
    ///
    /// - Parameter date: 目标时刻。
    /// - Returns: 形如「23:21:44」。
    static func timeString(from date: Date) -> String {
        let formatter: DateFormatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// 落盘形状：**单 key、单值** —— 按来源各保留最近一条，来源之间互不覆盖。
private struct AppDiagnosticLog: Codable {

    /// 来源 `rawValue` → 该来源最近一次结果。
    var latestBySource: [String: AppDiagnosticEntry] = [:]
}

/// App 侧诊断记录读写层（App 本地 `UserDefaults.standard`，绝不经 App Group）。
///
/// 全部调用点都在 @MainActor（设置页 / 换图标器 / 实时活动管理器），故本类型
/// **不**做跨线程共享设计；`UserDefaults` 自身的读写即线程安全。
final class AppDiagnosticsStore {

    // MARK: - 常量

    /// 持久化键（**全仓唯一一个**诊断键；整份日志是单值 Codable）。
    static let key: String = "zs.weather.appDiagnostics.log"

    /// 生产共享实例（App 本地 `.standard`；与默认构造出的实例读到同一份数据）。
    static let shared: AppDiagnosticsStore = AppDiagnosticsStore()

    // MARK: - 依赖

    private let defaults: UserDefaults
    private let encoder: JSONEncoder = JSONEncoder()
    private let decoder: JSONDecoder = JSONDecoder()

    /// - Parameter defaults: 存储（App 用 `.standard`；
    ///   单测注入 `UserDefaults(suiteName:)` 以隔离）。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 写（记录一次结果）

    /// 记录一次结果（**永不抛出**：写失败只打印，绝不让诊断拖累主流程）。
    ///
    /// - Parameter entry: 待记录的结果（覆盖同来源的旧记录）。
    func record(_ entry: AppDiagnosticEntry) {
        var log: AppDiagnosticLog = loadLog()
        log.latestBySource[entry.source.rawValue] = entry
        do {
            let data: Data = try encoder.encode(log)
            defaults.set(data, forKey: Self.key)
        } catch {
            // 诊断写失败**绝不上抛**：换图标 / 实时活动的返回值只由系统结果决定。
            print("[AppDiagnosticsStore] 写入诊断记录失败（已忽略，不影响主流程）：\(error)")
        }
    }

    /// 记录一次结果（便捷入口：现场组装 `AppDiagnosticEntry`）。
    ///
    /// - Parameters:
    ///   - source: 来源。
    ///   - succeeded: 是否成功。
    ///   - target: 操作对象。
    ///   - message: 完整描述（失败句请传各调用方文案单一真源产出的短句）。
    ///   - error: 失败时的错误（成功传 nil）。
    func record(source: AppDiagnosticSource,
                succeeded: Bool,
                target: String,
                message: String,
                error: Error? = nil) {
        let entry = AppDiagnosticEntry(source: source,
                                       succeeded: succeeded,
                                       target: target,
                                       message: message,
                                       error: error)
        record(entry)
    }

    // MARK: - 读（读取最近一次结果）

    /// 读取某来源的最近一次结果（该来源从无记录 → nil）。
    ///
    /// - Parameter source: 来源。
    /// - Returns: 最近一条记录；解码失败或无记录为 nil。
    func latest(for source: AppDiagnosticSource) -> AppDiagnosticEntry? {
        loadLog().latestBySource[source.rawValue]
    }

    /// 读取**全部来源**中最近的一次结果（按 `occurredAt` 比较）。
    ///
    /// - Returns: 最近一条记录；无记录为 nil。
    func latest() -> AppDiagnosticEntry? {
        loadLog().latestBySource.values.max { $0.occurredAt < $1.occurredAt }
    }

    // MARK: - 内部

    /// 读取整份日志（缺失 / 解码失败 → 空日志）。
    ///
    /// 解码失败时**只打印、不删除既有字节**（与 `AppGroupStore.loadCities()`
    /// 同款纪律：坏数据留给下一次成功写入自然修正，绝不因读失败清数据）。
    ///
    /// - Returns: 日志；任何失败路径都返回**空日志**，绝不抛出。
    private func loadLog() -> AppDiagnosticLog {
        guard let data: Data = defaults.data(forKey: Self.key) else {
            return AppDiagnosticLog()
        }
        do {
            return try decoder.decode(AppDiagnosticLog.self, from: data)
        } catch {
            print("[AppDiagnosticsStore] 读取诊断记录失败（返回空日志，保留原字节）：\(error)")
            return AppDiagnosticLog()
        }
    }
}

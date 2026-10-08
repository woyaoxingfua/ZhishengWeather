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
//  ⚠️ **本轮新增 `import WidgetKit`（唯一一处对上面那条纪律的例外）**：
//  「小组件系统探针」（`probeWidgetSystemRegistration`）要向系统问
//  「当前登记了几个小组件实例」，那是 `WidgetCenter` 的 API，而
//  `WidgetFamily` 这个枚举类型也出自WidgetKit。不引它就写不出这段。
//  为什么可接受：① `WidgetKit` 是**系统框架**，不是第三方依赖，
//  且本类型**零网络、零 UI**（只用 `WidgetCenter` 的查询 API，
//  不用任何 view / provider）；② 本文件仍**不引 UIKit**。
//  故把它记在这里而不是默默破例—— 纪律的价值在于「例外必须可见」。
//

import Foundation
import WidgetKit

/// 诊断记录的来源（落盘用 `rawValue` 作字典键，新增来源只改这一处）。
enum AppDiagnosticSource: String, Codable, Sendable, CaseIterable {

    /// 换图标（`UIApplication.setAlternateIconName`）。
    case appIcon
    /// 实时活动（ActivityKit 的 request / update / end）。
    case liveActivity
    /// 小组件时间线重载（`WidgetCenter.reloadAllTimelines()`）。
    case widgetTimeline
    /// 雷达纠偏探针（R1：`CoordinateTransform` 的偏移量实测落盘）。
    case radarOffsetProbe
    /// 小组件系统登记探针（`WidgetCenter.getCurrentConfigurations` 的实测结果）。
    ///
    /// ⚠️ 为什么**只能**在主 App 侧采集：`WidgetCenter` 是**主 App 进程**的 API，
    /// 小组件扩展进程调它拿不到主 App 的视角；而小组件进程自己的执行轨迹
    /// （`timeline` 有没有被调）**写不进本存储**（`UserDefaults.standard` 在扩展
    /// 沙盒里，主 App 读不到—— 与 App Group 是否可用无关，是沙盒边界本身）。
    /// 故本 case 记的是**系统认为存在几个小组件实例、各自什么尺寸**，
    /// 它与Console 里的 timeline 日志互补，合起来才能定位问题层级。
    case widgetSystemProbe

    /// 导航栈落盘 / 恢复（`NavigationPathStore` 的存盘与恢复结果）。
    ///
    /// ⚠️ **为什么值得单独记一条**：导航栈恢复失败**在屏幕上完全看不出来**
    /// —— 它降级成空路径后，用户看到的就是一个「普普通通的首页」，与
    /// 「本来就该在首页」在视觉上**没有任何区别**。若只打印日志，这个故障
    /// 在用户侧就彻底消失了。故必须落盘，让设置页可读。
    ///
    /// ⚠️ 只记**失败**（`succeeded: false`）：恢复成功 / 本来就没有记录都是
    /// 正常态，不需要占用「最近一次失败」的位置。
    case navigationPathRestore

    /// 面向用户的来源名（设置页展示用）。
    var displayName: String {
        switch self {
        case .appIcon:
            return "换图标"
        case .liveActivity:
            return "实时活动"
        case .widgetTimeline:
            return "小组件时间线"
        case .radarOffsetProbe:
            return "雷达纠偏探针"
        case .widgetSystemProbe:
            return "小组件系统探针"
        case .navigationPathRestore:
            return "导航栈恢复"
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
    /// 记录产生时的安装身份（`Bundle.main.bundleIdentifier`）。
    ///
    /// 用于「本安装不可用」判据：换 Bundle Identifier 后重签是 -54 的一种社区验证
    /// 解法（SO 75370140），读到记录时比对身份，不一致即视为「无记录」→ 自动恢复
    /// 可用——否则一条陈旧的 -54 会永久锁死功能。成功记录也带身份（无害）。
    /// 可选：旧版日志无此字段，解码缺失即 nil（视为无身份、不比对、不锁死）。
    let bundleIdentifier: String?
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
    ///   - bundleIdentifier: 记录产生时的安装身份（`Bundle.main.bundleIdentifier`）；
    ///     用于「本安装不可用」判据，默认 nil（旧调用方不传）。
    ///   - occurredAt: 发生时刻（默认当前时刻）。
    init(source: AppDiagnosticSource,
         succeeded: Bool,
         target: String,
         message: String,
         error: Error? = nil,
         bundleIdentifier: String? = nil,
         occurredAt: Date = Date()) {
        let nsError: NSError? = error.map { $0 as NSError }
        self.source = source
        self.succeeded = succeeded
        self.target = target
        self.message = message
        self.errorDomain = nsError?.domain
        self.errorCode = nsError?.code
        self.bundleIdentifier = bundleIdentifier
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
    ///   - bundleIdentifier: 记录产生时的安装身份（默认 nil；换图标失败调用方传入
    ///     当前 `Bundle.main.bundleIdentifier` 以支撑「本安装不可用」判据）。
    func record(source: AppDiagnosticSource,
                succeeded: Bool,
                target: String,
                message: String,
                error: Error? = nil,
                bundleIdentifier: String? = nil) {
        let entry = AppDiagnosticEntry(source: source,
                                       succeeded: succeeded,
                                       target: target,
                                       message: message,
                                       error: error,
                                       bundleIdentifier: bundleIdentifier)
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

    // MARK: - R1：雷达纠偏探针落盘

    /// 把「当前偏移量到底是多少米 / 多少像素」写进诊断记录。
    ///
    /// ── 为什么需要它（R1 的核心痛点）────────────────────────────────────
    /// 纠偏方向此前只能靠「用户手动切档 + 人眼比对两个地物」判断，太弱：
    /// ① 人眼判不出 50 m 量级；② 无法留痕、无法复查；③ 无法把结论带回来讨论。
    /// 本方法把**偏移量本身**（各参考点的米数 + 像素当量）落盘，
    /// 真机验收时用户只需要**读一个数字**，而不是在屏幕上找两处地物。
    ///
    /// ⚠️ **它不判断方向对错** —— 偏移量是纯几何事实，与 MapKit 的行为无关。
    /// 方向仍须真机看回波与底图是否对齐（但注意：见
    /// `CoordinateTransform.correctionIsInertAcrossRadarZooms`，
    /// 切档在 z4–z7 上**不改变瓦片请求**，故切档无法用于判方向）。
    ///
    /// - Parameters:
    ///   - mode: 当前纠偏档位（仅作为记录上下文，不影响计算）。
    ///   - tileEdge: 瓦片边长（像素）。
    ///   - store: 诊断层（默认 `.shared`，单测可注入独立 suite）。
    static func recordRadarOffsetProbe(mode: CoordinateTransformMode,
                                       tileEdge: Int = RadarTileURLBuilder.tileEdge,
                                       store: AppDiagnosticsStore = .shared) {
        let summaries = CoordinateTransform.probeSummaries(tileEdge: tileEdge)
        let message = ("当前档位：" + mode.displayName + "\n"
            + summaries.joined(separator: "\n")
            + "\n官方文档未定义 tile overlay 是否被纠偏（见 CoordinateTransform.Evidence）")
        store.record(source: .radarOffsetProbe,
                     succeeded: true,
                     target: "offsetProbe",
                     message: message)
    }

    /// 🆕 把「像素级平移量」写进诊断记录（R2）。
    ///
    /// ── 为什么必须单独落盘（不能塞进 `recordRadarOffsetProbe`）────────────
    /// 两者回答的是**不同问题**：
    ///  · `offsetProbe` = 「偏移有多远」（米 / 瓦片像素当量）；
    ///  · 本方法= 「绘制期平移会挪多少」（**屏幕点/ 设备像素**）。
    /// 而R1 真机验收要看的是**后者** —— 用户看到的是屏幕，
    /// 不是瓦片像素。实测后者在 z4–z7 都 < 1 设备像素，
    /// 这正是"切档看不出差别"的**根因**，必须单独可查。
    ///
    /// ⚠️ **它同样不下方向结论**（R1 未定案），故文案里显式带
    /// 「纠偏方向未验证」，防止读日志的人把某个数字当成"已对齐"。
    ///
    /// - Parameters:
    ///   - mode: 当前平移档位。
    ///   - longitude: 参考点经度（WGS84）。
    ///   - latitude: 参考点纬度（WGS84）。
    ///   - tileEdge: 瓦片边长（点）。
    ///   - contentScaleFactor: 内容缩放因子。
    ///   - store: 诊断层（默认 `.shared`）。
    ///
    /// ⚠️ `contentScaleFactor` **由调用方传入**而非在此读 `UIScreen`：
    /// 本文件纪律是「仅 import Foundation（不引 UIKit）」（见文件头），
    /// 且单测必须能固定该值 —— 故绝不在这里取设备相关量。
    static func recordRadarPixelShift(mode: RadarPixelShiftMode,
                                      longitude: Double,
                                      latitude: Double,
                                      tileEdge: Int = RadarTileURLBuilder.tileEdge,
                                      contentScaleFactor: Double,
                                      store: AppDiagnosticsStore = .shared) {
        let summaries = CoordinateTransform.pixelShiftSummaries(
            tileEdge: Double(tileEdge),
            zoom: RadarTileZoomRange.maximum,
            contentScaleFactor: contentScaleFactor)
        let probe = CoordinateTransform.pixelShiftProbe(
            longitude: longitude, latitude: latitude,
            zoom: RadarTileZoomRange.maximum,
            tileEdge: Double(tileEdge),
            contentScaleFactor: contentScaleFactor)
        let message = ("平移档位：" + mode.displayName + "\n"
            + "当前城市平移量 " + CoordinateTransform.decimal2(probe.magnitudeDevicePixels)
            + " 设备像素（" + CoordinateTransform.decimal1(contentScaleFactor) + "x）\n"
            + summaries.joined(separator: "\n")
            + "\n纠偏方向未验证（R1），平移量不足 1 像素时肉眼不可辨")
        store.record(source: .radarOffsetProbe,
                     succeeded: true,
                     target: "pixelShift",
                     message: message)
    }

    // MARK: - 小组件系统登记探针（真机「小组件没数据」的第一手设备事实）

    /// 向系统查询「当前登记了几个小组件实例」，并把结果**如实**落进诊断记录。
    ///
    /// ── 它能回答什么（这是它存在的唯一理由）────────────────────────────
    /// 用户在真机上的核心症状是「小组件能加到桌面、但一直空数据」。
    /// 排查第一刀该切在哪一层，取决于两个**互相独立**的事实：
    ///   1. **系统认不认这个实例？** —— 本探针回答（`WidgetCenter` 是设备事实，
    ///      不是我们对代码的假设）。
    ///   2. **系统到底调不调 `timeline`？** —— 由 Console 里的
    ///      `WidgetTrace` ENTER/EXIT 行回答（小组件进程内的事，主 App 读不到）。
    /// 两者合起来才能把「系统侧问题」与「我们的代码问题」分开。
    ///
    /// ⚠️ **诚实边界**：本探针**看不到**小组件进程的执行轨迹，也**看不到**
    /// AppIntents 配置有没有送达（`configuration` 字段对本项目这种
    /// 自定义 AppIntent 不保证可读，故此处**只取 kind / family 两个字段**，
    /// 不去解读配置内容—— 解读不了就不解读，绝不编造）。
    ///
    /// - Parameter store: 诊断层（默认 `.shared`）。
    static func probeWidgetSystemRegistration(store: AppDiagnosticsStore = .shared) async {
        let message: String
        let succeeded: Bool
        do {
            let configurations = try await Self.loadCurrentWidgetConfigurations()
            succeeded = true
            if configurations.isEmpty {
                // 空数组 ≠ 失败：它意味着「系统当前没有登记任何本App 的小组件实例」，
                // 这与「实例在但空数据」是完全不同的两件事，必须分开说。
                message = """
                系统登记的小组件实例数：0
                ⇒ 系统当前**没有**任何本 App 的小组件实例。
                若你确实在桌面上看到小组件卡片，说明系统侧登记与桌面显示不一致。
                """
            } else {
                // ⚠️ 元素类型名在此处**不出现**：靠类型推断（`configurations`）。
                // 【更正 2026-10-08】此前的注释说「Apple 文档把这个元素类型分别写成
                // `WidgetInfo` / `WidgetConfiguration`」—— 逐页核对官方文档后更正：
                // `WidgetCenter` 页明确写的是 `struct WidgetInfo`（含 `configuration`
                // / `family` / `kind` 三个字段），文档没有第二种写法。
                // 保留不写死类型名只是**减少编译面**的工程选择，不是因为文档有歧义。
                let lines = configurations
                    .map { conf in
                        "kind=\(conf.kind) family=\(Self.familyName(conf.family))"
                    }
                    .joined(separator: "\n")
                message = """
                系统登记的小组件实例数：\(configurations.count)
                \(lines)
                ⇒ 实例已被系统登记。若桌面仍空数据，请看Console 里 category=widget 的 \
                ENTER/EXIT 日志，判断 timeline 是否被调用、请求是否发出。
                """
            }
        } catch {
            succeeded = false
            // 带domain + code：侧载场景下 localizedDescription 常是泛化的一句。
            message = "查询系统小组件登记失败：\(error.localizedDescription)"
        }
        store.record(source: .widgetSystemProbe,
                     succeeded: succeeded,
                     target: "WidgetCenter.getCurrentConfigurations",
                     message: message,
                     error: succeeded ? nil : WidgetProbeError.queryFailed)
    }

    /// 桥接 `WidgetCenter.getCurrentConfigurations(_:)`（**iOS 14+** 的完成回调版）到 async。
    ///
    /// ── 为什么必须绕这一层（这是本方法存在的唯一理由）─────────────────────
    /// 直觉上该写 `WidgetCenter.shared.currentConfigurations()` —— Apple 文档里
    /// 确实有这个 async 方法，但它的可用性是 **iOS 18.0+**（同页标注
    /// iOS 18.0+ / iPadOS 18.0+ / macOS 15.0+ / watchOS 11.0+）。
    /// 而本工程 `IPHONEOS_DEPLOYMENT_TARGET = 17.0`（`project.yml`）→
    /// 直接调用它会在 CI 编译期失败：
    /// `value of type 'WidgetCenter' has no member 'currentConfigurations'`。
    ///
    /// **可用性门槛不够时编译器报的是「无此成员」，不是「版本太新」**，
    /// 很容易被误判成「名字写错了」而去改名字 —— 改名字只会更错。
    ///
    /// 结论（本项目第三次同类事故，前两次是 `MKTileOverlay.loadingPolicy`
    /// 与 `UnkeyedDecodingContainer.decode(_:at:)`）：
    /// **API 的存在性与归属版本只能查官方文档，不能靠推理。**
    ///
    /// - Returns: 系统当前登记的本 App 小组件实例；失败时抛出底层错误。
    private static func loadCurrentWidgetConfigurations() async throws -> [WidgetInfo] {
        try await withCheckedThrowingContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                continuation.resume(with: result)
            }
        }
    }

    /// 探针失败时的占位错误。
    ///
    /// ⚠️ 为什么要造一个 error 而不是直接传 nil：`record` 的 error 参数只为把
    /// domain + code 带进落盘记录，而「查询失败」这个事实必须有 domain/code
    /// 才判得出来（`AppDiagnosticEntry` 的既有纪律，见文件头）。
    /// 它**不对外抛出**，也**不代表**底层真实错误（真实错误在 message 里）。
    private enum WidgetProbeError: Error {
        case queryFailed
    }

    /// `WidgetFamily` → 稳定短串（穷尽 switch，不留 `default`）。
    private static func familyName(_ family: WidgetFamily) -> String {
        switch family {
        case .systemSmall: return "small"
        case .systemMedium: return "medium"
        case .systemLarge: return "large"
        case .systemExtraLarge: return "xl"
        case .accessoryCircular: return "accCircular"
        case .accessoryRectangular: return "accRect"
        case .accessoryInline: return "accInline"
        @unknown default: return "unknown"
        }
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

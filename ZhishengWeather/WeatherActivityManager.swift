//
//  WeatherActivityManager.swift
//  ZhishengWeather（主 App target）
//
//  实时活动的**副作用出口**：把「用户开了开关」落为 ActivityKit 的
//  `request / update / end` 系统调用。
//
//  第一原则：**按能力探测诚实降级**。
//  ActivityKit 本身不需要 entitlement，但本 App 是侧载自用（未签名 IPA 经
//  第三方工具重签），重签会不会影响实时活动**没有实证**。故绝不假设可用：
//  每次启动前先查 `ActivityAuthorizationInfo().areActivitiesEnabled`，
//  为 false 时不发起任何系统调用、直接把「本安装/系统未开启实时活动」
//  交给 UI —— 让用户**点了没反应**是最糟的结果。
//
//  纪律（对齐 AppIconSwitcher / UmbrellaReminderScheduler）：
//  - **错误不静默**：失败必须 `print` + 收敛为一句中文短句返回给 UI；
//    绝不弹系统弹窗、绝不重试（失败重试会在侧载渠道上变成重试风暴，
//    而失败原因几乎必是「本安装不支持」，重试多少次都不会变）。
//  - **偏好在成功之后才落**：与换图标同款 —— 系统调用失败而偏好已写，
//    重启后「UI 显示已开启」与「设备上其实没有活动」就不一致了。
//  - **幂等**：同一城市重复启动 = 更新，不叠新活动；`end()` 后清空内部引用。
//  - **字段可空**：拿不到的数据一律 nil，绝不填伪数据。
//  - 仅 import ActivityKit + Foundation（不引 UIKit）。
//  - **诊断留痕（本轮增量）**：启动 / 更新 / 结束都写一份诊断记录
//    （`AppDiagnosticsStore`，App 本地 UserDefaults），设置页「实时活动」
//    区随时可读最近一次结果。诊断是**旁路**：写失败只打印，绝不改变返回值。
//  - ⚠️ **不伪造失败分支**：iOS 17 SDK 上 `Activity.end` / `Activity.update`
//    是**非抛出**的 async 方法，没有 error 出口；故这两处**只记成功**，
//    绝不为了「有失败留痕」编一个 catch 出来。
//
//  ⚠️ 已知的**本轮未完成接线**：实时活动的 UI（`ActivityConfiguration`）属于
//  Widget 扩展，本轮未加。缺少它时 `Activity.request` 大概率会直接失败，
//  失败短句会如实显示在设置页 —— 这是**预期的诚实结果**，不是 bug。
//

import ActivityKit
import Foundation

/// 实时活动管理器（@MainActor：与设置页同一隔离域，读写活动引用无竞态）。
@MainActor
final class WeatherActivityManager {

    // MARK: - 文案单一真源（纯静态，UI 与日志共用，不散落在视图里）

    /// 能力不可用时的说明文案（设置页 12 号红色文案的唯一来源）。
    ///
    /// 成因有两种，文案一并覆盖：① 用户在系统设置里关掉了本 App 的实时活动；
    /// ② 本安装/系统层面不允许（侧载重签的未知影响也落在这里）。
    static let unavailableHint: String = "本安装/系统未开启实时活动，开关暂不可用"

    /// 能力可用时的说明文案（12 号次级文字）。
    ///
    /// 为什么必须写「自动更新尚未接线」：本轮只做手动启动/更新/结束，
    /// 取数成功后自动刷新由后续接线完成。不写明，用户会以为开了就该自己变。
    static let availableHint: String = "开启后在灵动岛/锁屏显示当前城市天气；取数后自动更新尚未接线，当前为手动启动"

    /// 尚未启动活动却收到更新请求时的短句（UI 12 号红色展示）。
    static let notRunningMessage: String = "实时活动尚未启动，请先开启开关"

    /// 启动成功的记录文案（**只**进诊断记录；UI 上开关已变开，不再另给提示）。
    static let startSucceededMessage: String = "实时活动已启动"

    /// 更新成功的记录文案（**只**进诊断记录）。
    static let updateSucceededMessage: String = "实时活动已更新"

    /// 结束成功的记录文案（**只**进诊断记录）。
    static let endSucceededMessage: String = "实时活动已结束"

    /// 开关已开、但管理器尚未缓存到任何取数结果时，主动补推的提示文案。
    ///
    /// 成因：用户开了开关、App 却还没成功取过数（无网冷启动等）——此时活动
    /// 已启动但没有任何真实数据可推，必须如实告知，而不是假装「已更新」。
    static let noDataToPushMessage: String = "尚无天气数据，无法推送"

    /// 启动/更新失败的面向用户短句：**带上 NSError 的 domain + code**。
    ///
    /// 为什么必须带 domain/code（与 `AppIconSwitcher.failureMessage(for:)`
    /// 同款理由）：侧载场景里 `localizedDescription` 往往只是一句泛化的
    /// 「操作无法完成」，看不出是「本安装不支持」还是「缺少活动 UI 配置」；
    /// domain + code 是用户在截图里能直接提供给我们的唯一可判定信息。
    ///
    /// - Parameter error: 系统回传的错误（可为任意 Error，桥接为 NSError 取值）。
    /// - Returns: 中文短句，形如「启动实时活动失败（xxx 4：xxx）」。
    static func failureMessage(for error: Error) -> String {
        let nsError = error as NSError
        let detail = "\(nsError.domain) \(nsError.code)：\(nsError.localizedDescription)"
        return "启动实时活动失败（\(detail)）"
    }

    // MARK: - 依赖与状态

    /// 开关持久化（App 本地 UserDefaults；注入即读写同一 store）。
    private let settings: LiveActivitySettings

    /// 诊断记录层（启动 / 更新 / 结束都留痕；**旁路**，绝不改变返回值）。
    private let diagnostics: AppDiagnosticsStore

    /// 当前活动引用（进程内；`end()` 后清空）。
    ///
    /// ⚠️ 生命周期限制：App 被杀后本引用丢失。冷启动后若用户直接关开关，
    /// `end()` 会走「向系统查询本类型的在跑活动」的兜底路径补结束。
    private var currentActivity: Activity<WeatherActivityAttributes>?

    /// 最近一次取数结果（快照 + 城市），由 `update(from:city:)` 每次成功取数时缓存。
    ///
    /// 用途：开关打开 / 切单位 / 回到前台等时机，若已有在跑活动但还没有被
    /// `update` 喂过数据，就用这份缓存把当前天气**主动补推**一次，避免活动长期空态
    /// （灵动岛一直显示「— / 暂无数据」）。仅缓存、**绝不**在此处编造数据。
    /// 与 `currentActivity` 同为进程内引用：App 被杀后清空，下次取数再填。
    private var latestSnapshot: (snapshot: WeatherSnapshot, city: City)?

    /// - Parameters:
    ///   - settings: 开关持久化（默认 App 本地 standard）。
    ///   - diagnostics: 诊断记录层（nil = `AppDiagnosticsStore.shared`，
    ///     同样是 App 本地 standard —— 与 `settings` 的默认 store 同源）。
    init(settings: LiveActivitySettings = LiveActivitySettings(),
         diagnostics: AppDiagnosticsStore? = nil) {
        self.settings = settings
        self.diagnostics = diagnostics ?? AppDiagnosticsStore.shared
    }

    // MARK: - 能力探测（诚实，不假装可用）

    /// 系统/本安装是否允许实时活动（ActivityKit 的能力开关，iOS 16.1+）。
    ///
    /// 本工程部署目标为 iOS 17.0，故无需 `if #available` 保护；
    /// 但**运行期**是否允许与本安装有关，必须在每次启动前实测。
    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// 用户的开关状态（读**注入的** store）。
    var isEnabled: Bool {
        settings.isEnabled
    }

    // MARK: - 启动（幂等）

    /// 启动实时活动。
    ///
    /// 流程：能力探测 → 同城市幂等（已有活动则转更新）→ 异城市先结束后新建 →
    /// `Activity.request` → **成功后**写偏好 → 失败上抛短句（不写偏好）。
    ///
    /// - Parameters:
    ///   - cityName: 城市名（nil = 调用方没有真实城市数据）。
    ///   - conditionText: 天气描述文案（nil = 无数据）。
    ///   - temperatureText: 温度文案（nil = 无数据）。
    ///   - updatedAtText: 更新时间文案（由调用方按城市时区格式化；nil = 无数据）。
    /// - Returns: 成功为 nil；失败为面向用户的中文短句。
    @discardableResult
    func start(cityName: String?,
               conditionText: String?,
               temperatureText: String? = nil,
               updatedAtText: String? = nil) async -> String? {
        let cityID = cityName ?? WeatherActivityAttributes.unknownCityID
        guard areActivitiesEnabled else {
            // 能力不可用：一个系统调用都不发，如实告诉 UI。
            print("[LiveActivity] 启动被拒：\(Self.unavailableHint)")
            // 留痕（旁路）：「能力未开」是最需要在设置页长期可见的一条 ——
            // 用户这次关掉设置页、下次再来看，仍然读得到为什么起不来。
            diagnostics.record(source: .liveActivity,
                               succeeded: false,
                               target: cityID,
                               message: Self.unavailableHint)
            return Self.unavailableHint
        }
        if let existing = currentActivity {
            if existing.attributes.cityID == cityID {
                // 幂等：同一城市重复启动 → 退化为更新，绝不叠新活动。
                let message = await update(cityName: cityName,
                                           conditionText: conditionText,
                                           temperatureText: temperatureText,
                                           updatedAtText: updatedAtText)
                if message == nil {
                    // 更新成功即视为已开启：保证「偏好」与「设备上真有活动」一致，
                    // 否则开关回滚逻辑会把一个正在跑的活动判成「没开」。
                    settings.setEnabled(true)
                }
                return message
            }
            // 换城市：先结束旧的再建新的（同一时刻只保留一个活动）。
            await endCurrentActivity()
        }
        let attributes = WeatherActivityAttributes(cityID: cityID)
        let state = Self.contentState(cityName: cityName,
                                      temperatureText: temperatureText,
                                      conditionText: conditionText,
                                      updatedAtText: updatedAtText)
        do {
            // pushType = nil：本特性不用推送驱动更新（无推送 entitlement，
            // 侧载渠道上更是死路），全部由 App 侧主动 update。
            let activity = try Activity<WeatherActivityAttributes>.request(attributes: attributes,
                                                                          contentState: state,
                                                                          pushType: nil)
            currentActivity = activity
            // 系统接受后才落偏好，保证「开关显示已开」==「设备上真有活动」。
            settings.setEnabled(true)
            // 成功同样留痕：与失败成对出现，才能判定「这次行 / 从来没行过」。
            // 附「字段非空 X/4」：开关刚开时通常只带 updatedAtText，能一眼看出
            // 「活动已起、但内容几乎为空」，定位「灵动岛一直空」的成因。
            let startCount = Self.fieldCount(cityName: cityName,
                                             conditionText: conditionText,
                                             temperatureText: temperatureText,
                                             updatedAtText: updatedAtText)
            diagnostics.record(source: .liveActivity,
                               succeeded: true,
                               target: cityID,
                               message: Self.startSucceededMessage + Self.fieldSummary(startCount))
            return nil
        } catch {
            // 错误绝不静默：打印 + 收敛短句给设置页展示。绝不重试。
            let message = Self.failureMessage(for: error)
            print("[LiveActivity] \(message)")
            // 留痕（旁路）：domain + code 是侧载场景下唯一可判定的信息。
            diagnostics.record(source: .liveActivity,
                               succeeded: false,
                               target: cityID,
                               message: message,
                               error: error)
            return message
        }
    }

    // MARK: - 更新

    /// 取数成功后推送实时活动（**仅更新，不启动**）。
    ///
    /// 主 App 每取到一次天气，把最新真实数据推进正在进行的活动；
    /// **没有在跑的活动就直接返回 `notRunningMessage`，绝不凭空 `start`**
    /// —— 启动仍是用户手动/设置开关的语义，本轮不改（否则用户没开开关、
    /// 取数成功却突然冒出一个活动，是越权副作用）。
    /// 无数据字段即 nil，保持诚实空态，绝不造假。
    ///
    /// - Parameters:
    ///   - snapshot: 取数成功的天气快照（温度/天气码/更新时刻来源）。
    ///   - city: 本次取数目标城市（城市名 + 时区来源）。
    ///   - unit: 单位偏好（默认 App Group 共享容器的生产实例，与主 App 展示一致）。
    /// - Returns: 成功为 nil；未启动/失败为面向用户的中文短句。
    @discardableResult
    func update(from snapshot: WeatherSnapshot,
                city: City,
                unit: UnitPreference = UnitPreference()) async -> String? {
        // 缓存最近一次取数结果：开关打开 / 切单位 / 回到前台时靠它主动补推，
        // 避免活动长期空态（见 `pushLatestIfRunning`）。仅缓存真实数据。
        latestSnapshot = (snapshot, city)
        let timeZone = WeatherTimeFormatter.timeZone(for: city)
        let content = WeatherActivityContentBuilder.buildContentState(
            cityName: snapshot.location.name,
            temperatureCelsius: snapshot.temperature,
            weatherCode: snapshot.weatherCode,
            isDay: snapshot.isDay,
            updatedAt: snapshot.fetchedAt,
            timeZone: timeZone,
            unit: unit)
        return await update(cityName: content.cityName,
                           conditionText: content.conditionText,
                           temperatureText: content.temperatureText,
                           updatedAtText: content.updatedAtText)
    }

    /// 更新当前实时活动的内容。
    ///
    /// 尚未启动时**不偷偷启动** —— 返回 `notRunningMessage` 让 UI 如实告知，
    /// 「用户只点了更新、系统却冒出一个新活动」属越权副作用。
    /// 但「在跑的活动」来源做宽：优先用本实例的内存引用；若实例引用已丢失
    /// （App 被杀冷启、或开关由另一处同类型管理器发起），向系统查询本类型的
    /// 在跑活动兜底补上 —— 与 `end()` 的兜底同款，确保「取数成功 → 能推进
    /// 已在跑的活动」不依赖「恰好是同一实例拿着引用」。
    ///
    /// - Parameters: 同 `start(cityName:conditionText:temperatureText:updatedAtText:)`。
    /// - Returns: 成功为 nil；失败/未启动为面向用户的中文短句。
    @discardableResult
    func update(cityName: String?,
                conditionText: String?,
                temperatureText: String? = nil,
                updatedAtText: String? = nil) async -> String? {
        let count = Self.fieldCount(cityName: cityName,
                                   conditionText: conditionText,
                                   temperatureText: temperatureText,
                                   updatedAtText: updatedAtText)
        // 解析在跑活动：内存引用优先，否则查系统兜底。
        var activity: Activity<WeatherActivityAttributes>? = currentActivity
        if activity == nil, settings.isEnabled {
            activity = await Activity<WeatherActivityAttributes>.activities.first
        }
        guard let activity else {
            let message = Self.notRunningMessage + Self.fieldSummary(count)
            print("[LiveActivity] 更新跳过：\(message)")
            // 留痕（旁路）：「还没启动就点更新」是一次真实的失败尝试，
            // 记下来才能解释设置页为什么曾出现过这条红字。附字段非空数，
            // 一眼看出「到底是没启动，还是启动了但没内容」。
            diagnostics.record(source: .liveActivity,
                               succeeded: false,
                               target: cityName ?? WeatherActivityAttributes.unknownCityID,
                               message: message)
            return Self.notRunningMessage
        }
        // 兜底查到的活动回填内存引用：后续更新不必每次都查系统。
        currentActivity = activity
        let state = Self.contentState(cityName: cityName,
                                      temperatureText: temperatureText,
                                      conditionText: conditionText,
                                      updatedAtText: updatedAtText)
        await activity.update(using: state)
        // `Activity.update` 在 iOS 17 SDK 上是**非抛出**的 async，没有 error
        // 出口 —— 故这里只记成功，绝不伪造失败分支。附字段非空数。
        diagnostics.record(source: .liveActivity,
                           succeeded: true,
                           target: activity.attributes.cityID,
                           message: Self.updateSucceededMessage + Self.fieldSummary(count))
        return nil
    }

    /// 开关已开、已有缓存取数结果时，**主动补推**一次当前天气到在跑活动。
    ///
    /// 触发时机（解决「开了开关却一直空」）：① 用户在设置页打开开关（见
    /// `SettingsView.toggleLiveActivity`）；② 切温度/风速/气压单位（同一次
    /// 取数、不同单位展示，需重推）；③ App 回到前台（若活动在跑、有缓存则补推）。
    /// 仅「开关开着且有缓存」才推；没开（无活动）或没缓存（从未取数）都
    /// 如实留痕，绝不凭空 start、绝不造假数据。
    ///
    /// - Parameter unit: 单位偏好（切单位时传最新偏好；默认生产实例）。
    /// - Returns: 成功为 nil；无活动/无缓存为面向用户的中文短句。
    @discardableResult
    func pushLatestIfRunning(unit: UnitPreference = UnitPreference()) async -> String? {
        // 开关没开 = 没有活动，无需尝试也不留痕（不是一次有意义的推送尝试）。
        guard settings.isEnabled else { return nil }
        guard let (snapshot, city) = latestSnapshot else {
            // 开关开着但还没取到过数：如实告知，并在诊断里标「字段非空 0/4」。
            let message = Self.noDataToPushMessage + Self.fieldSummary(0)
            diagnostics.record(source: .liveActivity,
                               succeeded: false,
                               target: WeatherActivityAttributes.unknownCityID,
                               message: message)
            return Self.noDataToPushMessage
        }
        return await update(from: snapshot, city: city, unit: unit)
    }

    // MARK: - 结束

    /// 结束实时活动（关闭开关时调用）：结束后清空内部引用并落偏好为关。
    ///
    /// 内存引用丢失时（App 被杀后冷启动）向系统查询本类型仍在跑的活动逐个结束，
    /// 保证「开关关闭」与「设备上真的没有活动」一致 —— 否则用户关了开关，
    /// 锁屏上的活动还挂着，是最典型的「UI 与设备事实不一致」。
    func end() async {
        // 先取城市标识：`endCurrentActivity()` 会清空 `currentActivity`，
        // 之后就取不到了（诊断记录要写清「结束的是哪个城市」）。
        let cityID = currentActivity?.attributes.cityID ?? WeatherActivityAttributes.unknownCityID
        // 只有「没有内存引用**且**偏好说开过」才查系统：从没开过就没有活动可结束，
        // 白查一次系统徒增不确定性（开关回滚时会走到这里）。
        if currentActivity == nil, settings.isEnabled {
            // 兜底：查询系统仍持有的本类型活动（静态属性，可能异步；
            // 这里统一 `await`，同步/异步两种签名都能通过编译）。
            let running = await Activity<WeatherActivityAttributes>.activities
            for activity in running {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        await endCurrentActivity()
        settings.setEnabled(false)
        // `Activity.end` 同样**非抛出**（无 error 出口）→ 只记成功。
        // 语义：本方法返回后设备上已无本类型的活动，这是「结束成功」的可判定事实。
        diagnostics.record(source: .liveActivity,
                           succeeded: true,
                           target: cityID,
                           message: Self.endSucceededMessage)
    }

    // MARK: - 内部

    /// 结束内存中的活动并清空引用（**不写偏好**：切城市复用与对外 `end()` 共用）。
    private func endCurrentActivity() async {
        guard let activity = currentActivity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        currentActivity = nil
    }

    /// 统计四个动态字段里有几个非空（用于诊断文案「字段非空 X/4」）。
    ///
    /// 四个字段对应 `WeatherActivityAttributes.ContentState` 的全部字段：
    /// 城市名 / 温度 / 天气描述 / 更新时间。空态（开开关但没推进数据）即 0~1/4，
    /// 正常取数成功后即 4/4 —— 一眼能看出「活动在跑但内容到底有没有填上」。
    private static func fieldCount(cityName: String?,
                                  conditionText: String?,
                                  temperatureText: String?,
                                  updatedAtText: String?) -> Int {
        var count = 0
        if cityName != nil { count += 1 }
        if temperatureText != nil { count += 1 }
        if conditionText != nil { count += 1 }
        if updatedAtText != nil { count += 1 }
        return count
    }

    /// 诊断文案后缀「（字段非空 X/4）」。
    private static func fieldSummary(_ count: Int) -> String {
        "（字段非空 \(count)/4）"
    }

    /// 组装动态内容（纯函数；字段一律可空，无数据即 nil）。
    ///
    /// - Returns: 实时活动的动态内容状态。
    private static func contentState(cityName: String?,
                                     temperatureText: String?,
                                     conditionText: String?,
                                     updatedAtText: String?) -> WeatherActivityAttributes.ContentState {
        WeatherActivityAttributes.ContentState(cityName: cityName,
                                               temperatureText: temperatureText,
                                               conditionText: conditionText,
                                               updatedAtText: updatedAtText)
    }
}

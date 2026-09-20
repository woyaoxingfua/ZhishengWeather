//
//  SettingsView.swift
//  ZhishengWeather（主 App target）
//
//  设置页完整版（A3-4）：外观切换 + 单位切换 + 数据源标注 + 数据状态（诊断）+ 关于页。
//  单位偏好走共享容器（UnitPreference 在 Core/Models）；
//  外观偏好走 **App 本地**标准 UserDefaults（AppearancePreference 在 Core/Models），
//  不进共享容器（小组件只跟随系统深浅）。
//
//  D-4：时间渲染改按**传入时区**（默认设备时区）格式化，「最近更新」随选中城市时区显示。
//  D-5（本轮）：新增「数据状态」—— 逐条数据链路的健康诊断（内存记录，无网络无落盘）。
//
//  诊断留痕（本轮增量）：换图标 / 实时活动 / 小组件时间线的**每一次结果**都写进
//  App 本地诊断记录（`AppDiagnosticsStore`），本页随时可读 —— 真机上失败提示
//  「一闪而过」，只靠内存里的 @State 是留不住的（退出设置页再回来就没了）。
//
//  ⚠️ 诚实纪律：本 App 走未签名 / 重签侧载，App Group 恒不可用，故本页**绝不**
//  承诺「点一下就自动同步城市给小组件」；「小组件自查」只给真能生效的路径
//  （长按 → 编辑小组件 → 城市，手动选一次）。
//

import SwiftUI
import WidgetKit

/// 设置页。
@MainActor
struct SettingsView: View {

    /// 最近一次取数时刻（主屏透传，AC-A3-9）。
    let lastUpdated: Date?

    /// 主数据源展示名（动态派生，不再写死常量，ARCH §5 L3）。
    private var primarySourceDisplayName: String {
        SourceCatalog.all.first { $0.role == .primary }?.displayName ?? "Open-Meteo"
    }

    /// 时间渲染时区（D-4）。默认设备时区；App 侧由 ContentView 透传
    /// `viewModel.selectedTimeZone`。声明为**默认参数**，既有调用点保持源码兼容。
    var timeZone: TimeZone = .current

    /// 新鲜度窗口（秒）：由 ContentView 透传 `viewModel.freshnessWindowInterval`，
    /// 复用主循环**同一个**常量判定链路「正常 / 陈旧」，不在此再写一个 15 分钟字面量。
    var freshnessWindow: TimeInterval

    /// 外观存储（由 ContentView 透传；本页「外观」行写入 → RootView 观察并重建视图树）。
    var appearance: AppearanceStore

    /// 雨伞提醒调度器（开关读写单一真源；App 本地 UserDefaults，不进共享容器）。
    let reminderScheduler: UmbrellaReminderScheduler

    /// 应用图标切换器（AppIconChoice 纯映射 + setAlternateIconName 副作用出口；
    /// App 本地 UserDefaults，不进共享容器）。⚠️ default 参数在调用方的
    /// 非隔离上下文求值，同 UmbrellaReminderScheduler 陷阱——default 给 nil，
    /// 真正创建移到 init 体内。
    private let iconSwitcher: AppIconSwitcher

    /// 实时活动管理器（能力探测 + 手动启动/更新/结束）。
    /// ⚠️ 同 AppIconSwitcher 陷阱：default 参数在调用方的非隔离上下文求值，
    /// 故 default 给 nil，真正创建移到 init 体内。
    private let activityManager: WeatherActivityManager

    /// ⚠️ 初值经**注入的 AppearanceStore** 读取（`appearance.setting`），
    /// 不得直接调 `AppearancePreference.appearance()`——那会绕过注入的 store，
    /// 变成「读硬编码 standard、写注入 store」的镜像缝。
    @State private var appearanceSetting: AppearanceSetting
    @State private var temperatureUnit = UnitPreference.temperatureUnit()
    @State private var windSpeedUnit = UnitPreference.windSpeedUnit()
    @State private var pressureUnit = UnitPreference.pressureUnit()
    /// 雨伞提醒开关（本页状态源；初值由调度器从 App 本地偏好读出，缺省为开）。
    @State private var umbrellaReminderEnabled: Bool
    /// 数据链路健康快照（诊断用；进入页面时从记录器读取一次，进程内内存）。
    @State private var linkHealth: [LinkHealth] = []
    /// 多源管理面板数据（进入页面时从健康跟踪器读取一次）。
    @State private var sourceStatusRows: [SourceStatusRow] = []
    /// Sunrise-Sunset.org 手动停用状态（与 SourcePreferences 同真源）。
    @State private var sunriseSunsetDisabled: Bool = false

    /// 应用图标档位（本页状态源；初值 = 设备事实 + 本地偏好归一化）。
    @State private var iconChoice: IconChoice = .phosphor
    /// 换图标失败短句（非空时在图标区下方弱提示展示；成功后清空）。
    @State private var iconErrorMessage: String?

    /// 实时活动开关（本页状态源；初值由管理器从 App 本地偏好读出，缺省为关）。
    @State private var liveActivityEnabled: Bool
    /// 实时活动失败短句（非空时在实时活动区下方红色小字展示；成功后清空）。
    @State private var liveActivityErrorMessage: String?

    /// 诊断记录读写层（App 本地 UserDefaults；换图标 / 实时活动 / 小组件共用一份）。
    private let diagnostics: AppDiagnosticsStore

    /// 换图标的最近一次结果（**持久**记录；退出设置页再回来仍可读）。
    @State private var iconLastResult: AppDiagnosticEntry?
    /// 实时活动的最近一次结果（**持久**记录）。
    @State private var liveActivityLastResult: AppDiagnosticEntry?
    /// 小组件时间线重载的最近一次结果（**持久**记录）。
    @State private var widgetLastResult: AppDiagnosticEntry?

    /// 本安装换图标是否因 LaunchServices 拒绝（-54）而不可用（判据单一真源在
    /// `AppIconSwitcher.isUnavailableDueToLaunchServicesRejection()`；本页只读取）。
    /// 命中 → 档位 Picker 置灰 + 显示如实说明；未命中（没试过 / 成功过 /
    /// 换了 Bundle Identifier 重签）→ 与现在完全一致，按钮照常可点。
    private var iconUnavailable: Bool {
        iconSwitcher.isUnavailableDueToLaunchServicesRejection()
    }

    /// ⚠️ default 参数在调用方的非隔离上下文求值（Swift 并发模型），而
    /// UmbrellaReminderScheduler 是 @MainActor 隔离 init（CI 实测挂编译，
    /// 与 LocationProvider 同款陷阱）。故 default 用 nil，真正创建移到本
    /// init 体内——SettingsView 整体 @MainActor，体内已隔离，合法。
    init(lastUpdated: Date?,
         timeZone: TimeZone = .current,
         freshnessWindow: TimeInterval,
         appearance: AppearanceStore,
         reminderScheduler: UmbrellaReminderScheduler? = nil,
         iconSwitcher: AppIconSwitcher? = nil,
         activityManager: WeatherActivityManager? = nil,
         diagnostics: AppDiagnosticsStore? = nil) {
        self.lastUpdated = lastUpdated
        self.timeZone = timeZone
        self.freshnessWindow = freshnessWindow
        self.appearance = appearance
        let scheduler = reminderScheduler ?? UmbrellaReminderScheduler()
        self.reminderScheduler = scheduler
        let switcher = iconSwitcher ?? AppIconSwitcher()
        self.iconSwitcher = switcher
        let manager = activityManager ?? WeatherActivityManager()
        self.activityManager = manager
        // 生产路径下三者都落在 App 本地 `.standard`：切换器与活动管理器默认的
        // 诊断 store 同为 standard（或 shared），故本页读得到它们写的记录。
        self.diagnostics = diagnostics ?? AppDiagnosticsStore.shared
        // @State 初值必须在 init 内赋（不能在属性默认值处触碰非隔离参数）。
        // 外观初值走注入的 AppearanceStore（与 .onChange 的写路径同一个 store）。
        _appearanceSetting = State(initialValue: appearance.setting)
        _umbrellaReminderEnabled = State(initialValue: scheduler.isEnabled)
        _iconChoice = State(initialValue: switcher.currentChoice())
        _liveActivityEnabled = State(initialValue: manager.isEnabled)
    }

    var body: some View {
        Form {
            // 三档外观：深色 / 浅色 / 跟随系统（默认跟随系统）。
            // 写入即触发 RootView 重建视图树（切换即重绘，无需重启 App）。
            Section("外观") {
                Picker("外观", selection: $appearanceSetting) {
                    Text("深色").tag(AppearanceSetting.dark)
                    Text("浅色").tag(AppearanceSetting.light)
                    Text("跟随系统").tag(AppearanceSetting.system)
                }
                .onChange(of: appearanceSetting) { _, newValue in
                    appearance.set(newValue)
                }
            }

            // 应用图标三档：磷光（默认）/ 清冷翡翠 / 终端雨字。
            // 走 iOS 10.3+ 备用图标 API（setAlternateIconName）；
            // 系统切换成功会弹**自己的**确认框，本页不再补提示。
            // 文案单一真源：IconChoice.displayName（Core）。
            Section("应用图标") {
                Picker("应用图标", selection: $iconChoice) {
                    ForEach(IconChoice.allCases, id: \.self) { choice in
                        Text(choice.isDefault ? "\(choice.displayName)（默认）" : choice.displayName)
                            .tag(choice)
                    }
                }
                // 本安装因 LaunchServices 拒绝（-54）而不可用时，与其让用户点了静默失败，
                // 不如直接不给点 + 如实说明（文案单一真源在 AppIconSwitcher）。
                .disabled(iconUnavailable)
                .onChange(of: iconChoice) { _, newValue in
                    switchIcon(to: newValue)
                }
                if iconUnavailable {
                    Text(AppIconSwitcher.unavailableDueToRejectionHint)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
                // 运行期诊断行（读设备事实，而非构建产物的假设）：用户截一张图
                // 即可判定本安装是否保留备用图标声明——侧载重签裁 plist 时这里是「否」。
                // 文案与判据的单一真源都在 AppIconSwitcher，视图只负责展示。
                Text(iconSwitcher.diagnosticsSummary())
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                if !iconSwitcher.supportsAlternateIcons() {
                    Text(AppIconSwitcher.declarationMissingHint)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
                if let iconErrorMessage {
                    Text(iconErrorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
                // 持久化的最近一次结果：**退出设置页再回来仍然可读**，这是
                // 「闪一下就没了」的失败唯一的留存处。
                if let iconLastResult {
                    diagnosticResultRow(iconLastResult)
                }
            }

            // 实时活动（ActivityKit）：能力探测诚实降级。
            // 能力不可用 → 开关**置灰**（绝不让用户点了没反应）+ 红色说明；
            // 可用 → 12 号次级说明写清「自动更新尚未接线」。
            // 所有文案的单一真源都在 WeatherActivityManager，本页只负责展示。
            Section("实时活动") {
                Toggle("显示实时活动", isOn: $liveActivityEnabled)
                    // 能力不可用时禁用：与其让用户点了静默失败，不如直接不给点。
                    .disabled(!activityManager.areActivitiesEnabled)
                    .onChange(of: liveActivityEnabled) { _, newValue in
                        toggleLiveActivity(newValue)
                    }
                if activityManager.areActivitiesEnabled {
                    Text(WeatherActivityManager.availableHint)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    Text(WeatherActivityManager.unavailableHint)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
                if let liveActivityErrorMessage {
                    Text(liveActivityErrorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
                // 持久化的最近一次结果（含失败时的 domain + code）。
                if let liveActivityLastResult {
                    diagnosticResultRow(liveActivityLastResult)
                }
            }

            // 小组件自查（本轮新增）：一眼看清「共享容器能不能用」+
            // 手动请求一次时间线重载，并如实说明本渠道上城市只能手动选。
            Section("小组件自查") {
                HStack {
                    Text("共享容器")
                    Spacer(minLength: 8)
                    Text(sharedContainerAvailable ? "可用" : "不可用")
                        .foregroundStyle(sharedContainerAvailable ? Theme.secondaryText : Color.red)
                }
                Button("重载小组件时间线") {
                    requestWidgetTimelineReload()
                }
                if let widgetLastResult {
                    diagnosticResultRow(widgetLastResult)
                }
                Text(sharedContainerAvailable ? Self.widgetContainerOKHint : Self.widgetManualCityHint)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }

            Section("单位") {
                Picker("温度", selection: $temperatureUnit) {
                    Text("℃").tag("celsius")
                    Text("℉").tag("fahrenheit")
                }
                .onChange(of: temperatureUnit) { _, newValue in
                    UnitPreference.setTemperatureUnit(newValue)
                    // 切单位：用最新单位把当前缓存天气重推一次（℉/℃ 切换时灵动岛温度符号要跟着变）。
                    Task {
                        await activityManager.pushLatestIfRunning()
                        liveActivityLastResult = diagnostics.latest(for: .liveActivity)
                    }
                }

                Picker("风速", selection: $windSpeedUnit) {
                    Text("m/s").tag("ms")
                    Text("km/h").tag("kmh")
                }
                .onChange(of: windSpeedUnit) { _, newValue in
                    UnitPreference.setWindSpeedUnit(newValue)
                    // 切单位：重推当前天气（温度符号随偏好变化，需刷新灵动岛展示）。
                    Task {
                        await activityManager.pushLatestIfRunning()
                        liveActivityLastResult = diagnostics.latest(for: .liveActivity)
                    }
                }

                // D-2：气压单位独立设置（原版「温度/风速/气压」三档独立；走共享容器，Widget 同步）。
                Picker("气压", selection: $pressureUnit) {
                    Text("hPa").tag("hpa")
                    Text("mmHg").tag("mmhg")
                    Text("inHg").tag("inhg")
                }
                .onChange(of: pressureUnit) { _, newValue in
                    UnitPreference.setPressureUnit(newValue)
                    // 切单位：重推当前天气（温度符号随偏好变化，需刷新灵动岛展示）。
                    Task {
                        await activityManager.pushLatestIfRunning()
                        liveActivityLastResult = diagnostics.latest(for: .liveActivity)
                    }
                }
            }

            Section("数据源") {
                HStack {
                    Text("天气数据")
                    Spacer(minLength: 8)
                    Text(primarySourceDisplayName)
                        .foregroundStyle(Theme.secondaryText)
                }
                if let lastUpdated {
                    HStack {
                        Text("最近更新")
                        Spacer(minLength: 8)
                        // D-4：按传入时区渲染（复用 WeatherTimeFormatter 的格式器缓存）。
                        Text(WeatherTimeFormatter.string(from: lastUpdated,
                                                         format: "MM-dd HH:mm",
                                                         timeZone: timeZone))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }

            // D-5：数据链路健康面板。每条链路一行；记录器为空（尚未跑过任何链路）
            // 时显示「从未尝试」，**不是**空屏。
            Section("数据状态") {
                ForEach(linkHealth) { record in
                    linkHealthRow(record)
                }
            }

            // D-C5：多源管理（ARCH §4.3 / §5 L3）。
            // 逐源显示状态（在用 / 备用 / 已摘除·原因 EV-n / 未配置）+ 最近成功 + 今日用量，
            // 并支持手动停用某源（停用只影响该源降级参与，不影响其余源、绝不换城市）。
            Section("多源管理") {
                if sourceStatusRows.isEmpty {
                    Text("尚未尝试任何辅助数据源")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                ForEach(sourceStatusRows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.displayName)
                            Spacer(minLength: 8)
                            Text(Self.sourceStatusText(row.state))
                                .foregroundStyle(Self.sourceStatusColor(row.state))
                        }
                        if let success = row.lastSuccessAt {
                            HStack {
                                Text("最近成功")
                                    .foregroundStyle(Theme.secondaryText)
                                Spacer(minLength: 8)
                                Text(WeatherTimeFormatter.string(from: success,
                                                                 format: "MM-dd HH:mm",
                                                                 timeZone: timeZone))
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            .font(.system(size: 12))
                        }
                        HStack {
                            Text("今日用量")
                                .foregroundStyle(Theme.secondaryText)
                            Spacer(minLength: 8)
                            Text("\(row.todayUsage)")
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .font(.system(size: 12))
                        if row.id == .sunriseSunset {
                            // 手动停用：开关 = 启用；停用只影响该源降级参与，不换城市。
                            Toggle("启用该数据源", isOn: Binding(
                                get: { !sunriseSunsetDisabled },
                                set: { newValue in
                                    sunriseSunsetDisabled = !newValue
                                    SourcePreferences.shared.setDisabled(.sunriseSunset, disabled: !newValue)
                                }))
                        }
                    }
                }
            }

            Section("关于") {
                HStack {
                    Text("版本")
                    Spacer(minLength: 8)
                    Text(Self.appVersion)
                        .foregroundStyle(Theme.secondaryText)
                }
                Link(destination: URL(string: "https://github.com/woyaoxingfua/ZhishengWeather")!) {
                    HStack {
                        Text("开源仓库")
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadLinkHealth()
            reloadDiagnosticResults()
            await loadSourceStatus()
        }
    }

    // MARK: - 诊断记录（持久化读取）

    /// 共享容器是否可用（判据的唯一真源是 Core 的 `AppGroupStore`）。
    private var sharedContainerAvailable: Bool {
        AppGroupStore.isSharedContainerAvailable
    }

    /// 从诊断记录里重新读取三处「最近一次结果」（进页面 / 操作后各调一次）。
    private func reloadDiagnosticResults() {
        iconLastResult = diagnostics.latest(for: .appIcon)
        liveActivityLastResult = diagnostics.latest(for: .liveActivity)
        widgetLastResult = diagnostics.latest(for: .widgetTimeline)
    }

    /// 一条诊断结果行（时间 + 成败 + 操作对象 + 完整描述；失败标红并带 domain/code）。
    ///
    /// - Parameter entry: 持久化的诊断记录。
    private func diagnosticResultRow(_ entry: AppDiagnosticEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("最近记录")
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 8)
                Text("\(entry.timeText) \(entry.outcomeText)")
                    .foregroundStyle(entry.succeeded ? Theme.secondaryText : Color.red)
            }
            Text("目标：\(entry.target)")
                .foregroundStyle(Theme.secondaryText)
            // 完整描述（失败句由 `AppIconSwitcher.failureMessage(for:)` /
            // `WeatherActivityManager.failureMessage(for:)` 产出，含 domain + code）。
            Text(entry.message)
                .foregroundStyle(entry.succeeded ? Theme.secondaryText : Color.red)
            if let domain = entry.errorDomain, let code = entry.errorCode {
                Text("错误码：\(domain) \(code)")
                    .foregroundStyle(Color.red)
            }
        }
        .font(.system(size: 12))
    }

    /// 请求系统重载一次小组件时间线，并把「已请求重载 HH:mm:ss」落进诊断记录。
    ///
    /// ⚠️ 诚实边界：`WidgetCenter.reloadAllTimelines()`（iOS 14 经典 API，
    /// 不用 iOS 17 的泛型重载）**只是请系统重新拉取一次时间线**；它不会、
    /// 也不能把主 App 选的城市同步给小组件 —— 本渠道上共享容器不可用，
    /// 城市只能由用户在「编辑小组件」里手动选一次。
    private func requestWidgetTimelineReload() {
        WidgetCenter.shared.reloadAllTimelines()
        let now: Date = Date()
        let entry = AppDiagnosticEntry(source: .widgetTimeline,
                                       succeeded: true,
                                       target: Self.widgetReloadTargetName,
                                       message: "已请求重载 \(AppDiagnosticEntry.timeString(from: now))",
                                       occurredAt: now)
        diagnostics.record(entry)
        // 立即显示：不等下一次读取（用户点完就要看到「确实请求过了」）。
        widgetLastResult = entry
    }

    // MARK: - 应用图标切换

    /// 切换应用图标（副作用出口走注入的 AppIconSwitcher）。
    ///
    /// 失败：恢复 Picker 到设备当前档位并展示短句（错误不静默）；
    /// 成功：系统自带确认弹窗，本侧不补提示。
    private func switchIcon(to choice: IconChoice) {
        Task { @MainActor in
            if let errorMessage = await iconSwitcher.apply(choice) {
                iconErrorMessage = errorMessage
                // 设备事实优先：切换失败时回滚 UI 状态（偏好未被写入）。
                iconChoice = iconSwitcher.currentChoice()
            } else {
                iconErrorMessage = nil
            }
            // 刷新持久记录行（成功与失败都会留一条，供用户截图反馈）。
            iconLastResult = diagnostics.latest(for: .appIcon)
        }
    }

    // MARK: - 实时活动开关

    /// 实时活动开关变更（副作用出口走注入的 WeatherActivityManager）。
    ///
    /// 开启：先用空 ContentState 启动活动（本页拿不到城市/天气文案，如实传 nil，
    /// **绝不填伪数据**；更新时间取本页已有的 `lastUpdated`）；启动成功后立刻调用
    /// `pushLatestIfRunning` 把**已缓存的当前天气**补推进去 —— 这样「开了开关」这个
    /// 动作本身就能拿到数据，而不是被动等下一次取数（否则灵动岛会一直空着）。
    /// 失败：开关回滚到设备事实（偏好未被写入）+ 展示红色短句；绝不重试。
    /// 关闭：结束活动并清空引用。
    ///
    /// - Parameter enabled: 目标状态。
    private func toggleLiveActivity(_ enabled: Bool) {
        Task { @MainActor in
            if enabled {
                let startMessage = await activityManager.start(cityName: nil,
                                                              conditionText: nil,
                                                              updatedAtText: updatedAtText())
                if let startMessage {
                    // 启动本身失败（能力未开 / 系统拒绝）：如实展示短句，开关回滚。
                    liveActivityErrorMessage = startMessage
                } else {
                    // 启动成功：立刻把当前已缓存的天气推进去（若已有取数结果），
                    // 否则灵动岛会一直空着。无数据则 pushLatestIfRunning 给出提示。
                    let pushMessage = await activityManager.pushLatestIfRunning()
                    liveActivityErrorMessage = pushMessage
                }
                // 设备事实优先：启动失败时回滚开关（管理器未写偏好）。
                liveActivityEnabled = activityManager.isEnabled
            } else {
                await activityManager.end()
                liveActivityErrorMessage = nil
            }
            // 刷新持久记录行（启动/更新结果会带上「字段非空 X/4」留在这一行）。
            liveActivityLastResult = diagnostics.latest(for: .liveActivity)
        }
    }

    /// 实时活动的更新时间文案（复用本页「最近更新」的时区与格式；无数据为 nil）。
    ///
    /// - Returns: 形如「09-18 23:21」；`lastUpdated` 为空时返回 nil。
    private func updatedAtText() -> String? {
        guard let lastUpdated else { return nil }
        return WeatherTimeFormatter.string(from: lastUpdated,
                                           format: "MM-dd HH:mm",
                                           timeZone: timeZone)
    }

    // MARK: - 数据状态（D-5 诊断面板）

    /// 单条链路行：显示名 + 派生状态 + 最近成功时刻（按城市时区）+ 最近错误（截断）。
    private func linkHealthRow(_ record: LinkHealth) -> some View {
        let state = record.state(now: Date(), freshnessWindow: freshnessWindow)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.displayName)
                Spacer(minLength: 8)
                Text(state.displayName)
                    .foregroundStyle(stateColor(state))
            }
            if let success = record.lastSuccessAt {
                HStack {
                    Text("最近成功")
                        .foregroundStyle(Theme.secondaryText)
                    Spacer(minLength: 8)
                    // D-4：与「最近更新」同一时区与格式器（选中城市时区）。
                    Text(WeatherTimeFormatter.string(from: success,
                                                     format: "MM-dd HH:mm",
                                                     timeZone: timeZone))
                        .foregroundStyle(Theme.secondaryText)
                }
                .font(.system(size: 12))
            }
            if let error = record.lastErrorMessage, !error.isEmpty {
                Text("最近错误：\(truncated(error))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    /// 派生状态 → 颜色（仅诊断用；不使用语义色以外的新配色常量）。
    private func stateColor(_ state: LinkHealthState) -> Color {
        switch state {
        case .healthy: return .green
        case .stale: return .orange
        case .failed: return .red
        case .neverAttempted: return Theme.secondaryText
        }
    }

    /// 错误信息截断（面板宽度有限）：超过 60 字保留头部并加省略号。
    private func truncated(_ text: String) -> String {
        text.count <= 60 ? text : String(text.prefix(60)) + "…"
    }

    /// 读取链路健康快照（进程内内存；无网络、无落盘、无配额）。
    private func loadLinkHealth() async {
        linkHealth = await LinkHealthRecorder.shared.snapshot()
    }

    /// 读取多源管理面板数据（源级健康快照 + 手动停用状态）。
    private func loadSourceStatus() async {
        sourceStatusRows = await SourceHealthTracker.shared.snapshot(now: Date())
        sunriseSunsetDisabled = SourcePreferences.shared.isDisabled(.sunriseSunset)
    }

    /// 多源状态 → 文案（单一真源在 ExclusionReason.displayText）。
    private static func sourceStatusText(_ state: SourceStatusState) -> String {
        switch state {
        case .primaryActive: return "在用"
        case .standby: return "备用"
        case .excluded(let reason): return reason.displayText
        case .notConfigured: return "未配置"
        }
    }

    /// 多源状态 → 颜色（仅诊断用；不引入新配色常量）。
    private static func sourceStatusColor(_ state: SourceStatusState) -> Color {
        switch state {
        case .primaryActive: return .green
        case .standby: return Theme.secondaryText
        case .excluded: return .orange
        case .notConfigured: return Theme.secondaryText
        }
    }

    /// 诊断记录里「时间线重载」的操作对象名（用方法名，便于一眼对上代码）。
    private static let widgetReloadTargetName: String = "reloadAllTimelines"

    /// 小组件自查：共享容器**可用**时的说明。
    private static let widgetContainerOKHint: String =
        "共享容器可用：主 App 取数后会写入同一份数据，小组件能读到。"

    /// 小组件自查：共享容器**不可用**（未签名 / 重签侧载下的常态）时的如实说明。
    ///
    /// 口径对齐 Core `WidgetCopy.hintText` 的 `.noCity` 分支（「长按小组件 →
    /// 编辑，选择城市」）—— 那是小组件空态文案的单一真源，本句必须与它同口径，
    /// **绝不**另写一套互相矛盾的说法；同样**绝不**承诺「点一下就自动同步」，
    /// 因为本渠道上共享容器恒不可用，自动同步根本做不到。
    private static let widgetManualCityHint: String =
        "本安装的共享容器不可用（未签名 / 重签侧载下 entitlements 不生效），"
        + "主 App 选的城市无法自动同步给小组件。请长按桌面小组件 → 编辑小组件 → 城市，"
        + "手动选一次；该选择由系统按小组件实例保存，卸载重装前一直有效。"
        + "「重载小组件时间线」只请系统重新拉取一次，不会同步城市。"

    /// App 版本号（Info.plist MARKETING_VERSION，AC-A3-10）。
    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return version ?? "--"
    }
}

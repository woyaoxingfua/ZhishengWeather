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

import SwiftUI

/// 设置页。
@MainActor
struct SettingsView: View {

    /// 最近一次取数时刻（主屏透传，AC-A3-9）。
    let lastUpdated: Date?

    /// 数据源名称（当前恒为 Open-Meteo）。
    let dataSourceName: String = "Open-Meteo"

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

    @State private var appearanceSetting = AppearancePreference.appearance()
    @State private var temperatureUnit = UnitPreference.temperatureUnit()
    @State private var windSpeedUnit = UnitPreference.windSpeedUnit()
    @State private var pressureUnit = UnitPreference.pressureUnit()
    /// 雨伞提醒开关（本页状态源；初值由调度器从 App 本地偏好读出，缺省为开）。
    @State private var umbrellaReminderEnabled: Bool
    /// 数据链路健康快照（诊断用；进入页面时从记录器读取一次，进程内内存）。
    @State private var linkHealth: [LinkHealth] = []

    /// 应用图标档位（本页状态源；初值 = 设备事实 + 本地偏好归一化）。
    @State private var iconChoice: IconChoice = .phosphor
    /// 换图标失败短句（非空时在图标区下方弱提示展示；成功后清空）。
    @State private var iconErrorMessage: String?

    /// ⚠️ default 参数在调用方的非隔离上下文求值（Swift 并发模型），而
    /// UmbrellaReminderScheduler 是 @MainActor 隔离 init（CI 实测挂编译，
    /// 与 LocationProvider 同款陷阱）。故 default 用 nil，真正创建移到本
    /// init 体内——SettingsView 整体 @MainActor，体内已隔离，合法。
    init(lastUpdated: Date?,
         timeZone: TimeZone = .current,
         freshnessWindow: TimeInterval,
         appearance: AppearanceStore,
         reminderScheduler: UmbrellaReminderScheduler? = nil,
         iconSwitcher: AppIconSwitcher? = nil) {
        self.lastUpdated = lastUpdated
        self.timeZone = timeZone
        self.freshnessWindow = freshnessWindow
        self.appearance = appearance
        let scheduler = reminderScheduler ?? UmbrellaReminderScheduler()
        self.reminderScheduler = scheduler
        let switcher = iconSwitcher ?? AppIconSwitcher()
        self.iconSwitcher = switcher
        // @State 初值必须在 init 内赋（不能在属性默认值处触碰非隔离参数）。
        _umbrellaReminderEnabled = State(initialValue: scheduler.isEnabled)
        _iconChoice = State(initialValue: switcher.currentChoice())
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
                .onChange(of: iconChoice) { _, newValue in
                    switchIcon(to: newValue)
                }
                if let iconErrorMessage {
                    Text(iconErrorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }

            Section("单位") {
                Picker("温度", selection: $temperatureUnit) {
                    Text("℃").tag("celsius")
                    Text("℉").tag("fahrenheit")
                }
                .onChange(of: temperatureUnit) { _, newValue in
                    UnitPreference.setTemperatureUnit(newValue)
                }

                Picker("风速", selection: $windSpeedUnit) {
                    Text("m/s").tag("ms")
                    Text("km/h").tag("kmh")
                }
                .onChange(of: windSpeedUnit) { _, newValue in
                    UnitPreference.setWindSpeedUnit(newValue)
                }

                // D-2：气压单位独立设置（原版「温度/风速/气压」三档独立；走共享容器，Widget 同步）。
                Picker("气压", selection: $pressureUnit) {
                    Text("hPa").tag("hpa")
                    Text("mmHg").tag("mmhg")
                    Text("inHg").tag("inhg")
                }
                .onChange(of: pressureUnit) { _, newValue in
                    UnitPreference.setPressureUnit(newValue)
                }
            }

            Section("数据源") {
                HStack {
                    Text("天气数据")
                    Spacer(minLength: 8)
                    Text(dataSourceName)
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
        .task { await loadLinkHealth() }
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
        }
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

    /// App 版本号（Info.plist MARKETING_VERSION，AC-A3-10）。
    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return version ?? "--"
    }
}

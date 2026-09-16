//
//  SettingsView.swift
//  ZhishengWeather（主 App target）
//
//  设置页完整版（A3-4）：单位切换 + 数据源标注 + 数据状态（诊断）+ 关于页。
//  单位偏好走共享容器（UnitPreference 在 Core/Models）。
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

    @State private var temperatureUnit = UnitPreference.temperatureUnit()
    @State private var windSpeedUnit = UnitPreference.windSpeedUnit()
    /// 数据链路健康快照（诊断用；进入页面时从记录器读取一次，进程内内存）。
    @State private var linkHealth: [LinkHealth] = []

    var body: some View {
        Form {
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

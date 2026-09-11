//
//  ContentView.swift
//  ZhishengWeather（主 App target）
//
//  主屏：NavigationStack 包裹（F-B 城市管理入口）+ 单一 ScrollView + VStack，
//  自上而下 7 个区块：
//    ① 顶部栏（城市按钮 + ⌄ → 城市页 | 刷新）② Hero 温度区 ③ 指标格（风速 / 湿度）
//    ④ 逐小时预报 ⑤ 逐日预报（F-A，nil/空时整块隐藏）⑥ 月相 ⑦ 页脚（更新时间）
//  支持下拉刷新；加载中显示占位；失败时用缓存 + 提示降级。
//

import SwiftUI

/// @MainActor：同 CityListView——辅助成员（content 等）需主 actor 隔离
/// 才能合法触碰 @MainActor 的 WeatherViewModel。
@MainActor
struct ContentView: View {

    let viewModel: WeatherViewModel

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            // 自定义顶部栏（F-B：城市名变按钮），隐藏系统导航条。
            .navigationBarHidden(true)
        }
    }

    // MARK: - 状态分支

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            loadingView

        case .loaded(let snapshot):
            mainScroll(snapshot: snapshot,
                       footerText: "更新于 \(Self.timeFormatter.string(from: snapshot.fetchedAt))",
                       footerHighlighted: false)

        case .failed(let cached, let message):
            if let cached {
                mainScroll(snapshot: cached,
                           footerText: "更新于 \(Self.timeFormatter.string(from: cached.fetchedAt)) · \(message)",
                           footerHighlighted: true)
            } else {
                emptyView(message: message)
            }
        }
    }

    // MARK: - 主滚动视图

    private func mainScroll(snapshot: WeatherSnapshot,
                            footerText: String,
                            footerHighlighted: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                topBar(snapshot: snapshot)
                heroSection(snapshot: snapshot)
                metricsSection(snapshot: snapshot)
                hourlySection(snapshot: snapshot)
                // F-A 逐日区块：位于逐小时（④）之下、月相（⑤）之上（F-A-1）。
                // daily 为 nil 或空数组时整块不渲染，连标题都不出（AC-A7）。
                if let daily = snapshot.daily, !daily.isEmpty {
                    DailyForecastSection(daily: daily)
                }
                moonSection(snapshot: snapshot)
                footerSection(footerText, highlighted: footerHighlighted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    // MARK: - ① 顶部栏

    private func topBar(snapshot: WeatherSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                // F-B：城市名变为可点按钮（+ ⌄），push 城市管理页。
                // 其余（日期、刷新按钮）零改动。
                NavigationLink {
                    CityListView(viewModel: viewModel)
                } label: {
                    HStack(spacing: 4) {
                        Text(snapshot.location.name)
                            .font(.system(size: Theme.FontSize.city, weight: .semibold))
                            .foregroundStyle(Theme.primaryText)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换城市，当前 \(snapshot.location.name)")

                Text(Self.dateFormatter.string(from: snapshot.fetchedAt))
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 8)
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(8)
                    .background(Theme.surface, in: Circle())
            }
            .accessibilityLabel("刷新")
        }
    }

    // MARK: - ② Hero 温度区

    private func heroSection(snapshot: WeatherSnapshot) -> some View {
        VStack(spacing: 12) {
            Text("\(Int(snapshot.temperature.rounded()))°")
                .font(.system(size: Theme.FontSize.temperature, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            HStack(spacing: 10) {
                WeatherSymbol(code: snapshot.weatherCode,
                              isDay: snapshot.isDay,
                              size: 34)
                Text(WMOCodeMapper.description(for: snapshot.weatherCode))
                    .font(.system(size: Theme.FontSize.condition, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
            }

            HStack(spacing: 16) {
                Text("体感 \(Int(snapshot.apparentTemperature.rounded()))°")
                Text("↑\(Int(snapshot.dailyHigh.rounded()))°")
                Text("↓\(Int(snapshot.dailyLow.rounded()))°")
            }
            .font(.system(size: Theme.FontSize.metric))
            .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - ③ 指标格

    private func metricsSection(snapshot: WeatherSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                  spacing: 12) {
            MetricCell(icon: "wind",
                       value: "\(String(format: "%.1f", snapshot.windSpeed)) m/s \(Self.windDirectionText(snapshot.windDirection))",
                       caption: "风速")
            MetricCell(icon: "humidity.fill",
                       value: "\(snapshot.humidity)%",
                       caption: "湿度")
        }
    }

    // MARK: - ④ 逐小时预报

    private func hourlySection(snapshot: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("未来数小时")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            HourlyStrip(points: snapshot.hourly)
        }
    }

    // MARK: - ⑤ 月相区

    private func moonSection(snapshot: WeatherSnapshot) -> some View {
        let moon = snapshot.moonPhase
        return HStack(spacing: 14) {
            Image(systemName: moon.symbolName)
                .font(.system(size: 30))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accent)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(moon.name.rawValue)
                    .font(.system(size: Theme.FontSize.metric, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("照亮 \(moon.illuminationPercent)%")
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(Theme.divider, lineWidth: 0.5)
        )
    }

    // MARK: - ⑥ 页脚

    private func footerSection(_ text: String, highlighted: Bool) -> some View {
        Text(text)
            .font(.system(size: Theme.FontSize.footnote))
            .foregroundStyle(highlighted ? Theme.accentSecondary : Theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
    }

    // MARK: - 占位视图

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Theme.accent)
            Text("正在获取天气…")
                .font(.system(size: Theme.FontSize.metric))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyView(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(Theme.secondaryText)
            Text("暂无天气数据")
                .font(.system(size: Theme.FontSize.condition, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text(message)
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Text("重试")
                    .font(.system(size: Theme.FontSize.metric, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Theme.accent, in: Capsule())
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 格式化工具

    /// 「9月11日 00:31」。
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    /// 「00:31」。
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// 风向角度 → 8 方位中文。
    private static func windDirectionText(_ degrees: Double) -> String {
        let directions = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        let index = Int((positive / 45).rounded()) % directions.count
        return directions[index]
    }
}

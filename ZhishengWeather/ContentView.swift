//
//  ContentView.swift
//  ZhishengWeather（主 App target）
//
//  主屏：NavigationStack 包裹（F-B 城市管理入口）+ 单一 ScrollView + VStack，
//  自上而下 8 个区块：
//    ① 顶部栏（城市按钮 + ⌄ → 城市页 | 刷新）② Hero 温度区
//    ②b 昨日对比行（A1-5，nil 隐藏）③ 指标格（风速 / 湿度 / 气压，A1 后 3 格）
//    ④ 逐小时预报（A1 后 ≤24 条）⑤ 逐日预报（A1 后 3/7/15 三档）
//    ⑥ 月相 + 日出日落行（A1-4） ⑦ 页脚（更新时间）
//  支持下拉刷新；加载中显示占位；失败时用缓存 + 提示降级。
//  A1-7/A1-8：深链 + 快捷方式统一路由出口（AppRouter，挂在 body 层全分支生效）。
//

import SwiftUI

/// @MainActor：同 CityListView——辅助成员（content 等）需主 actor 隔离
/// 才能合法触碰 @MainActor 的 WeatherViewModel。
@MainActor
struct ContentView: View {

    let viewModel: WeatherViewModel

    /// 编程式 push（AppRouter 触发跳转用）。
    @State private var navigation: NavigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigation) {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            // 自定义顶部栏（F-B：城市名变按钮），隐藏系统导航条。
            .navigationBarHidden(true)
            // A1-7/A1-8：深链路由出口（zhisheng://refresh 等，与快捷方式共用 AppRouter）。
            // 挂在 body 层：state 任何分支（loading/empty/failed）都能接住深链。
            .onOpenURL { url in
                AppRouter.shared.handle(url: url, viewModel: viewModel)
            }
            // A1-8：快捷方式路由观察（AppDelegate/SceneDelegate 转发 → AppRouter 发布 → 这里消费）。
            // ⚠️ @Observable 宏不合成 $投影（那是 ObservableObject/@Published 的机制），
            // 观察用 onChange(of:) 监听 pendingRoute 值本身（其内 UUID 令牌保证同目的地也触发）。
            .onChange(of: AppRouter.shared.pendingRoute) { _, pending in
                handleRouterRoute(pending)
            }
            // 冷启动兜底：AppDelegate 在配置 Scene 前已读到 shortcutItems 并写入
            // pendingRoute，而 @Observable 不会就「初始值」重复通知，故首值不触发上面的
            // onChange；此处于视图首现时补消费一次首值（热启动的快捷方式仍走 onChange）。
            .task {
                if let pending = AppRouter.shared.pendingRoute {
                    handleRouterRoute(pending)
                }
            }
            // 跳转目的地注册（A1-8 搜索 → 城市列表；A3-4 设置 → SettingsView）。
            .navigationDestination(for: CityRoute.self) { route in
                switch route {
                case .cities:
                    CityListView(viewModel: viewModel)
                case .settings:
                    // D-4：透传选中城市时区，设置页「最近更新」随城市时区显示。
                    SettingsView(lastUpdated: lastUpdatedDate,
                                 timeZone: viewModel.selectedTimeZone)
                }
            }
        }
    }

    /// 消费 AppRouter 发布的路由令牌：刷新类直接执行，跳转类做 push。
    private func handleRouterRoute(_ pending: AppRouter.PendingRoute?) {
        guard let consumed = AppRouter.shared.consume(pending, viewModel: viewModel) else { return }
        switch consumed {
        case .searchCity:
            navigation.append(CityRoute.cities)
        case .settings:
            navigation.append(CityRoute.settings)
        case .refresh:
            break // consume 内已处理强刷
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
                       footerText: "更新于 \(timeText(snapshot.fetchedAt))",
                       footerHighlighted: false)

        case .failed(let cached, let message):
            if let cached {
                mainScroll(snapshot: cached,
                           footerText: "更新于 \(timeText(cached.fetchedAt)) · \(message)",
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
                // A2-2：一句话摘要（Hero 温度下一行；nil → 整行隐藏，AC-A2-8）。
                // 摘要与 Hero 同源展示，不参与模块排序（归组 Hero）。
                if let summary = WeatherSummaryEngine.summary(for: snapshot) {
                    Text(summary)
                        .font(.system(size: Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Theme.accentSecondary)
                }
                // B1-2：短时降水卡（未来约 2 小时 · 15 分钟粒度 · 由逐小时插值·非实况外推）。
                // 干窗 / 无数据 → 整卡隐藏（沿用原 Android 行为，AC-B1-8/B1-9）；
                // 时刻按选中城市时区渲染（D-4 一致）。数据来自既有无新增请求的 forecast。
                if let minutely = snapshot.minutely15,
                   MinutelyPrecipitationEngine.hasPrecipitation(minutely) {
                    MinutelyPrecipitationCard(points: minutely,
                                              timeZone: viewModel.selectedTimeZone)
                }
                // A2-7：可排序/可隐藏区块按 HomeSectionOrder 渲染
                //（Hero 与页脚固定不参与，AC-A2-21 例外条款）。
                ForEach(orderedVisibleSections) { section in
                    sectionView(section, snapshot: snapshot)
                }
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

    /// 最近一次取数时刻（设置页数据源标注，AC-A3-9）。
    private var lastUpdatedDate: Date? {
        if case .loaded(let snapshot) = viewModel.state { return snapshot.fetchedAt }
        if case .failed(let cached, _) = viewModel.state { return cached?.fetchedAt }
        return nil
    }

    // MARK: - A2-7 区块排序/隐藏

    /// 当前用户排序且未被隐藏的区块。
    private var orderedVisibleSections: [HomeSection] {
        HomeSectionOrder.current().filter { !HomeSectionOrder.hidden().contains($0) }
    }

    /// 区块视图分发（每个 case 对应主屏一个既有区块；内容与原实现逐一对应）。
    @ViewBuilder
    private func sectionView(_ section: HomeSection, snapshot: WeatherSnapshot) -> some View {
        switch section {
        case .yesterday:
            // A1-5：昨日对比行（yesterday == nil → 整行不渲染，AC-A1-16）。
            YesterdayComparisonSection(yesterday: snapshot.yesterday,
                                       todayHigh: snapshot.dailyHigh,
                                       todayLow: snapshot.dailyLow)
        case .metrics:
            metricsSection(snapshot: snapshot)
        case .airQuality:
            // A2-1：空气卡（独立链路，airQuality == nil 整卡不渲染，R5）。
            if let airQuality = viewModel.airQuality {
                AirQualityCard(airQuality: airQuality)
            }
        case .hourly:
            hourlySection(snapshot: snapshot)
        case .daily:
            // F-A 逐日区块：daily 为 nil 或空数组时整块不渲染（AC-A7）。
            if let daily = snapshot.daily, !daily.isEmpty {
                // D-4：透传选中城市时区（逐日行/15 天页时刻按城市时区渲染）。
                DailyForecastSection(daily: daily,
                                     latitude: snapshot.location.latitude,
                                     longitude: snapshot.location.longitude,
                                     snapshot: snapshot,
                                     timeZone: viewModel.selectedTimeZone)
            }
        case .lifeIndex:
            // A2-3：生活指数（本地估算）。
            LifeIndexSection(items: LifeIndexEngine.indices(for: snapshot))
        case .moon:
            moonSection(snapshot: snapshot)
            // A3-1：历史天气入口（独立第三链路页）。
            NavigationLink {
                HistoricalWeatherView(latitude: snapshot.location.latitude,
                                      longitude: snapshot.location.longitude)
            } label: {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14))
                    Text("过去 7 日")
                        .font(.system(size: Theme.FontSize.caption, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                .foregroundStyle(Theme.accent)
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
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

                Text(dateTimeText(snapshot.fetchedAt))
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

    /// 指标格（A1 后 3 格 + B1 遥测补全 4 格 = 7 格：风速 / 湿度 / 气压 /
    /// 能见度 / 露点 / 云量 / 阵风）。
    /// LazyVGrid 2 列布局下自动换行，iPhone SE 375pt 无溢出风险。
    private func metricsSection(snapshot: WeatherSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                  spacing: 12) {
            MetricCell(icon: "wind",
                       value: "\(String(format: "%.1f", UnitPreference.displayWindSpeed(ms: snapshot.windSpeed))) \(UnitPreference.windSpeedSymbol()) \(Self.windDirectionText(snapshot.windDirection))",
                       caption: "风速")
            MetricCell(icon: "humidity.fill",
                       value: "\(snapshot.humidity)%",
                       caption: "湿度")
            // A1-1：气压格。hPa 保留 1 位小数；nil → "--"（AC-A1-3，绝不显示 0 冒充）。
            MetricCell(icon: "barometer",
                       value: Self.pressureText(snapshot.pressureMSL),
                       caption: "气压")
            // B1 遥测补全四格。nil → "--"（绝不显示 0 冒充；0% 云量等合法 0 值原样显示）。
            MetricCell(icon: "eye",
                       value: Self.visibilityText(snapshot.visibility),
                       caption: "能见度")
            MetricCell(icon: "thermometer.medium",
                       value: Self.dewPointText(snapshot.dewPoint),
                       caption: "露点")
            MetricCell(icon: "cloud.fill",
                       value: Self.cloudCoverText(snapshot.cloudCover),
                       caption: "云量")
            MetricCell(icon: "wind",
                       value: Self.windGustText(snapshot.windGusts),
                       caption: "阵风")
        }
    }

    // MARK: - ④ 逐小时预报

    private func hourlySection(snapshot: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("未来数小时")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            // D-4：透传选中城市时区，逐小时条时刻按城市时区渲染。
            HourlyStrip(points: snapshot.hourly,
                        timeZone: viewModel.selectedTimeZone)
        }
    }

    // MARK: - ⑤ 月相区

    /// 月相卡片 + 下方日出日落行（A1-4：`日出 HH:mm · 日落 HH:mm`，
    /// nil 段隐藏，AC-A1-12 的降级面）。
    private func moonSection(snapshot: WeatherSnapshot) -> some View {
        let moon = snapshot.moonPhase
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
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

            // A1-4：日出日落行。任一存在才渲染；各自 nil → 对应段隐藏。
            if snapshot.sunrise != nil || snapshot.sunset != nil {
                Text(sunText(snapshot))
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            // A2-4：月出月落行（本地近似，±10min）。任一存在才渲染；
            // 全 nil（极地/无事件日）→ "今日无月出"式文案（AC-A2-14）。
            if let moonText = moonRiseSetText(snapshot) {
                Text(moonText)
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// 「月出 09:58 · 月落 21:30」/「今日无月出」。
    /// 坐标取 snapshot.location（选中城市），时刻格式复用 timeFormatter。
    private func moonRiseSetText(_ snapshot: WeatherSnapshot) -> String? {
        let events = MoonCalculator.moonEvents(for: snapshot.fetchedAt,
                                               latitude: snapshot.location.latitude,
                                               longitude: snapshot.location.longitude)
        var parts: [String] = []
        if let rise = events.rise {
            parts.append("月出 \(timeText(rise))")
        }
        if let set = events.set {
            parts.append("月落 \(timeText(set))")
        }
        if parts.isEmpty {
            return "今日无月出"
        }
        return parts.joined(separator: " · ")
    }

    /// 「日出 05:53 · 日落 18:22」；单侧缺失时只显示存在的一侧（AC-A1-12 降级面）。
    private func sunText(_ snapshot: WeatherSnapshot) -> String {
        var parts: [String] = []
        if let sunrise = snapshot.sunrise {
            parts.append("日出 \(timeText(sunrise))")
        }
        if let sunset = snapshot.sunset {
            parts.append("日落 \(timeText(sunset))")
        }
        return parts.joined(separator: " · ")
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

    // MARK: - 格式化工具（D-4：按选中城市时区渲染，缺省回退设备时区）

    /// 「9月11日 00:31」——按**选中城市时区**渲染（`WeatherTimeFormatter` 内缓存格式器，
    /// 不逐次新建）。
    private func dateTimeText(_ date: Date) -> String {
        WeatherTimeFormatter.string(from: date, format: "M月d日 HH:mm",
                                    timeZone: viewModel.selectedTimeZone)
    }

    /// 「00:31」——按**选中城市时区**渲染（D-4；缺省回退设备时区）。
    private func timeText(_ date: Date) -> String {
        WeatherTimeFormatter.string(from: date, format: "HH:mm",
                                    timeZone: viewModel.selectedTimeZone)
    }

    /// 风向角度 → 8 方位中文。
    private static func windDirectionText(_ degrees: Double) -> String {
        let directions = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        let index = Int((positive / 45).rounded()) % directions.count
        return directions[index]
    }

    /// 气压文案：hPa 保留 1 位小数；nil → "--"（AC-A1-3，绝不显示 0 冒充）。
    private static func pressureText(_ pressure: Double?) -> String {
        guard let pressure else { return "-- hPa" }
        return String(format: "%.1f hPa", pressure)
    }

    /// 能见度文案（Open-Meteo 单位 m）：≥1 km 用 km（1 位小数），否则 m；
    /// nil / 非有限值 → "--"（绝不显示 0 冒充）。
    private static func visibilityText(_ meters: Double?) -> String {
        guard let meters, meters.isFinite else { return "--" }
        if meters >= 1000 { return String(format: "%.1f km", meters / 1000) }
        return String(format: "%.0f m", meters)
    }

    /// 露点文案：整数摄氏度；nil / 非有限值 → "--"。
    private static func dewPointText(_ celsius: Double?) -> String {
        guard let celsius, celsius.isFinite else { return "--" }
        return "\(Int(celsius.rounded()))°"
    }

    /// 云量文案：整数百分比；nil / 非有限值 → "--"（0% 为合法值，原样显示）。
    private static func cloudCoverText(_ percent: Double?) -> String {
        guard let percent, percent.isFinite else { return "--" }
        return "\(Int(percent.rounded()))%"
    }

    /// 阵风文案：随单位偏好换算，1 位小数；nil / 非有限值 → "--"。
    private static func windGustText(_ ms: Double?) -> String {
        guard let ms, ms.isFinite else { return "--" }
        let value = UnitPreference.displayWindSpeed(ms: ms)
        return "\(String(format: "%.1f", value)) \(UnitPreference.windSpeedSymbol())"
    }
}

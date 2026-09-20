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

import CoreSpotlight
import SwiftUI

/// @MainActor：同 CityListView——辅助成员（content 等）需主 actor 隔离
/// 才能合法触碰 @MainActor 的 WeatherViewModel。
@MainActor
struct ContentView: View {

    let viewModel: WeatherViewModel

    /// 外观存储（由 RootView 透传；设置页「外观」行写入，RootView 观察并重绘）。
    let appearance: AppearanceStore

    /// 实时活动管理器（与 VM 同一实例，由 RootView 透传；注入设置页，
    /// 保证设置页启动的活动与 VM 取数后更新的活动是同一个）。
    let activityManager: WeatherActivityManager

    /// 编程式 push（AppRouter 触发跳转用）。
    @State private var navigation: NavigationPath = NavigationPath()

    /// 来源标注协调器（接线点 (b)：拉辅助源 + 逐字段合并 + 写归属）。
    /// 由下方 `.task(id: 城市 id)` 驱动，复用既有刷新节拍，不引入第二刷新生命周期。
    @StateObject private var attributionCoordinator = SourceAttributionCoordinator()

    var body: some View {
        // Handoff / Siri 建议：先把「当前城市」取成**局部值**再交给下面的
        // userActivity 闭包 —— 该闭包是 @escaping 且非主 actor 隔离，若直接
        // 捕获 `self` / `viewModel`（@MainActor）会踩本仓已踩过的
        // 「非隔离上下文求值」陷阱（SettingsView default 参数同款）。
        // `City` 是 Sendable 值类型，捕获它是安全的。
        let activityCity: City? = viewModel.directory.selectedCity

        return NavigationStack(path: $navigation) {
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
            // 系统搜索结果点击（CoreSpotlight）与 Handoff（本 App 活动类型）
            // 两个入口共用 AppRouter 的 NSUserActivity 分发。
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                AppRouter.shared.handle(activity: activity, viewModel: viewModel)
            }
            .onContinueUserActivity(WeatherSpotlight.activityType) { activity in
                AppRouter.shared.handle(activity: activity, viewModel: viewModel)
            }
            // 把当前浏览的城市声明为 NSUserActivity：支持 Handoff 跨设备接续、
            // Siri 建议与系统内搜索建议。
            // 写法说明：只传活动类型 + 一个更新闭包（不传 isEligibleFor* 参数），
            // 三个开关在闭包内设置 —— 该修饰符在不同 SDK 上的重载参数表有差异，
            // 「类型 + 尾随闭包」是各版本都成立的最小形态。
            .userActivity(WeatherSpotlight.activityType) { activity in
                guard let city = activityCity else { return }
                activity.title = WeatherSpotlight.activityTitle(cityName: city.name)
                activity.userInfo = WeatherSpotlight.userInfo(cityID: city.id)
                activity.isEligibleForHandoff = true
                activity.isEligibleForSearch = true
                activity.isEligibleForPrediction = true
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
            // 系统搜索索引：冷启动先写一次；其后城市集合 / 各城市已知温度
            // 任一变化再重写一次（见 `spotlightSignature`）。
            // 索引是**增强能力**：失败只打印，绝不触碰取数状态、绝不弹窗。
            .task {
                await indexCitiesForSpotlight()
            }
            .onChange(of: spotlightSignature) { _, _ in
                Task { await indexCitiesForSpotlight() }
            }
            // 来源标注协调器（接线点 b，ARCH §12.3.2）：随城市切换触发，
            // 复用既有刷新节拍，**不引入第二个刷新生命周期**（硬约束⑦）；
            // App 不打开则不跑（已知限制，非遗漏，硬约束⑤）。
            .task(id: viewModel.directory.selectedCity?.id) {
                guard let city = viewModel.directory.selectedCity else { return }
                let primary: PrimarySolarInput
                if case .loaded(let snapshot) = viewModel.state {
                    primary = PrimarySolarInput(sunrise: snapshot.sunrise, sunset: snapshot.sunset)
                } else {
                    primary = PrimarySolarInput()
                }
                await attributionCoordinator.refresh(for: city, primarySolar: primary, now: Date())
            }
            // 跳转目的地注册（A1-8 搜索 → 城市列表；A3-4 设置 → SettingsView）。
            .navigationDestination(for: CityRoute.self) { route in
                switch route {
                case .cities:
                    CityListView(viewModel: viewModel)
                case .settings:
                    // D-4：透传选中城市时区，设置页「最近更新」随城市时区显示。
                    // D-5：透传新鲜度窗口（复用主循环常量）供「数据状态」判定 正常/陈旧。
                    // 雨伞提醒：透传 VM 持有的调度器（开关读写单一真源，App 本地偏好）。
                    SettingsView(lastUpdated: lastUpdatedDate,
                                 timeZone: viewModel.selectedTimeZone,
                                 freshnessWindow: viewModel.freshnessWindowInterval,
                                 appearance: appearance,
                                 reminderScheduler: viewModel.reminderSchedulerForSettings,
                                 activityManager: activityManager)
                }
            }
        }
    }

    // MARK: - 系统搜索索引（Spotlight）

    /// 索引重写触发签名：城市集合（id 列表）+ 各城市已知温度。
    ///
    /// 为什么用「签名」而不是挂在每个动作上：索引写入需要**城市列表变化后**
    /// 与**取数成功后**两个时机都触发，逐个动作挂点会散落到 VM 的
    /// select / addAndSelect / remove / refresh 四处（且会改到既有数据流）。
    /// 这里只观察「可索引内容的快照签名」，两个时机天然都被覆盖，
    /// VM 侧零改动。
    private var spotlightSignature: String {
        let cityIDs: String = viewModel.directory.cities.map { $0.id }.joined(separator: ",")
        let temperatures: String = viewModel.snapshotsByCity
            .map { "\($0.key)=\(Int($0.value.temperature.rounded()))" }
            .sorted()
            .joined(separator: ",")
        return "\(cityIDs)#\(temperatures)"
    }

    /// 把当前城市列表写入系统搜索索引。**失败只打印**：索引不是数据源，
    /// 写不进去时天气功能必须完好（绝不弹窗、绝不改 `viewModel.state`）。
    private func indexCitiesForSpotlight() async {
        do {
            try await SpotlightIndexer.shared.index(cities: viewModel.directory.cities,
                                                    snapshotByCityID: viewModel.snapshotsByCity)
        } catch {
            print("[ContentView] 系统搜索索引写入失败（不影响天气取数）：\(error)")
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
                // D-5：主屏陈旧提示 —— 共享容器里的主载荷已超过新鲜度窗口时给出**弱**提示，
                // 便于真机判断主屏/小组件显示的是否为过期数据（复用主循环同一 freshnessWindow，
                // 不新增第二个数字）。无载荷 / 未过期 → 不渲染。
                if viewModel.isCachedPayloadStale {
                    Text("缓存数据可能已过期（超过 \(Int(viewModel.freshnessWindowInterval / 60)) 分钟未更新）")
                        .font(.system(size: Theme.FontSize.footnote))
                        .foregroundStyle(Theme.accentSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // 本轮（可诊断性）：定位 / 共享容器两类「应用级」问题不再静默——
                // 文案由 VM 从 Core 的 FaultDomain 单一真源投影而来（视图不拼错误句）。
                // nil = 正常 → 不渲染。
                if let notice = viewModel.locationNotice {
                    noticeRow(notice)
                }
                if let issue = viewModel.storageIssue {
                    noticeRow(issue)
                }
                heroSection(snapshot: snapshot)
                // A2-2：一句话摘要（Hero 温度下一行；nil → 整行隐藏，AC-A2-8）。
                // 摘要与 Hero 同源展示，不参与模块排序（归组 Hero）。
                if let summary = WeatherSummaryEngine.summary(for: snapshot) {
                    Text(summary)
                        .font(.system(size: Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Theme.accentSecondary)
                }
                // 集合预报不确定性区（新增第三链路；固定区块，**不**参与 HomeSection 排序，
                // 以免改动已持久化的区块顺序）。无可用集合 / 不归属当前城市 / 取数失败 →
                // displayedEnsemble 或 evidence 为 nil → 整块不渲染（失败隔离，绝不触碰主 state）。
                // 成员数来自数据（evidence.memberCount），绝不硬编码 30。
                if let forecast = viewModel.displayedEnsemble,
                   let evidence = EnsembleProbabilityEngine.evidence(for: forecast) {
                    EnsembleUncertaintyCard(evidence: evidence,
                                            timeZone: viewModel.selectedTimeZone)
                } else if case .failed(let message) = viewModel.ensembleState {
                    // 本轮：集合链路**取数失败**时，屏上如实说明「该链路失败」，
                    // 而不是整块静默消失（其余链路数据不受影响，失败隔离纪律不变）。
                    noticeRow("集合预报暂不可用：\(message)")
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
            } else if case .failed(let message) = viewModel.airState {
                // 本轮：空气链路**取数失败**时如实说明「该链路失败」，不再静默消失。
                noticeRow("空气质量暂不可用：\(message)")
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
            // 气候档案需要 City 的时区信息；若选中城市缺失，用快照坐标构造 fallback。
            let profileCity = viewModel.directory.selectedCity ?? City(
                name: snapshot.location.name,
                latitude: snapshot.location.latitude,
                longitude: snapshot.location.longitude,
                isCurrentLocation: false
            )
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
            // 个人气候档案入口：用户点击才进入，内部 .task 触发唯一一次宽范围 archive 请求。
            NavigationLink {
                ClimateProfileView(city: profileCity, currentYearHigh: snapshot.dailyHigh)
            } label: {
                HStack {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 14))
                    Text("气候档案")
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
            HStack(spacing: 10) {
                // D-3：设置页此前**只在**下方 navigationDestination 注册处被实例化，
                // UI 无可见入口（只能靠深链 / 桌面快捷方式到达）。此处补一个可见入口：
                // 与刷新按钮并排、同款圆形图标。走与深链/快捷方式**相同**的
                // `CityRoute.settings` 目的地，两条路径渲染同一页面（注册逻辑零改动）。
                NavigationLink(value: CityRoute.settings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(8)
                        .background(Theme.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("设置")

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
                       value: "\(String(format: "%.1f", UnitPreference.displayWindSpeed(ms: snapshot.windSpeed))) \(UnitPreference.windSpeedSymbol()) \(WindDirectionFormatter.text(from: snapshot.windDirection))",
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

            // D-C3：日照与昼夜卡（第二源 overlay 逐字段叠加 + L2 来源标注）。
            // 协调器持有的 overlay 非 nil 字段优先显示；其 provenance 标记 .fallback
            // 时，行尾标注「来自 sunrise-sunset.org」（诚实红线，绝不静默换源）。
            DaylightCard(snapshot: snapshot,
                         overlay: attributionCoordinator.solarOverlay,
                         provenance: attributionCoordinator.solarProvenance,
                         timeZone: viewModel.selectedTimeZone,
                         now: Date())

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
        VStack(alignment: .center, spacing: 2) {
            Text(text)
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(highlighted ? Theme.accentSecondary : Theme.secondaryText)
            // L1 来源归属（ARCH §5）：读 App 本地 SourceAttributionStore 最近一次成功记录，
            // 冷启动 / 缓存态也诚实（不静默换源、不静默换城市）。
            Text(Self.sourceAttributionText(attributionCoordinator.attribution))
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(highlighted ? Theme.accentSecondary : Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
    }

    /// L1 页脚归属文案（诚实红线）。
    private static func sourceAttributionText(_ attribution: SourceAttribution) -> String {
        if attribution.hasFieldFallback {
            return "主源不可用，当前数据来自 sunrise-sunset.org（备源）"
        }
        return "数据来自 Open-Meteo"
    }

    // MARK: - 本轮新增：单行弱提示（链路失败 / 定位 / 共享容器统一外观）

    /// 单行弱提示行（左侧警告图标 + 短句）。
    ///
    /// 本轮的定位 / 共享容器 / 副链路失败提示统一走这里，保证外观一致、且**文案
    /// 仍由 VM 从 Core `FaultDomain` 单一真源投影**（此视图只负责排版，不拼错误句）。
    /// - Parameter text: 已按故障域裁定好的中文短句。
    /// - Returns: 一行弱提示视图。
    private func noticeRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12))
            Text(text)
                .font(.system(size: Theme.FontSize.footnote))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Theme.accentSecondary)
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

    /// 气压文案：随单位偏好换算并输出符号；小数位 hPa=1 / mmHg=0 / inHg=2。
    /// nil → "-- <符号>"（AC-A1-3，绝不显示 0 冒充）。分支逻辑全在 UnitPreference 纯函数内。
    private static func pressureText(_ pressure: Double?) -> String {
        let symbol = UnitPreference.pressureSymbol()
        guard let pressure else { return "-- \(symbol)" }
        let digits = UnitPreference.pressureFractionDigits(for: UnitPreference.pressureUnit())
        let value = UnitPreference.displayPressure(hPa: pressure)
        return String(format: "%.\(digits)f \(symbol)", value)
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

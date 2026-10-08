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

    /// 降水雷达卡状态（第四链路：独立域名 + 独立失败域）。
    ///
    /// 与 `attributionCoordinator` 生命周期**同款**（`.task(id:)` 驱动），
    /// 但持有方式**必须不同**：`RadarCardModel` 用 `@Observable` 而非
    /// `ObservableObject` —— `@Observable` 宏**不合成 `$` 投影**，
    /// 用 `@StateObject` 会直接编译失败（run 37458644694 实证）。
    /// 这一点在本文件下方已有一条关于 `$` 投影的注释，三处口径必须一致。
    ///
    /// 刻意**不进 `WeatherViewModel`**：雷达失败只该写自己的状态，
    /// 塞进主 VM 会污染主 `state`（失败隔离纪律）。
    @State private var radarModel = RadarCardModel()

    /// 台风卡状态（第七链路：台风网独立域名 + 独立失败域）。
    ///
    /// 持有方式与 `radarModel` **同款**（`@State`，因为 `@Observable` 宏
    /// **不合成 `$` 投影**，用 `@StateObject` 会编译失败 —— 见上方radarModel
    /// 注释里记录的 run 37463237543 / 37458644694 实证）。
    @State private var typhoonModel = TyphoonCardModel()

    /// 卫星云图卡状态（风云四号真彩云图：独立域名 + 独立失败域）。
    ///
    /// 持有方式与 `radarModel` / `typhoonModel` **同款**（`@State`，因为
    /// `@Observable` 宏**不合成 `$` 投影**，用 `@StateObject` 会编译失败 ——
    /// 见上方 radarModel 注释里记录的 run 37463237543 / 37458644694 实证）。
    ///
    /// ⚠️ **不引入第二个城市来源**：卫星云图产品**与选中城市无关**
    /// （`SatelliteCardModel.load(now:)` 只吃时间，URL 也只由时戳决定），
    /// 故它的加载触发写在 `SatelliteCard` **卡内**（`.task(id: isEnabled)`），
    /// 本文件不调`satelliteModel.load(...)` —— 与台风卡「不绑 id」的判据同款。
    @State private var satelliteModel = SatelliteCardModel()

    /// 河道流量卡状态（第五源 Open-Meteo Flood：独立子域名 + 独立失败域）。
    ///
    /// 持有方式同上（`@State`，不是 `@StateObject`）。
    /// 坐标**复用既有真源** `viewModel.resolvedCoordinateForRadar`
    /// （与雷达卡同一个属性，"当前位置"项已由 VM 用 `location` 覆盖），
    /// **绝不新建第二套城市来源**。
    @State private var floodModel = FloodCardModel()

    /// 地震卡状态（第十源 USGS 地震：免 Key、零鉴权、独立域名）。
    ///
    /// 持有方式同上（`@State`，不是 `@StateObject`）。
    /// 坐标**复用既有真源** `viewModel.resolvedCoordinateForRadar`
    /// （与雷达 / 洪水卡同一个属性），**绝不新建第二套城市来源** ——
    /// 否则两卡会出现「一个按城市、一个按定位」的分歧。
    @State private var earthquakeModel = EarthquakeCardModel()

    /// 和风天气卡状态（第九源 QWeather：**需 Key**）。
    ///
    /// 持有方式同上（`@State`，不是 `@StateObject`）。
    /// ⚠️ **凭据由 App 侧注入**（Core 不读凭据，`SC-42a` 静态门禁会扫）；
    /// 未配置时 `QWeatherService` 抛 `dataMissing` → 卡片显示
    /// 「未配置 API 凭据」，**绝不伪造数据、绝不静默换源**。
    ///
    /// 🔴 2026-10-10：`QWeatherCardModel` 的默认 service 已从
    ///   `QWeatherService(now:)`（凭据恒为 nil）换成
    ///   `QWeatherCredentialProviding` —— **每次取数前**读当前凭据。
    ///   在此之前全仓没有任何一处构造过带凭据的 `QWeatherCredentials`，
    ///   真机上和风卡必然恒显「未配置 API 凭据」。
    @State private var qWeatherModel = QWeatherCardModel()

    /// 和风凭据存储（与设置页**同一实例**；设置页保存后由下方 `.onChange` 触发重取）。
    ///
    /// ⚠️ 之所以要在主屏持有：`QWeatherCardModel` 在本类型初始化时就构造完成，
    ///   那时用户还没进设置页 → 若无「凭据已变」的信号，
    ///   保存完凭据返回主屏将**看不到任何变化**（`.task(id: 城市 id)`
    ///   只在城市切换时重跑）。
    private let credentialStore = SourceCredentialStore.shared

    /// 台风卡的年份选择器所需的「当前年」。
    ///
    /// ⚠️ 由 `Date()` 在**视图构造期**取值并显式传给卡片（卡片自己不读时钟），
    /// 与本仓「Core/ 不读内部Date()」的纪律一致，且可被单测固定。
    private var currentYearValue: Int {
        Date().currentYearValue
    }

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
// 🔴🔴 降水雷达 / 河道流量 / 地震 / 和风：**合并成唯一一个 `.task`**，
            // 内部用 `async let` **并发**发出。
            //
            // ⚠️⚠️ **为什么必须合并**（本轮实测定位的「超时误报」根因）：
            // 这四条链路原本各自挂一个 `.task(id: 选中城市 id)`。
            // **SwiftUI 对相同 `id` 的多个 `.task` 不并发执行 —— 它们排队串行**。
            // 于是切城市时：雷达（含覆盖探测）→ 河道 → 地震 → 和风 依次跑，
            // 排在后面的链路等十几秒才轮到 → 各自 12 秒的 `loadTimeout`
            // 被打爆 → 用户看到「加载超时」—— **而那不是网络慢，是排队**。
            //
            // 🔴 **这个 bug 的性质**：它把「架构缺陷」伪装成「网络问题」，
            // 靠调大超时只能**掩盖**症状（并让真慢的请求更难被发现）。
            // 正解是消除串行排队。
            //
            // 📌 并发的代价（诚实说明）：同一时刻并发 4 个请求，
            // 对弱网 / 限流场景**更不友好**。故：
            // · 坐标在**并发发起前一次性解析**（不各算一遍）；
            // · 任一链路失败**不影响**其它链路（各自 model 内部独立收敛状态）；
            // · 保留「未配置凭据 → 如实空态」（和风不做静默换源）；
            // · flood / 地震 / 和风**均无坐标可用性门禁**
            //   （实测 flood 内陆有值、地震内陆常为 0 条但那是真实结果）。
            .task(id: viewModel.directory.selectedCity?.id) {
                guard let city = viewModel.directory.selectedCity else { return }
                // ⚠️ 坐标**复用既有真源** `viewModel.resolvedCoordinateForRadar`
                //（"当前位置"项已由 VM 用 location 覆盖）——
                // **绝不新建第二套城市来源**，否则两卡会出现口径分歧。
                let resolved = viewModel.resolvedCoordinateForRadar
                let latitude = resolved.latitude
                let longitude = resolved.longitude

                // 🔴🔴 **可见性必须在进入 `async let` 之前读出**。
                //
                // ⚠️ 踩坑记录（CI run#37757972635 编译错：
                //    `expression is 'async' but is not marked with 'await'`）：
                // `CardVisibilityStore` 是 **类型级 `@MainActor`**，故连它的
                // `static func isHidden` 也是 MainActor 隔离的；
                // 而 `async let` 的闭包是**非隔离** async 上下文，
                // 在里面调MainActor 方法**必须**写 `await`。
                // → 写法A（守卫搬进闭包）：四处都得加 `await`，
                //   且闭包内 `isHidden` 与 `load` 两次跨 actor 往返；
                // → 写法B（本处采用）：**在 MainActor 上先同步读出四个Bool**，
                //   闭包内只做纯值判断 + 一次 `load` 的 `await`。
                //
                // ⚠️ 顺带一个由此产生的**真实收益**：读一次即定格，
                // 四路用的是同一批快照，不会出现「有的卡读到 true、
                // 有的卡读到 false」的撕裂（同一次取数过程内一致）。
                let radarHidden = CardVisibilityStore.isHidden(.radar)
                let floodHidden = CardVisibilityStore.isHidden(.flood)
                let quakeHidden = CardVisibilityStore.isHidden(.earthquake)
                let qWeatherHidden = CardVisibilityStore.isHidden(.qWeather)

                // 四条链路**并发**（不是串行）：`async let` 保证同时发起，
                // 最后一起 await —— 任何一条都不是另三条的**前置阻塞**。
                //
                // 🔴🔴 **被用户关掉的卡：连请求都不发**（不只是不渲染）。
                // 守卫用 `if` 包裹时，闭包在条件为假时**根本不会执行** → 零请求。
                // 这正是「关掉一张卡真的省流量与电量」的实现方式。
                // ⚠️ 坐标系里的 satellite 由卡内 `.task(id: isEnabled)` 自管，
                //   不在这四路里（它默认关闭，用户拨开关才取数）。
                async let radar: Void = {
                    guard !radarHidden else { return }
                    await radarModel.load(cityID: city.id,
                                          latitude: latitude,
                                          longitude: longitude)
                }()
                async let flood: Void = {
                    guard !floodHidden else { return }
                    await floodModel.load(latitude: latitude, longitude: longitude)
                }()
                async let earthquake: Void = {
                    guard !quakeHidden else { return }
                    await earthquakeModel.load(latitude: latitude, longitude: longitude)
                }()
                async let qWeather: Void = {
                    guard !qWeatherHidden else { return }
                    await qWeatherModel.load(latitude: latitude, longitude: longitude)
                }()
                _ = await (radar, flood, earthquake, qWeather)
            }
            // 🔴 凭据变更 → **只重跑和风这一条链路**。
            //
            // ⚠️ 为什么必须显式挂这个触发：上面的 `.task(id: 城市 id)` 只在
            //   **城市切换**时重跑；而凭据是在**设置页**改的，返回主屏时
            //   城市没变 → 那个 task 不会重跑 → 用户会看到
            //   「凭据明明填对了，卡片还是说取不到」。
            //   这是一个**真实的死局**，不是理论风险。
            //
            // ⚠️ 为什么只重跑和风、不重跑全部四条：其余三源与凭据无关，
            //   重跑它们是**白耗流量与电量**。
            //
            // ⚠️ `.onChange` 闭包**不是 async** → 必须包一层 `Task`；
            //   `Task { @MainActor in }` 的显式隔离是必要的：
            //   体内要碰 `@MainActor` 的 `viewModel` 与 `qWeatherModel`。
            //   错误已在 `QWeatherCardModel.load` 内部收敛，任务体不抛。
            .onChange(of: credentialStore.revision) { _, _ in
                Task { @MainActor in
                    let resolved = viewModel.resolvedCoordinateForRadar
                    await qWeatherModel.load(latitude: resolved.latitude,
                                             longitude: resolved.longitude)
                }
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
                                 activityManager: activityManager,
                                 // 透传**同一个**凭据 store 实例：本页写入 → 主屏读取
                                 // 是同一份，否则会退化成「读 A 实例、写 B 实例」。
                                 credentialStore: SourceCredentialStore.shared)
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
                // 降水雷达卡（第四链路 · RainViewer）。
                //
                // **插入位置**：紧跟「短时降水卡」之后、「可排序区块」之前。
                // 理由（三条）：
                //  ① 语义相邻 —— 短时降水是"未来 2 小时模型概率"，雷达是"过去 2 小时
                //     实况回波"，两者是同一时间轴的正反面，放一起用户能连续读；
                //  ② 短时降水卡是**干窗即隐藏**的（AC-B1-8），所以雷达卡不能挂在它
                //     内部（否则无雨时雷达也跟着消失 —— 而"无雨"恰恰是用户最想确认
                //     "确实没下"的时候）。挂在它之后 = 干窗时雷达照常显示；
                //  ③ **不占用 `HomeSection`**（不参与排序/隐藏）—— 与
                //     `EnsembleUncertaintyCard` 同款做法。加新 case 会让老用户的
                //     持久化顺序把它补到尾部，且用户没主动要求过它可排序。
                //
                // 四态（`.radar` / `.forecast` / `.radarUnavailable`）**全部**由
                // `RadarCardModel` 派生并渲染，**绝无空白地图页**。
                // 🔴 可见性由 `CardVisibilityStore` 决定（用户可关掉这张卡 → 顺带不取数）
if !CardVisibilityStore.isHidden(.radar) {
                    RadarMapCard(model: radarModel,
                                 timeZone: viewModel.selectedTimeZone)
                }
                // P2 · AC-B17c：UV 指数卡（当前档位 + 防晒建议 + 当日峰值与峰值时刻）。
                //
                // **插入位置**：与「短时降水卡」「空气质量卡」同级，固定区块，
                // 位于 `ForEach(orderedVisibleSections)` **之前**（理由同 `RadarMapCard`：
                // 不占用 `HomeSection`，避免老用户持久化顺序把它补到尾部）。
                //
                // 隐藏判据全在卡内（当前 UV 与峰值**都**无 → `EmptyView`），
                // 故这里**无条件**挂载——与 `RadarMapCard` 同款（由卡内四态自行决定渲染）。
                // 分级与文案由 Core `UVIndexGuide` 单一真源给出，本文件不拼字符串。
                if !CardVisibilityStore.isHidden(.uv) {
                    UVIndexCard(points: snapshot.hourly,
                                currentUV: snapshot.uvIndex,
                                dailyPeakFallback: snapshot.daily?.first?.uvIndexMax,
                                timeZone: viewModel.selectedTimeZone)
                }
                // 官方预警卡（第六源 · 中国气象局 NMC）。
                //
                // **插入位置**：UV 卡之后、可排序区块 `ForEach(orderedVisibleSections)`
                // **之前**（与 `UVIndexCard` / `RadarMapCard` 同款：不占用
                // `HomeSection`，避免老用户持久化顺序把它补到尾部）。
                //
                // ⚠️ **四态由VM 派生，本文件不做任何判定**：
                //   · `.none`（真的没预警）→ 卡内 `EmptyView`，不留空白；
                //   · `.active` / `.stale` / `.unavailable` → 卡内各有可见输出。
                // ⚠️ **`displayedOfficialWarning` 为 nil 时不渲染** —— nil 表示
                //   **从未取数**（不是"没有预警"）。绝不能把 nil 当成 `.none`：
                //   那会在真正有红色预警时让卡片静默消失（本仓明令禁止的静默兜底）。
                // `now` 由 `TimelineView` 外的 `snapshot.fetchedAt` 提供
                //   （卡片本身不读 `Date()`）。
                if !CardVisibilityStore.isHidden(.warning) {
                    if let warningState = viewModel.displayedOfficialWarning {
                        OfficialWarningCard(state: warningState,
                                           now: snapshot.fetchedAt,
                                           timeZone: viewModel.selectedTimeZone)
                    }
                }
                // 台风卡（第七链路· 中央气象台台风网）。
                //
                // **插入位置**：官方预警卡之后、可排序区块 `ForEach(orderedVisibleSections)`
                // **之前**（与 `RadarMapCard` / `UVIndexCard` / `OfficialWarningCard` 同款：
                // **不占用 `HomeSection`**，避免老用户持久化顺序把它补到尾部）。
                //
                // ⚠️ **无条件挂载**：四态（`.idle` / `.none` / `.active` / `.unavailable`）
                // 由 `TyphoonCardModel` 派生，卡内**各自**渲染可见内容 ——
                // 尤其「当前无活跃台风」是**如实显示的文字**，绝不留空白页。
                //
                // ⚠️ **加载只做一次**：用 `.task`（**不绑任何 id**）——
                // 台风是**全App 唯一**的一条链路，既不随城市切换而变，
                // 也不随快照刷新而变；绑`id:` 会让它在切城时无谓重取。
                // 卡内年份选择器是**另一条**入口（用户主动切年份才重取）。
                if !CardVisibilityStore.isHidden(.typhoon) {
                    TyphoonCard(model: typhoonModel,
                                currentYear: currentYearValue)
                        .task {
                            // 仅在**尚未取过数**时拉一次（`.idle` 判据）。
                            guard case .idle = typhoonModel.state else { return }
                            await typhoonModel.load(year: nil)
                        }
                }
                // 卫星云图卡（风云四号真彩 · 独立失败域）。
                //
                // **插入位置**：台风卡之后、可排序区块 `ForEach(orderedVisibleSections)`
                // **之前**（与 `RadarMapCard` / `UVIndexCard` / `OfficialWarningCard` /
                // `TyphoonCard` 同款：**不占用 `HomeSection`**，避免老用户持久化顺序
                // 把它补到尾部）。
                //
                // ⚠️ **无条件挂载**：四态（未开启 / 加载中 / 已加载 / 取不到）由
                // `SatelliteCardModel` 派生，卡内**各自**渲染可见内容 ——
                // 尤其「取不到」的**原因文案分类**（未找到时次 / 不是图片 /
                // 该时次为空白）是三类不同的事实，**绝不含糊成一句"加载失败"**。
                //
                // ⚠️ **加载触发在卡内**（`.task(id: isEnabled)`）：云图**默认关闭**
                // （整幅亚洲区域位图会完全遮住地图底图，理由见
                // `SatelliteCardModel.isEnabled`），故未开启时**一个请求都不发**；
                // 用户拨开开关才取数。本文件**不调** `satelliteModel.load(...)`。
                if !CardVisibilityStore.isHidden(.satellite) {
                    SatelliteCard(model: satelliteModel,
                                  timeZone: viewModel.selectedTimeZone)
                }
                // 河道流量卡（第五源 Open-Meteo Flood · 独立失败域）。
                //
                // **插入位置**：卫星云图卡之后、可排序区块**之前**（同上款：
                // **不占用 `HomeSection`**）。
                //
                // ⚠️ **无条件挂载**：四态（`.idle` / `.noData` / `.available` /
                // `.unavailable`）由 `FloodCardModel` 派生，卡内各自渲染可见内容。
                // 特别地 **`.noData`（这一带没有河道数据）与 `.unavailable`（取不到）
                // 是两套不同的文案** —— 混用会把"正常地理事实"说成"产品坏了"。
                //
                // ⚠️ **无坐标判据**：实测内陆城市同样有值（北京、拉萨），
                // 故不按"是否沿海"过滤（那会错杀真实数据）。
                if !CardVisibilityStore.isHidden(.flood) {
                    FloodCard(model: floodModel,
                              timeZone: viewModel.selectedTimeZone)
                }
                // 地震卡（第十源 USGS地震 · 免 Key· 独立失败域）。
                //
                // **插入位置**：河道流量卡之后、可排序区块**之前**（同上款：
                // **不占用 `HomeSection`**）。
                //
                // ⚠️ **无条件挂载**：四态（`.idle` / `.none` / `.available` /
                // `.unavailable`）由 `EarthquakeCardModel` 派生，卡内各自渲染。
                // 🔴 **`.none` 与 `.unavailable` 必须是两套文案** ——
                // 实测**北京 300km/30天/M2.5+ 就是 0 条**（已用 `/count` 交叉验证，
                // 确认真的没地震），也就是说**绝大多数用户看到的就是「没有」**。
                // 若把「没有」与「取不到」混用，用户会以为 App 坏了。
                if !CardVisibilityStore.isHidden(.earthquake) {
                    EarthquakeCard(model: earthquakeModel,
                                  timeZone: viewModel.selectedTimeZone)
                }
                // 和风天气卡（第九源 QWeather · 需 Key · 独立失败域）。
                //
                // **插入位置**：地震卡之后、可排序区块**之前**（同款：
                // **不占用 `HomeSection`**）。
                //
                // ⚠️ **无条件挂载**：四态由 `QWeatherCardModel` 派生。
                // 🔴 **未配置凭据时显示「未配置 API 凭据」**（如实空态）。
                //
                // 🔴🔴 **`attributions` 必须渲染**（和风官方明文：
                // 「必须与当前数据共同显示」）—— 这是**许可条件，非可选**。
                // 漏渲染 = 违反许可条件，比少一个 UI 元素严重得多。
                //
                // 🔴 2026-10-11（区域化双源）：本卡现在**同时**显示两个源
                // （国内和风为主 / 海外 Open-Meteo 为主，可点按切换），故传入：
                // · `openMeteoDaily: snapshot.daily` —— Open-Meteo 侧逐日**复用既有
                //   主源快照**，**不发新请求**（否则重复取数 + 重复计配额）；
                // · `country/latitude/longitude` —— 供 `RegionalSourcePolicy`
                //   裁定「默认谁当主源」（`country` 缺失时才退到坐标粗判）。
                if !CardVisibilityStore.isHidden(.qWeather) {
                    QWeatherCard(model: qWeatherModel,
                                 timeZone: viewModel.selectedTimeZone,
                                 openMeteoDaily: snapshot.daily,
                                 country: viewModel.directory.selectedCity?.country,
                                 latitude: snapshot.location.latitude,
                                 longitude: snapshot.location.longitude)
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
                // P2 · AC-C5b：六污染物 24h **分项**趋势（只做加法，不重做既有 AQI 卡）。
                // 挂在同一 case 内紧跟既有卡之后 → 二者天然相邻、同进同退
                // （`airQuality == nil` 时本卡随之不渲染，不做第二个失败判据）。
                // 卡内再守一层：六项**全**缺测 → 整卡 `EmptyView`（绝不渲染六个 "--"）。
                AirQualityPollutantCard(points: airQuality.hourly ?? [])
            } else if case .failed(let message) = viewModel.airState {
                // 本轮：空气链路**取数失败**时如实说明「该链路失败」，不再静默消失。
                noticeRow("空气质量暂不可用：\(message)")
            }
            // 海洋第四源 · 潮汐卡（`sea_level_height_msl` 15 分钟序列）。
            // ⚠️ **内陆城市整卡不渲染**：`displayedTide` 对内陆坐标返回 nil
            //   （判据不通过 → 不联网；即便放行，实测服务端也回**全 null**
            //   → `isEffectivelyEmpty` → nil），
            //   故此处**不是**渲染"暂无潮汐"——那会让内陆用户以为数据缺失。
            // ⚠️ 窗内有效点不足时`TideCard` 自身返回 `EmptyView`（不留空槽）。
            // ⚠️ 曲线窗**从"现在"起算**（注入 Date()）：`TideForecast.pointsInNext24Hours`
            //   按注入时刻截取，Core 层禁内部取时钟，故 now 由视图注入。
            if let tide = viewModel.displayedTide {
                TideCard(points: tide.pointsInNext24Hours(now: Date()),
                         timeZone: viewModel.selectedTimeZone)
            } else if case .failed(let message) = viewModel.marineState {
                // 海洋链路**真失败**时如实说明（与空气链路同款可见性纪律）；
                // 内陆城市走不到这里 —— 那是"正常无此数据"，不是故障，不提示。
                noticeRow("潮汐暂不可用：\(message)")
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
    /// 能见度 / 露点 / 云量 / 阵风）+ D-C2 逐时风力图。
    /// LazyVGrid 2 列布局下自动换行，iPhone SE 375pt 无溢出风险。
    ///
    /// **D-C2 挂载点说明**：风力图挂在 `.metrics` 区块内（而不是新开一个
    /// `HomeSection` case）—— ① 指标格里已经有「风速 / 阵风」两格，逐时趋势紧贴其上
    /// 是同量相邻；② 新开 case 会让**老用户**的持久化顺序把新块"补齐到尾部"
    /// （`HomeSectionOrder.current()` 的既有行为），屏幕上它就跑到最底下；
    /// ③ 挂进既有区块即自动随该区块参与排序/隐藏（`HomeSection` 机制未被绕过）。
    /// 数据全 nil → 卡内整块 `EmptyView`，不留空槽。
    private func metricsSection(snapshot: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            metricsGrid(snapshot: snapshot)
            // 🔴 兜底源提示行（2026-10-11）：紧跟指标格 —— 备源补的正是
            //   这几个量。主源有值时它整段不渲染（判据在 `FallbackSourceNote`）。
            fallbackSourceNote(snapshot: snapshot)
            // D-C2：逐时平均风速（实心）/ 阵风（空心）同尺并列（AC-C6）。
            // ⚠️ 逐时风向未请求（`OpenMeteoEndpoint.hourlyFields` 无 `wind_direction_10m`）
            // → 不画风向，卡内如实说明（AC-C4 属数据面缺口，见卡片文件头）。
            HourlyWindChart(points: snapshot.hourly,
                            timeZone: viewModel.selectedTimeZone)
        }
    }

    /// 指标格本体（7 格）。
    private func metricsGrid(snapshot: WeatherSnapshot) -> some View {
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

    /// 🔴 兜底源数值提示行（2026-10-11 新增）。
    ///
    /// ⚠️ **只在主源缺该字段时**才有内容（判据全在 `FallbackSourceNote.lines`，
    ///   视图只渲染不判定）—— 主源有值时它**整段不渲染**（不留空槽）。
    /// ⚠️ **绝不覆盖主源值**：那是 `FieldFallbackResolver.merge` 的语义，
    ///   本轮**一个字都没改**那个文件。
    /// ⚠️ 挂在指标格**之后**：那正是备源补的几个量（温度/气压/湿度/云量/风）
    ///   在主屏的位置，用户不用多滚一屏就能看到「这个值来自备源」。
    @ViewBuilder
    private func fallbackSourceNote(snapshot: WeatherSnapshot) -> some View {
        FallbackSourceNote(snapshot: snapshot,
                           overlay: attributionCoordinator.solarOverlay,
                           provenance: attributionCoordinator.solarProvenance)
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
            // D-C1：逐时降水图（柱＝mm / 折线＝%），按 ARCH §2 挂在**逐小时条下方**。
            // 数据不足（hourly 空 / 降水量全 nil / 有效点不足）→ 卡内整块 `EmptyView`，
            // 不留空槽（AC-C3）；挂在 `.hourly` 区块内 = 自动随该区块参与排序/隐藏。
            // 数据来自既有 `snapshot.hourly`，**无新增网络请求**。
            HourlyPrecipitationChart(points: snapshot.hourly,
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

            // ⚠️ AC-A1-12（月相区日出日落）的渲染落点**已由下方的 `DaylightCard` 承接**。
            //
            // 这里原本有一行 `Text(sunText(snapshot))`，与紧随其后的 `DaylightCard`
            // **显示完全相同的两个值**（相邻两行重复），是用户直接可见的界面缺陷。
            // 去重时保留 `DaylightCard` 的版本，理由有两条：
            //   1. 它带 L2 来源标注（`provenanceLabel(for:)`），降级时会如实写出来源，
            //      而原来那行是无标注的裸文本 —— 保留更诚实的那一版；
            //   2. 它额外承载昼长与「距日落」倒计时，信息量严格更大。
            // **日出/日落仍在渲染，只是搬到了下方卡内** —— 不是被砍掉。
            // `DaylightCard.body` 无条件渲染，`riseSetRow` 在 `effectiveSunrise` /
            // `effectiveSunset` 非 nil 时分别输出「日出 HH:mm」「日落 HH:mm」，
            // 故删除本行**不存在"日出日落彻底不显示"的空窗**。
            // 对应的 `sunText(...)` 函数已随本行删除（避免留下死代码）。

            // D-C3：日照与昼夜卡（第二源 overlay 逐字段叠加 + L2 来源标注）。
            // 协调器持有的 overlay 非 nil 字段优先显示；其 provenance 标记 .fallback
            // 时，行尾标注「来自 sunrise-sunset.org」（诚实红线，绝不静默换源）。
            // 时钟：卡内 `TimelineView(.everyMinute)` 自己驱动「距日落」倒计时，
            // 故这里**不再注入 now**（两套时钟会漂移；卡片文件头有说明）。
            DaylightCard(snapshot: snapshot,
                         overlay: attributionCoordinator.solarOverlay,
                         provenance: attributionCoordinator.solarProvenance,
                         timeZone: viewModel.selectedTimeZone)

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

    /// ⚠️ 原来的 `sunText(_:)`（「日出 05:53 · 日落 18:22」，AC-A1-12 降级面）
    /// **已随重复行一并删除**：它唯一的调用点与下面的 `DaylightCard` 显示同一对值（相邻重复）。
    ///
    /// AC-A1-12 的渲染现由 `DaylightCard.riseSetRow` 承接 —— 那里同样按
    /// `effectiveSunrise` / `effectiveSunset` 的单侧存在性分别输出，即**保留了
    /// 「单侧缺失时只显示存在的一侧」这条降级语义**，并额外带上 L2 来源标注。
    /// 若将来要把 AC-A1-12 挪回月相区，**请先删掉 `DaylightCard` 的 `riseSetRow`**，
    /// 不要两处并存（那正是本次去重要修掉的缺陷）。

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

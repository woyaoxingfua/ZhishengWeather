//
//  WeatherViewModel.swift
//  ZhishengWeather（主 App target）
//
//  @Observable + @MainActor 视图模型。
//  F-B 多城市改造（ARCH-FB §3.2）：
//    - 持有 CityDirectory（城市目录纯逻辑）+ 双共享 key 持久化（D-1）；
//    - refresh 定位流：定位成功才 upsert"当前位置"（AC-B3），取数坐标 = 选中城市；
//    - 新增 select / addAndSelect / remove / moveDisplayedCities / toggleFavorite 动作；
//    - **R-3（本轮最高回归风险）**：snapshot.location 的覆盖源 = 选中城市
//      （`selectedCity.locationInfo`），而非定位结果 —— 遗漏会导致切换城市后
//      主屏与小组件 header 仍显示"当前位置/北京"。
//
//  红线（全部保留，未动）：State 枚举结构、`@MainActor @Observable`、
//  `isRefreshing` 门闩、冷启动缓存预填、失败降级分支（refresh 路径）、
//  refreshIfNeeded 新鲜度窗口。
//

import Foundation
import Observation
import WidgetKit

@MainActor
@Observable
final class WeatherViewModel {

    /// 界面状态。
    enum State: Equatable {
        /// 首次加载（无任何内容）。
        case loading
        /// 已加载（展示 `snapshot`）。
        case loaded(WeatherSnapshot)
        /// 失败（可携带上次缓存用于降级展示）。
        case failed(cached: WeatherSnapshot?, message: String)
    }

    /// 当前状态。
    private(set) var state: State = .loading
    /// 最近一次定位结果（UI 不直接消费；header 用 snapshot.location）。
    private(set) var location: LocationInfo = .beijing
    /// 定位相关提示（本轮：权限被拒不再静默）。
    ///
    /// 由 `FaultDomain.classify(locationOutcome:)` 纯裁定：只有「权限被拒 / 受限」
    /// 才有文案；未作答 / 单次失败保持既有静默回落（不打扰用户）。nil = 无提示。
    private(set) var locationNotice: String? = nil
    /// App Group 共享容器故障提示（本轮：写失败 / 容器不可用不再静默）。
    ///
    /// nil = 正常；非 nil = 需要让用户知道的共享容器问题（小组件可能读不到数据）。
    private(set) var storageIssue: String? = nil

    /// 城市目录（F-B）：数组顺序即展示顺序（D-2）。
    private(set) var directory: CityDirectory
    /// 会话内"最近一次已知温度"缓存（AC-B16，裁定：不跨启动持久化，冷启动 `--`）。
    private(set) var snapshotsByCity: [String: WeatherSnapshot] = [:]

    /// 当前选中城市的时区（D-4 时间渲染用，方案 b）。
    ///
    /// `LocationInfo` 无时区字段，故时区从**选中的 `City`** 派生（不改模型 / 不改载荷）。
    /// 缺省 / 非法 IANA 标识 → 设备时区（`WeatherTimeFormatter` 内裁定，保持既有行为）。
    var selectedTimeZone: TimeZone {
        WeatherTimeFormatter.timeZone(for: directory.selectedCity)
    }

    /// 新鲜度窗口（秒）的只读访问器：供诊断面板 / 陈旧提示复用**同一个**常量，
    /// 避免在别处再写一个「15 分钟」字面量（诊断面板属于本轮新增消费方）。
    var freshnessWindowInterval: TimeInterval { freshnessWindow }

    /// 共享容器里的主载荷是否已超过新鲜度窗口（主屏「陈旧提示」用）。
    ///
    /// 数据源 = `SharedWeatherPayload.updatedAt`（Widget 读的同一份载荷），
    /// 阈值复用主循环的 `freshnessWindow`，不新增第二个数字。
    /// 无载荷（从未成功落盘）→ false（此时由 .loading / .failed 分支表达，不叠加提示）。
    ///
    /// 本轮（可诊断性）：**陈旧判定式**下沉到 Core 纯函数 `StalePolicy.isStale`
    /// （严格大于阈值才算陈旧，可边界单测），本处只负责取「数据时刻 + 阈值」两个入参，
    /// 不再各自写一遍算术，避免「一处改了别处没改」的同源漂移。
    /// 注意：nil（无载荷）在本处仍按既有语义返回 false（不叠加提示），
    /// 故先做 nil 短路，不直接吃 `StalePolicy` 的「nil → 陈旧」约定。
    var isCachedPayloadStale: Bool {
        guard let updated = store.updatedAt else { return false }
        return StalePolicy.isStale(lastUpdated: updated, now: Date(), threshold: freshnessWindow)
    }

    private let service: WeatherProviding
    private let store: AppGroupStore
    private let locationProvider: LocationProvider
    /// 空气质量第二链路（A2-1，独立域名，与天气链路物理分离）。
    private let airService: AirQualityProviding
    /// 空气质量（A2-1）：**仅存于 VM，不进 WeatherSnapshot/共享容器**
    /// （ARCH-A2 §1.1①，Widget 载荷契约零改动）。nil = 未加载/取数失败/无关数据。
    private(set) var airQuality: AirQuality? = nil
    /// 空气链路的**独立状态**（本轮：失败必须在屏上表现为「该链路失败」，
    /// 而不是整卡静默消失）。失败只写本属性，**绝不触碰 `state`**。
    private(set) var airState: SourceState = .idle

    /// 集合预报第三链路服务（独立域名 `ensemble-api.open-meteo.com`，独立慢节奏）。
    private let ensembleService: EnsembleProviding
    /// 集合预报（本特性）：**仅存于 VM，不进 WeatherSnapshot / 共享容器**。
    /// nil = 未加载 / 取数失败 / 不归属当前选中城市。
    private(set) var ensemble: EnsembleForecast? = nil
    /// 集合链路的**独立状态**（同 `airState`：失败可见，但不触碰主 `state`）。
    private(set) var ensembleState: SourceState = .idle
    /// `ensemble` 归属的城市 id（跨城串号守卫，见 `displayedEnsemble`）。
    private var ensembleCityID: String? = nil
    /// 最近一次集合取数**尝试**时刻（配额守卫：本调用等价 4.0 次额度）。
    private var lastEnsembleFetchAt: Date? = nil

    /// 雨伞提醒调度器（本地通知副链路；副作用出口，绝不触碰 `state`）。
    /// 权限懒请求 / 开关读写 / 固定 id 替换全部内聚在调度器里（见其文件头）。
    private let reminderScheduler: UmbrellaReminderScheduler

    /// 实时活动管理器（取数成功后推送最新数据进正在进行的活动；仅更新不启动）。
    /// 副作用出口，与主链路隔离：更新失败由管理器自身诊断留痕，绝不触碰 `state`、
    /// 绝不反噬天气刷新（与雨伞提醒副链路同款纪律）。
    private let activityManager: WeatherActivityManager

    /// 仅当集合结果归属当前选中城市时返回（防切城后旧城集合串号，P1-A 纪律平移）。
    var displayedEnsemble: EnsembleForecast? {
        guard let id = directory.selectedID, id == ensembleCityID else { return nil }
        return ensemble
    }

    /// 雨伞提醒调度器（设置页「提醒」区块的开关读写入口；只读透传，
    /// 写路径全部收敛在调度器自身）。
    var reminderSchedulerForSettings: UmbrellaReminderScheduler {
        reminderScheduler
    }

    /// 防止并发重复刷新。
    private var isRefreshing = false

    /// 回到前台时的「新鲜度」阈值：15 分钟内不重复取数。
    private let freshnessWindow: TimeInterval = 15 * 60

    /// 集合取数节奏：3 小时。**独立于 15 分钟主循环**（配额纪律，PRD §4.1）：
    /// 本调用等价 **4.0 次**额度 → 3h ⇒ ≤8 次/日 ⇒ 32 次等价调用/日 ≈ 日预算
    /// （10,000）的 0.32%。集合指引变化缓慢，无需更密；更密只会白烧额度。
    private let ensembleCadence: TimeInterval = 3 * 60 * 60

    /// ⚠️ default 参数在调用方的非隔离上下文求值（Swift 并发模型），
    /// `LocationProvider()` 是 @MainActor 隔离 init，直接作 default 会挂编译
    /// （CI 实测）。故 default 用 nil，真正创建移到 init 体内——init 体内
    /// 已处于 @MainActor 隔离，合法。
    init(service: WeatherProviding = WeatherService(),
         store: AppGroupStore = AppGroupStore(),
         locationProvider: LocationProvider? = nil,
         airService: AirQualityProviding = AirQualityService(),
         ensembleService: EnsembleProviding = EnsembleService(),
         reminderScheduler: UmbrellaReminderScheduler? = nil,
         activityManager: WeatherActivityManager? = nil) {
        self.service = service
        self.store = store
        self.locationProvider = locationProvider ?? LocationProvider()
        self.airService = airService
        self.ensembleService = ensembleService
        // ⚠️ 同 LocationProvider：@MainActor 隔离 init 不能作 default 参数
        //（default 在调用方非隔离上下文求值），故 default 用 nil、体内创建。
        self.reminderScheduler = reminderScheduler ?? UmbrellaReminderScheduler()
        // ⚠️ 同款陷阱：WeatherActivityManager 也是 @MainActor 隔离 init，
        // default 用 nil、体内创建（否则 default 参数在非隔离上下文求值会挂编译）。
        self.activityManager = activityManager ?? WeatherActivityManager()

        // ── F-B：载入城市目录（AC-B1 / F-B-1）────────────────────────────
        // 三分支裁定（F-B 核验后补）：
        //   .loaded  → 直接采用（selectedID 坏值由 CityDirectory 回退第一项，不落盘覆盖）；
        //   .missing → 键缺失（首次启动）→ 初始目录 [北京] + 选中北京，并**立即落盘**
        //              （写入的是合法初始结构，不违反"不清数据"纪律）；
        //   .corrupt → 坏 JSON → 仅内存回退初始目录，**绝不落盘覆盖**（字节保全 /
        //              防误伤 / 纪律一致），打日志便于排查，留待用户显式操作时修正。
        switch store.loadCities() {
        case .loaded(let storedCities):
            directory = CityDirectory(cities: storedCities, selectedID: store.selectedCityID)
        case .missing:
            directory = CityDirectory.initial()
            do {
                try store.saveCities(directory.cities)
            } catch {
                print("[WeatherViewModel] 初始化城市列表写入失败：\(error)")
            }
        case .corrupt:
            print("[WeatherViewModel] 城市列表 JSON 损坏：本次启动使用内存初始目录，不覆盖既有数据")
            directory = CityDirectory.initial()
        }

        // 冷启动预填缓存，避免无网络时白屏（原有逻辑保留）。
        if let cached = store.loadSnapshot() {
            self.state = .loaded(cached)
            self.location = cached.location
            // 会话缓存冷启动为空（AC-B16：不做跨启动持久化），此处不填充。
        }
    }

    // MARK: - 定位刷新流（refresh）

    /// 冷启动 / 下拉刷新：定位 → upsert 目录 → 按选中城市取数 → 落盘 → 刷新 Widget。
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // 仅在「确实没有任何可展示内容」时才切回 loading。
        // state 为 .loaded 或缓存非空时都必须保留当前内容，否则下拉刷新会先闪一下
        // loading（缓存瞬间消失），违反 PRD P0-10 AC④「失败时仍展示最后一次缓存」。
        let hasDisplayableContent: Bool
        switch state {
        case .loaded:
            hasDisplayableContent = true
        case .failed(let cached, _):
            hasDisplayableContent = cached != nil
        case .loading:
            hasDisplayableContent = false
        }
        if !hasDisplayableContent {
            state = .loading
        }

        let resolved = await locationProvider.requestLocation()
        location = resolved
        // 本轮：定位权限被拒 / 受限不再静默（未作答 / 单次失败仍静默回落默认城市，不打扰用户）。
        // 裁定与文案都在 Core 纯逻辑里（可单测），这里只做投影。
        locationNotice = FaultDomain.classify(locationOutcome: locationProvider.lastOutcome)
            .map { FaultDomain.message(for: $0) }

        // ── F-B（AC-B3）：定位真实成功才 upsert"当前位置"；被拒/失败/超时 → no-op ──
        if !resolved.isFallback {
            if directory.upsertCurrentLocation(resolved) {
                saveCitiesQuietly()
            }
        }

        // upsert 可能改变选中项 id（"当前位置"项坐标更新 → 规范化 id 变化），重新取。
        guard let selectedCity = directory.selectedCity else { return }

        // ── F-B（§3.2③）：取数坐标。
        // 选中城市为"当前位置"且定位成功 → 用 resolved 新坐标（upsert 已同步，
        // 此处显式取 resolved 作双保险）；否则用选中城市存储坐标。
        let useResolved = selectedCity.isCurrentLocation && !resolved.isFallback
        let latitude = useResolved ? resolved.latitude : selectedCity.latitude
        let longitude = useResolved ? resolved.longitude : selectedCity.longitude

        do {
            // 诊断：主天气链路上报 —— 尝试在请求前打点，成败在各自分支打点（纯追加，
            // 不改失败隔离；记录器绝不向本方法抛错）。
            await LinkHealthRecorder.shared.recordAttempt(.forecast, at: Date())
            var snapshot = try await service.fetch(latitude: latitude,
                                                   longitude: longitude)
            await LinkHealthRecorder.shared.recordSuccess(.forecast, at: Date())
            // ── R-3（最高回归风险，改造即必踩）────────────────────────────
            // 快照 location 的覆盖源 = **选中城市**（selectedCity.locationInfo），
            // 不是定位结果。若沿用旧行为"用定位结果覆盖"，用户切到"杭州"后
            // 主屏与小组件 header 仍会显示"当前位置/北京"（静态检查抓不到，
            // 要等真机 F-B-7/F-B-11 才暴露）。
            snapshot.location = selectedCity.locationInfo

            // AC-B16：会话内记忆该城市最近一次已知温度。
            snapshotsByCity[selectedCity.id] = snapshot

            // D-4（Widget 时区补齐）：把选中城市的 IANA 时区随快照写入共享载荷，
            // Widget 才能在异地城市按当地时区渲染时刻（缺省 → Widget 回退设备时区）。
            let payload = SharedWeatherPayload(snapshot: snapshot, updatedAt: Date(),
                                               timeZoneIdentifier: selectedCity.timeZoneIdentifier)
            do {
                try store.save(payload)
                // 本轮：写入恢复正常 → 清除既有共享容器故障提示（自愈，避免陈旧告警挂屏）。
                storageIssue = nil

                // 落盘成功但共享容器不可用 = 小组件永远读不到，且系统不会报任何错，
                // 是自签名/重签名环节最常见的坑，这里主动提示。
                if !AppGroupStore.isSharedContainerAvailable {
                    print("[WeatherViewModel] 警告：App Group 容器不可用（\(AppGroup.identifier)），"
                          + "小组件将读不到数据。请确认两个 target 的 entitlements 均含该 group，"
                          + "且重签名时保留了 com.apple.security.application-groups。")
                }
            } catch {
                // 写失败不再静默（本轮）：投影到 `storageIssue`，主屏据此提示「小组件可能读不到数据」。
                // 失败域裁定与文案仍在 Core 纯逻辑（FaultDomain），这里只做投影。
                storageIssue = Self.message(for: WeatherError.appGroup(error.localizedDescription))
            }

            WidgetCenter.shared.reloadAllTimelines()
            // A2-1：天气链路成功后顺序触发空气第二链路（独立 Task，失败绝不反噬天气）。
            // 触发时机在落盘之后（ARCH-A2 §2.3），便于失败隔离测试断言顺序性。
            let airCity = selectedCity
            Task { await loadAir(for: airCity) }
            // 集合第三链路（独立 Task；内部自带 3h 慢节奏守卫，不随 15min 主循环刷新）。
            let ensembleCity = selectedCity
            Task { await loadEnsemble(for: ensembleCity) }
            // 雨伞提醒副链路（本地通知；纯副作用，绝不触碰 state，失败静默降级）。
            scheduleUmbrellaReminderIfNeeded(for: snapshot, city: selectedCity)
            // 过期丢弃（P1-A）：刷新期间用户若切换城市，当前结果已非选中城市，丢弃不应用，
            // 避免把旧城市的快照覆盖到新选中的界面。
            guard directory.selectedID == selectedCity.id else { return }
            state = .loaded(snapshot)
            // 取数成功 → 把真实数据推进正在进行的实时活动（仅更新，不启动）。
            // 放在 selectedID 校验之后：只推送「选中城市」的最新数据，不把过期旧城结果塞进活动。
            await pushLiveActivity(for: snapshot, city: selectedCity)
        } catch {
            await LinkHealthRecorder.shared.recordFailure(.forecast, at: Date(),
                                                          message: Self.message(for: error))
            let cached = store.loadSnapshot()
            state = .failed(cached: cached, message: Self.message(for: error))
        }
    }

    // MARK: - 城市动作（F-B 新增）

    /// 切换选中城市（AC-B12 / F-B-7）。
    /// 立即落盘选中 id，**保留当前展示内容（禁全屏 loading）**；
    /// 取数失败 → 回退选中 id（防 header 与数据错位）并置 .failed。
    /// - Parameter id: 目标城市 id。
    func select(_ id: String) async {
        // 注意：不在此处用 `isRefreshing` 门闩拦截（P1-A 修复）——即便有刷新在途也应
        // 立即响应用户切城，过期结果由 fetchAndApply / refresh 内的 selectedID 校验丢弃。
        guard let previousID = directory.selectedID else { return }
        guard directory.select(id), let city = directory.selectedCity else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        saveSelectedCityIDQuietly()
        await fetchAndApply(for: city, fallbackID: previousID)
    }

    /// 添加搜索结果并选中（AC-B5 / AC-B8）。去重判定由 CityDirectory.add 裁定。
    /// - Parameter city: 搜索结果构造的城市。
    func addAndSelect(_ city: City) async {
        // 同上（P1-A 修复）：不拦截用户操作，过期结果由 fetchAndApply 内 selectedID 校验丢弃。
        let previousID = directory.selectedID

        let added = directory.add(city)
        if added {
            saveCitiesQuietly()
        }
        guard let selected = directory.selectedCity else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        saveSelectedCityIDQuietly()
        await fetchAndApply(for: selected, fallbackID: previousID)
    }

    /// 删除城市（AC-B10 / AC-B11 / F-B-9）。
    /// "至少保留一个城市"由 CityDirectory.remove 裁定（no-op 返回 false）；
    /// 删除当前选中 → 目录自动回退选中 → 立即对回退后的选中城市取数 + 落盘 + reload。
    /// - Parameter id: 要删除的城市 id。
    func remove(_ id: String) async {
        // 同上（P1-A 修复）：不拦截用户操作，过期结果由 fetchAndApply 内 selectedID 校验丢弃。
        let wasSelected = (directory.selectedID == id)
        guard directory.remove(id) else { return }

        saveCitiesQuietly()
        guard wasSelected, let newSelected = directory.selectedCity else { return }

        saveSelectedCityIDQuietly()

        isRefreshing = true
        defer { isRefreshing = false }
        await fetchAndApply(for: newSelected, fallbackID: nil)
    }

    /// 展示序拖动（A2-6 星标置顶后的唯一入口，D-1 连带修复）。
    /// `.onMove` 给出的 offsets/toOffset 是 **`displayCities` 展示序**，
    /// 由 `CityDirectory.moveDisplay` 按 id 解析后落到存储序，避免置顶后错位。
    /// - Parameters:
    ///   - fromOffsets: 展示序中被拖动行原索引集。
    ///   - toOffset: 展示序中的目标偏移。
    func moveDisplayedCities(fromOffsets: IndexSet, toOffset: Int) {
        directory.moveDisplay(fromOffsets: fromOffsets, toOffset: toOffset)
        saveCitiesQuietly()
    }

    /// 切换城市收藏星标（A2-6）：显式用户操作 → 立即落盘（PRD §3.4）。
    /// 展示置顶由 `CityDirectory.displayCities` 读取时派生，此处不改写数组顺序。
    /// - Parameter id: 目标城市 id。
    func toggleFavorite(_ id: String) {
        directory.toggleFavorite(id)
        saveCitiesQuietly()
    }

    // MARK: - 回到前台节流

    /// 回到前台：仅当缓存过期时才刷新（原有逻辑不变）。
    func refreshIfNeeded() async {
        if let updated = store.updatedAt, Date().timeIntervalSince(updated) < freshnessWindow {
            return
        }
        await refresh()
    }

    /// 消费 Widget 强刷标志位并强制刷新（A1-7）。
    /// 由 `ZhishengWeatherApp` 在 scenePhase `.active` 时优先调用：有标志位则绕过
    /// `refreshIfNeeded` 的新鲜度节流强制刷新；无则交由 `refreshIfNeeded` 节流。
    /// - Returns: 是否确有强刷请求并已（强制）触发；false 表示无待办，调用方转 `refreshIfNeeded`。
    func consumePendingForceRefreshAndRefresh() async -> Bool {
        guard store.consumePendingForceRefresh() else { return false }
        // 显式用户意图（点 Widget 刷新按钮）：即便有刷新在途也强制重新取数。
        // 先清门闩，确保 refresh() 不被自身的 isRefreshing 去重拦截；
        // 过期结果由 refresh() 内的 selectedID 校验丢弃。
        isRefreshing = false
        await refresh()
        return true
    }

    // MARK: - Private

    /// 取数 → 覆盖 location（R-3：覆盖源 = 城市信息）→ 会话缓存 → 落盘 → reload → 更新 state。
    /// select / addAndSelect / remove 共用；失败时回退 `fallbackID` 并置 .failed（不切 loading）。
    /// - Parameters:
    ///   - city: 取数目标城市。
    ///   - fallbackID: 失败时回退到的选中城市 id；nil 表示不回退（如删除路径的自动回退已完成）。
    private func fetchAndApply(for city: City, fallbackID: String?) async {
        do {
            // 诊断：主天气链路上报（与 refresh 路径同一链路；纯追加）。
            await LinkHealthRecorder.shared.recordAttempt(.forecast, at: Date())
            var snapshot = try await service.fetch(latitude: city.latitude,
                                                   longitude: city.longitude)
            await LinkHealthRecorder.shared.recordSuccess(.forecast, at: Date())
            // R-3：覆盖源 = 选中城市（与 refresh 路径同一覆盖点，ARCH-FB §3.2）。
            snapshot.location = city.locationInfo

            snapshotsByCity[city.id] = snapshot

            // D-4（Widget 时区补齐）：写入目标城市的 IANA 时区（同 refresh 路径）。
            let payload = SharedWeatherPayload(snapshot: snapshot, updatedAt: Date(),
                                               timeZoneIdentifier: city.timeZoneIdentifier)
            do {
                try store.save(payload)
                // 本轮：写入恢复正常 → 自愈清除共享容器故障提示（同 refresh 路径）。
                storageIssue = nil
                if !AppGroupStore.isSharedContainerAvailable {
                    print("[WeatherViewModel] 警告：App Group 容器不可用（\(AppGroup.identifier)），"
                          + "小组件将读不到数据。")
                }
            } catch {
                // 写失败不再静默（本轮）：同 refresh 路径，投影到 `storageIssue`。
                storageIssue = Self.message(for: WeatherError.appGroup(error.localizedDescription))
            }

            WidgetCenter.shared.reloadAllTimelines()
            // A2-1：天气链路成功后触发空气第二链路（独立 Task，失败绝不反噬天气）。
            let airCity = city
            Task { await loadAir(for: airCity) }
            // 集合第三链路（独立 Task；3h 慢节奏守卫 + 跨城守卫见 loadEnsemble）。
            let ensembleCity = city
            Task { await loadEnsemble(for: ensembleCity) }
            // 过期丢弃（P1-A）：取数期间用户若又切换城市，仅当选中项仍是本次目标城市才应用，
            // 否则丢弃，交由对应的 select/addAndSelect/remove 取数流程修正界面。
            guard directory.selectedID == city.id else { return }
            state = .loaded(snapshot)
            // 取数成功 → 把真实数据推进正在进行的实时活动（仅更新，不启动）。
            await pushLiveActivity(for: snapshot, city: city)
        } catch {
            await LinkHealthRecorder.shared.recordFailure(.forecast, at: Date(),
                                                          message: Self.message(for: error))
            // 切换失败：回退选中 id，避免 header 与数据错位（F-B-7）。
            if let fallbackID {
                directory.select(fallbackID)
                saveSelectedCityIDQuietly()
            }
            let cached = store.loadSnapshot()
            state = .failed(cached: cached, message: Self.message(for: error))
        }
    }

    // MARK: - 雨伞提醒副链路（本地通知）

    /// 依快照的短时降水序列调度（或替换）雨伞提醒。
    ///
    /// 失败隔离纪律（ARCH §3.2 同款）：本地通知是**副产物**，本方法**绝不**读写
    /// `state` / `airQuality` / `ensemble`，内部全部静默降级（调度器吞错仅打印）。
    /// 触发时机与 loadAir / loadEnsemble 一致：主链路成功落盘之后。
    ///
    /// 时刻口径：文案起始时刻按**选中城市时区**渲染（D-4，复用 WeatherTimeFormatter
    /// 的格式器缓存，不新建第二套格式器）——与短时降水卡的口径完全一致。
    ///
    /// - Parameters:
    ///   - snapshot: 主链路刚取回的快照（含 minutely15，可 nil）。
    ///   - city: 本次取数目标城市（文案时区来源）。
    private func scheduleUmbrellaReminderIfNeeded(for snapshot: WeatherSnapshot,
                                                  city: City) {
        let timeZone = WeatherTimeFormatter.timeZone(for: city)
        let now = Date()
        let decision = UmbrellaReminderEngine.decide(
            minutely15: snapshot.minutely15,
            now: now,
            timeText: { date in
                WeatherTimeFormatter.string(from: date, format: "HH:mm", timeZone: timeZone)
            }
        )
        let onsetDelay = decision.onset.map { $0.timeIntervalSince(now) } ?? 0
        // 独立 Task：调度含权限申请（可能挂起），绝不阻塞主刷新流收尾。
        Task { await reminderScheduler.scheduleIfDecided(decision, onsetDelay: onsetDelay) }
    }

    // MARK: - 实时活动副链路（取数成功 → 更新）

    /// 取数成功后把最新真实数据推进入正在进行的实时活动（**仅更新，不启动**）。
    ///
    /// 失败隔离纪律（与伞提醒/空气/集合同款）：实时活动是**副产物**，本方法**绝不**
    /// 读写 `state` / `airQuality` / `ensemble`，内部全部静默降级（失败由管理器诊断留痕）。
    /// 只在用户已开启实时活动时才尝试（`isEnabled` 短路）：开关关着自然没有活动，
    /// 不必每轮取数都去撞一次「尚未启动」的短句，也避免无谓的诊断留痕。
    ///
    /// - Parameters:
    ///   - snapshot: 主链路刚取回的快照（温度/天气码/更新时刻来源）。
    ///   - city: 本次取数目标城市（城市名 + 时区来源）。
    private func pushLiveActivity(for snapshot: WeatherSnapshot, city: City) async {
        guard activityManager.isEnabled else { return }
        await activityManager.update(from: snapshot, city: city)
    }

    // MARK: - 空气质量第二链路（A2-1）

    /// 拉取空气质量（独立 Task，R5 隔离）：
    /// 失败只置 `airQuality = nil`，**绝不触碰 `state`**（天气主屏不受空气 API 影响）；
    /// 成功赋值前以 `selectedID` 守门，丢弃滞后于切城的过期结果（P1-A 纪律平移）。
    private func loadAir(for city: City) async {
        // 诊断：空气链路上报（纯追加；成功在 fetch 后、失败在本 catch 内打点）。
        await LinkHealthRecorder.shared.recordAttempt(.airQuality, at: Date())
        do {
            let aq = try await airService.fetch(latitude: city.latitude,
                                                longitude: city.longitude)
            await LinkHealthRecorder.shared.recordSuccess(.airQuality, at: Date())
            guard directory.selectedID == city.id else { return }
            airQuality = aq
            airState = .loaded
        } catch {
            // 空气失败 = 无空气卡，天气 state 不动（AC-A2-4 / R-A2-1）。
            await LinkHealthRecorder.shared.recordFailure(.airQuality, at: Date(),
                                                          message: error.localizedDescription)
            airQuality = nil
            // 本轮：失败在屏上**可见**（该链路自己的降级位），文案取自 FaultDomain 单一真源。
            airState = .failed(Self.message(for: error))
        }
    }

    // MARK: - 集合预报第三链路（Ensemble，额度 4.0 倍）

    /// 拉取集合预报（独立 Task，R5 隔离 + 配额守卫）：
    ///  - **慢节奏**：同一城市 3 小时内不重复取数（`ensembleCadence`）——本调用等价
    ///    4.0 次额度，**绝不随 15 分钟主循环刷新**（PRD §4.1）；
    ///  - **跨城守卫**：切城时立即清空旧值并改写归属 id，避免旧城集合串号到新城界面；
    ///  - **失败隔离**：失败只置 `ensemble = nil`，**绝不触碰 `state`**；
    ///  - **过期丢弃**：成功赋值前以 `selectedID` 守门（P1-A 纪律平移）。
    /// - Parameter city: 取数目标城市。
    private func loadEnsemble(for city: City) async {
        // 慢节奏守卫：同城且未到 3h，直接跳过（不发起 4.0 倍请求）。
        if ensembleCityID == city.id,
           let last = lastEnsembleFetchAt,
           Date().timeIntervalSince(last) < ensembleCadence {
            return
        }
        // 切城：清空旧城集合，避免旧数据在新城界面短暂展示（归属 id 立即改写）。
        if ensembleCityID != city.id {
            ensemble = nil
        }
        // 成败均先打点，避免失败时在 15min 主循环里高频重试 4.0 倍端点（配额纪律）。
        ensembleCityID = city.id
        lastEnsembleFetchAt = Date()

        // 诊断：集合链路上报（慢节奏守卫**跳过**时不计为一次尝试）。
        await LinkHealthRecorder.shared.recordAttempt(.ensemble, at: Date())
        do {
            let forecast = try await ensembleService.fetch(latitude: city.latitude,
                                                           longitude: city.longitude)
            await LinkHealthRecorder.shared.recordSuccess(.ensemble, at: Date())
            guard directory.selectedID == city.id else { return }
            ensemble = forecast
            ensembleState = .loaded
        } catch {
            // 集合失败 = 无集合区块，天气 state 不动（隔离纪律）。
            await LinkHealthRecorder.shared.recordFailure(.ensemble, at: Date(),
                                                          message: error.localizedDescription)
            ensemble = nil
            // 本轮：失败在屏上**可见**（该链路自己的降级位），文案取自 FaultDomain 单一真源。
            ensembleState = .failed(Self.message(for: error))
        }
    }

    /// 静默写城市列表（失败仅打印，不打断流程）。
    private func saveCitiesQuietly() {
        do {
            try store.saveCities(directory.cities)
        } catch {
            print("[WeatherViewModel] 写入城市列表失败：\(error)")
        }
    }

    /// 静默写选中城市 id（失败仅打印，不打断流程）。
    private func saveSelectedCityIDQuietly() {
        guard let id = directory.selectedID else { return }
        do {
            try store.saveSelectedCityID(id)
        } catch {
            print("[WeatherViewModel] 写入选中城市失败：\(error)")
        }
    }

    /// 错误 → 面向用户的文案（**唯一入口**）。
    ///
    /// 本轮（可诊断性修复）把分类与文案全部下沉到 Core 纯逻辑
    /// （`FaultDomain.classify` + `FaultDomain.message(for:)`）：视图 / VM 不再
    /// 各自拼错误句子，避免再次出现「一处改了、别处没改」的同源漂移。
    /// - Parameter error: 任意取数错误。
    /// - Returns: 按故障域给出的可操作中文短句。
    private static func message(for error: Error) -> String {
        FaultDomain.message(for: FaultDomain.classify(error))
    }
}

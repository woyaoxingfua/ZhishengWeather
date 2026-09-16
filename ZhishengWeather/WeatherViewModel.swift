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

    private let service: WeatherProviding
    private let store: AppGroupStore
    private let locationProvider: LocationProvider
    /// 空气质量第二链路（A2-1，独立域名，与天气链路物理分离）。
    private let airService: AirQualityProviding
    /// 空气质量（A2-1）：**仅存于 VM，不进 WeatherSnapshot/共享容器**
    /// （ARCH-A2 §1.1①，Widget 载荷契约零改动）。nil = 未加载/取数失败/无关数据。
    private(set) var airQuality: AirQuality? = nil

    /// 防止并发重复刷新。
    private var isRefreshing = false

    /// 回到前台时的「新鲜度」阈值：15 分钟内不重复取数。
    private let freshnessWindow: TimeInterval = 15 * 60

    /// ⚠️ default 参数在调用方的非隔离上下文求值（Swift 并发模型），
    /// `LocationProvider()` 是 @MainActor 隔离 init，直接作 default 会挂编译
    /// （CI 实测）。故 default 用 nil，真正创建移到 init 体内——init 体内
    /// 已处于 @MainActor 隔离，合法。
    init(service: WeatherProviding = WeatherService(),
         store: AppGroupStore = AppGroupStore(),
         locationProvider: LocationProvider? = nil,
         airService: AirQualityProviding = AirQualityService()) {
        self.service = service
        self.store = store
        self.locationProvider = locationProvider ?? LocationProvider()
        self.airService = airService

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
            var snapshot = try await service.fetch(latitude: latitude,
                                                   longitude: longitude)
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

                // 落盘成功但共享容器不可用 = 小组件永远读不到，且系统不会报任何错，
                // 是自签名/重签名环节最常见的坑，这里主动提示。
                if !AppGroupStore.isSharedContainerAvailable {
                    print("[WeatherViewModel] 警告：App Group 容器不可用（\(AppGroup.identifier)），"
                          + "小组件将读不到数据。请确认两个 target 的 entitlements 均含该 group，"
                          + "且重签名时保留了 com.apple.security.application-groups。")
                }
            } catch {
                print("[WeatherViewModel] 写入共享容器失败：\(error)")
            }

            WidgetCenter.shared.reloadAllTimelines()
            // A2-1：天气链路成功后顺序触发空气第二链路（独立 Task，失败绝不反噬天气）。
            // 触发时机在落盘之后（ARCH-A2 §2.3），便于失败隔离测试断言顺序性。
            let airCity = selectedCity
            Task { await loadAir(for: airCity) }
            // 过期丢弃（P1-A）：刷新期间用户若切换城市，当前结果已非选中城市，丢弃不应用，
            // 避免把旧城市的快照覆盖到新选中的界面。
            guard directory.selectedID == selectedCity.id else { return }
            state = .loaded(snapshot)
        } catch {
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
            var snapshot = try await service.fetch(latitude: city.latitude,
                                                   longitude: city.longitude)
            // R-3：覆盖源 = 选中城市（与 refresh 路径同一覆盖点，ARCH-FB §3.2）。
            snapshot.location = city.locationInfo

            snapshotsByCity[city.id] = snapshot

            // D-4（Widget 时区补齐）：写入目标城市的 IANA 时区（同 refresh 路径）。
            let payload = SharedWeatherPayload(snapshot: snapshot, updatedAt: Date(),
                                               timeZoneIdentifier: city.timeZoneIdentifier)
            do {
                try store.save(payload)
                if !AppGroupStore.isSharedContainerAvailable {
                    print("[WeatherViewModel] 警告：App Group 容器不可用（\(AppGroup.identifier)），"
                          + "小组件将读不到数据。")
                }
            } catch {
                print("[WeatherViewModel] 写入共享容器失败：\(error)")
            }

            WidgetCenter.shared.reloadAllTimelines()
            // A2-1：天气链路成功后触发空气第二链路（独立 Task，失败绝不反噬天气）。
            let airCity = city
            Task { await loadAir(for: airCity) }
            // 过期丢弃（P1-A）：取数期间用户若又切换城市，仅当选中项仍是本次目标城市才应用，
            // 否则丢弃，交由对应的 select/addAndSelect/remove 取数流程修正界面。
            guard directory.selectedID == city.id else { return }
            state = .loaded(snapshot)
        } catch {
            // 切换失败：回退选中 id，避免 header 与数据错位（F-B-7）。
            if let fallbackID {
                directory.select(fallbackID)
                saveSelectedCityIDQuietly()
            }
            let cached = store.loadSnapshot()
            state = .failed(cached: cached, message: "暂无法获取\(city.name)天气，请稍后重试")
        }
    }

    // MARK: - 空气质量第二链路（A2-1）

    /// 拉取空气质量（独立 Task，R5 隔离）：
    /// 失败只置 `airQuality = nil`，**绝不触碰 `state`**（天气主屏不受空气 API 影响）；
    /// 成功赋值前以 `selectedID` 守门，丢弃滞后于切城的过期结果（P1-A 纪律平移）。
    private func loadAir(for city: City) async {
        do {
            let aq = try await airService.fetch(latitude: city.latitude,
                                                longitude: city.longitude)
            guard directory.selectedID == city.id else { return }
            airQuality = aq
        } catch {
            // 空气失败 = 无空气卡（整卡不渲染），天气 state 不动（AC-A2-4 / R-A2-1）。
            airQuality = nil
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

    private static func message(for error: Error) -> String {
        guard let weatherError = error as? WeatherError else {
            return error.localizedDescription
        }
        switch weatherError {
        case .badURL:
            return "地址无效"
        case .badStatus(let code):
            return "服务器返回 \(code)"
        case .network(let detail):
            return "网络错误：\(detail)"
        case .decoding(let detail):
            return "数据解析失败：\(detail)"
        }
    }
}

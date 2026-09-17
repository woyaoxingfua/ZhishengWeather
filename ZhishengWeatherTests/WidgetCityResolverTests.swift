//
//  WidgetCityResolverTests.swift
//  ZhishengWeatherTests
//
//  F-C 桌面小组件城市选择：**新解析入口**（`resolveOutcome`，城市阶梯 C0/C1/C2）
//  + 原始容器读取 + 快照归属判定（AC-C9 主体）。
//
//  覆盖：
//    ① `.followApp` + 容器有选中 → 选中城市（AC-C2 数据侧）；
//    ② `.followApp` + 容器空 → `.needsConfiguration`（**幽灵北京回归防线**：
//       旧实现经 CityDirectory.loadReadOnly → initial() 静默解析出北京）；
//    ③ `.followApp` + 容器空但内置目录非空 → 仍 `.needsConfiguration`
//       （C1 只经「用户主动选择」生效，绝不替用户默认）；
//    ④ `.fixed` 命中容器 → 该城市（AC-C3 数据侧）；
//    ⑤ `.fixed` 命中内置目录（容器空）→ 内置城市（C1 新增能力）；
//    ⑥ `.fixed` 未命中两条目录 → **按「信息是否可得」分层**（AC-C5，B 组回归修复）：
//       ⑥a 容器**可用** → 回退「跟随 App」语义（**不**坐标回填、**不**再显示已删除城市）；
//       ⑥b 容器**可用**且 App 侧也无有效选中 → `.needsConfiguration`；
//       ⑥c 容器**不可用** → 才允许坐标回填（ARCH §10-3 旧实例兼容）；
//    ⑦ `.fixed` 怪值 + 容器不可用 → `.needsConfiguration`
//       （隔离「非法坐标不可回填」，不冒充、不静默改城市）；
//    ⑧ 同 id 同时存在于容器与内置 → **容器优先**（全量元数据；
//       该顺序与 ⑥ 的分层**正交**，不受 AC-C5 影响）；
//    ⑨ 容器的 selectedID 已失效 → `.needsConfiguration`；
//    ⑩ `mode(forEntityID:)`：两个哨兵 id → `.followApp` / `.currentLocation`，
//       城市 id → `.fixed`；
//    ⑪ 三个 id 互斥（R-C5 / R-C6）：两个哨兵互异、且都与 `City.makeID` 产物格式互斥；
//    ⑭ 「当前位置」+ 拿到坐标 → 用该坐标建城（id 走 `City.makeID`，名「当前位置」）；
//    ⑮⑯ 「当前位置」的两个空态**必须分开**（Apple：未授权 ≠ 已授权但拿不到）；
//    ⑰ 定位路径**绝不**回落北京（容器里放着北京做诱饵）；
//    ⑱⑲ 定位开销：非「当前位置」**零调用**；「当前位置」**恰好一次**。
//    ⑫ `WidgetCityCatalog.rawCities`：loaded 原样 / missing → [] / corrupt → []
//       且**不覆盖写**（字节保全）；
//    ⑬ 快照归属判定：makeID(北京坐标) == 北京.id（true）≠ 杭州.id（false）。
//
//  全部 guard case + XCTFail，无 try! / 强解包（SC-31 纪律）。
//

import XCTest
@testable import ZhishengWeather

final class WidgetCityResolverTests: XCTestCase {

    private var suiteName: String = ""
    private var defaults: UserDefaults?
    private var store: AppGroupStore?

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 临时 suite：避免依赖真实 App Group 权限（与 AppGroupStoreTests 同模式）。
        let name = "zs.test.resolver.\(UUID().uuidString)"
        suiteName = name
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name),
                                     "无法创建临时 UserDefaults suite")
        self.defaults = defaults
        self.store = AppGroupStore(defaults: defaults)
    }

    override func tearDown() {
        if let defaults, !suiteName.isEmpty {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        store = nil
        suiteName = ""
        super.tearDown()
    }

    // MARK: - Helpers

    /// 杭州城市（北京用 City.beijingDefault）。
    private static let hangzhou = City(name: "杭州", latitude: 30.25, longitude: 120.17,
                                       isCurrentLocation: false)

    /// 苏州（**不在**内置 34 城目录里；用于 ⑥ 的分层用例 ——
    /// 容器**可用**时它是「已被用户删除的城市」，容器**不可用**时它才被坐标回填）。
    private static let suzhou = City(name: "苏州", latitude: 31.30, longitude: 120.58,
                                     isCurrentLocation: false)

    /// 容器快照字面量（容器可用 → 城市阶梯一律纯本地）。
    private func container(cities: [City],
                           selectedID: String?,
                           available: Bool = true) -> WidgetContainerSnapshot {
        WidgetContainerSnapshot(cities: cities, selectedID: selectedID,
                                containerAvailable: available)
    }

    /// 实例配置值。
    private func selection(_ id: String, name: String = "配置城市") -> WidgetCitySelection {
        WidgetCitySelection(id: id, name: name, subtitle: nil)
    }

    /// 取点闭包：**不会被调用**的占位（用在所有「配置不是当前位置」的用例里）。
    ///
    /// 值只是为了满足签名 —— 那些用例的配置是「跟随 App」/ 固定城市，Core **不会**
    /// `await` 它（该不变量有专门用例看着，见
    /// `testNonCurrentLocationConfigNeverTouchesLocationProvider`）。
    private static let noFix: () async -> WidgetLocationOutcome = { .notAuthorized }

    /// 计数取点闭包：断言「取点被调用了几次」（定位开销的配额纪律）。
    /// - Parameter result: 被调用时返回的结果。
    /// - Returns: 闭包 + 读取调用次数的函数。
    private func countingFix(result: WidgetLocationOutcome)
        -> (fix: () async -> WidgetLocationOutcome, calls: () async -> Int) {
        let counter = FixCounter(result: result)
        return ({ await counter.next() }, { await counter.calls() })
    }

    // MARK: - ① followApp + 容器有选中（AC-C2 数据侧）

    func testFollowAppResolvesSelectedCityFromRawContainer() async {
        let outcome = await WidgetCityResolver.resolveOutcome(
            selection: selection(WidgetCityResolver.followAppID),
            container: container(cities: [City.beijingDefault, Self.hangzhou],
                                 selectedID: Self.hangzhou.id),
            builtIn: WidgetBuiltInCities.cities,
            location: Self.noFix)

        XCTAssertEqual(outcome.city?.id, Self.hangzhou.id,
                       "followApp 必须解析为容器中**用户主动选中**的城市（AC-C2）")
    }

    // MARK: - ② followApp + 容器空 → 无城市（幽灵北京回归防线）

    func testFollowAppWithEmptyContainerYieldsNoCityInsteadOfGhostBeijing() async {
        let outcome = await WidgetCityResolver.resolveOutcome(
            selection: selection(WidgetCityResolver.followAppID),
            container: container(cities: [], selectedID: nil),
            builtIn: WidgetBuiltInCities.cities,
            location: Self.noFix)

        XCTAssertEqual(outcome, .needsConfiguration,
                       "容器真空必须解析为无城市（诚实空态）——"
                       + "旧实现经 initial() 静默给出北京，即幽灵北京缺陷")
        XCTAssertNil(outcome.city, "绝不注入 CityDirectory.initial() 的北京")
    }

    // MARK: - ③ followApp + 容器空但内置目录非空 → 仍无城市

    func testFollowAppIgnoresBuiltInCatalogWithoutUserSelection() async {
        XCTAssertFalse(WidgetBuiltInCities.cities.isEmpty, "前置：内置目录非空")

        let outcome = await WidgetCityResolver.resolveOutcome(
            selection: selection(WidgetCityResolver.followAppID),
            container: container(cities: [], selectedID: nil),
            builtIn: WidgetBuiltInCities.cities,
            location: Self.noFix)

        XCTAssertEqual(outcome, .needsConfiguration,
                       "C1 只经『用户主动选择』生效，绝不替用户默认城市（决策 #4）")
    }

    // MARK: - ④ fixed 命中容器（AC-C3 数据侧）

    func testFixedHitResolvesContainerCity() async {
        let outcome = await WidgetCityResolver.resolveOutcome(
            selection: selection(Self.hangzhou.id),
            container: container(cities: [City.beijingDefault, Self.hangzhou],
                                 selectedID: City.beijingDefault.id),
            builtIn: WidgetBuiltInCities.cities,
            location: Self.noFix)

        XCTAssertEqual(outcome.city?.id, Self.hangzhou.id,
                       "fixed 命中容器项必须返回该城市，而非容器选中城市（AC-C3）")
    }

    // MARK: - ⑤ fixed 命中内置目录（容器空，C1 新增能力）

    func testFixedHitResolvesBuiltInCityWhenContainerIsEmpty() async {
        let builtInBeijing = City.beijingDefault
        let outcome = await WidgetCityResolver.resolveOutcome(
            selection: selection(builtInBeijing.id),
            container: container(cities: [], selectedID: nil),
            builtIn: WidgetBuiltInCities.cities,
            location: Self.noFix)

        XCTAssertEqual(outcome.city?.id, builtInBeijing.id,
                       "容器空时命中内置目录 → 解析成功（这就是 C1 让用户主动选到城市的路径）")
    }

    // MARK: - ⑥ fixed 未命中两条目录 → 按「信息是否可得」分层（AC-C5）

    /// ⑥a 容器**可用** = 信息可得 → 该城市确已被删除 → 回退「跟随 App」语义。
    ///
    /// 这条是 B 组的**回归防线**：初版在两条目录都不命中时无条件坐标回填，
    /// 于是「用户在主 App 删掉的城市」会继续被小组件显示、并继续为它取数 ——
    /// 违反 PRD **AC-C5**（配置城市被删除 → 回退跟随 App、不显示已删除城市名）。
    func testFixedMissWithContainerAvailableFallsBackToFollowApp() async {
        let containerHangzhou = City(name: "杭州", latitude: 30.25, longitude: 120.17,
                                     isCurrentLocation: false)
        let outcome = await WidgetCityResolver.resolveOutcome(
            selection: selection(Self.suzhou.id, name: "苏州"),
            container: container(cities: [City.beijingDefault, containerHangzhou],
                                 selectedID: containerHangzhou.id),
            builtIn: WidgetBuiltInCities.cities,
            location: Self.noFix)

        XCTAssertEqual(outcome.city?.id, containerHangzhou.id,
                       "容器可用 + id 已不在任何目录 → AC-C5：回退「跟随 App」解析出 App 选中城市")
        XCTAssertNotEqual(outcome.city?.id, Self.suzhou.id,
                          "绝不坐标回填一个「已被用户删除的城市」（否则会继续显示并继续取数）")
        XCTAssertNotEqual(outcome.city?.name, "苏州",
                          "更不得沿用配置里那个已删除城市的展示名")
    }

    /// ⑥b 容器**可用**但 App 侧也没有有效选中 → 如实空态（不回填、不默认）。
    func testFixedMissWithContainerAvailableAndNoAppSelectionYieldsNoCity() async {
        let outcome = await WidgetCityResolver.resolveOutcome(
            selection: selection(Self.suzhou.id, name: "苏州"),
            container: container(cities: [City.beijingDefault], selectedID: nil),
            builtIn: WidgetBuiltInCities.cities,
            location: Self.noFix)

        XCTAssertEqual(outcome, .needsConfiguration,
                       "容器可用 + 城市已删除 + App 无有效选中 → 请配置城市（不冒充、不回填）")
    }

    /// ⑥c 容器**不可用** = 信息不可得 → 才允许坐标回填（保住实例可用）。
    ///
    /// 未签名侧载下容器恒不可用，此时**无法得知**该城市是否被删除，
    /// 故不能按 AC-C5 判定为「已删除」；回填是 `.fixed` 实例唯一的存活路径。
    func testFixedMissWithContainerUnavailableBackfillsCanonicalCoordinate() async {
        let outcome = await WidgetCityResolver.resolveOutcome(
            selection: selection(Self.suzhou.id, name: "苏州"),
            container: container(cities: [], selectedID: nil, available: false),
            builtIn: WidgetBuiltInCities.cities,
            location: Self.noFix)

        XCTAssertEqual(outcome.city?.id, Self.suzhou.id,
                       "容器不可用 → 允许坐标回填（旧实例 / 从未联网时选中的城市）")
        XCTAssertEqual(outcome.city?.name, "苏州",
                       "坐标回填用**配置携带的展示名**重建城市，不伪造名称")
    }

    // MARK: - ⑦ fixed 怪值（容器不可用）→ 无城市

    func testFixedWeirdValueWithContainerUnavailableYieldsNoCity() async {
        // 容器置为**不可用**：这是唯一会尝试坐标回填的分支，
        // 故只有在此分支下才真正检验「非法坐标不可回填」这条防线
        //（容器可用时该 id 会先按 AC-C5 回退「跟随 App」，测不到回填防线）。
        let outcome = await WidgetCityResolver.resolveOutcome(
            selection: selection("no,such,id", name: "怪值"),
            container: container(cities: [], selectedID: nil, available: false),
            builtIn: WidgetBuiltInCities.cities,
            location: Self.noFix)

        XCTAssertEqual(outcome, .needsConfiguration,
                       "既非目录项、又非合法坐标 → 如实空态，**不**静默改城市")
    }

    // MARK: - ⑧ 同 id 双目录 → 容器优先

    func testContainerCityWinsOverBuiltInForSameID() async {
        // 同坐标同 id，但容器项带用户自己的元数据（名称不同）。
        // ⚠️ 这条锁的是**命中时的目录优先序**（容器 → 内置），与 ⑥ 的
        //    「未命中时按容器可用性分层」**正交**，不是 B 组那个 AC-C5 缺陷。
        //    保留容器优先的三条理由：① 容器项是用户自己在 App 里加的、元数据更全；
        //    ② 全仓唯一的另一处同源调用（配置界面回显）也是容器优先，改序会让
        //    回显与解析给出不同名字；③ 内置/容器同 id 必然同坐标同中文名，
        //    故该顺序对 AC-C5（删除判定）没有影响。
        let containerHangzhou = City(name: "杭州市区", latitude: 30.25, longitude: 120.17,
                                     isCurrentLocation: false)

        let outcome = await WidgetCityResolver.resolveOutcome(
            selection: selection(containerHangzhou.id),
            container: container(cities: [containerHangzhou], selectedID: nil),
            builtIn: WidgetBuiltInCities.cities,
            location: Self.noFix)

        XCTAssertEqual(outcome.city?.name, "杭州市区",
                       "同 id 时必须返回容器项（全量元数据），内置项只作兜底")
    }

    // MARK: - ⑨ 容器 selectedID 失效 → 无城市

    func testFollowAppWithDanglingSelectedIDYieldsNoCity() async {
        let outcome = await WidgetCityResolver.resolveOutcome(
            selection: selection(WidgetCityResolver.followAppID),
            container: container(cities: [City.beijingDefault], selectedID: "no,such,id"),
            builtIn: WidgetBuiltInCities.cities,
            location: Self.noFix)

        XCTAssertEqual(outcome, .needsConfiguration,
                       "容器有城市但选中 id 失效 → 无城市（绝不回退到第一个城市冒充用户选择）")
    }

    // MARK: - ⑩ mode(forEntityID:)：哨兵判定集中

    func testModeForEntityIDMapsSentinelAndCityID() {
        XCTAssertEqual(WidgetCityResolver.mode(forEntityID: WidgetCityResolver.followAppID),
                       .followApp,
                       "哨兵 id 必须判为 .followApp")
        XCTAssertEqual(WidgetCityResolver.mode(forEntityID: City.beijingDefault.id),
                       .fixed(cityID: City.beijingDefault.id),
                       "城市 id 必须判为 .fixed（携带该 id）")
        XCTAssertEqual(WidgetCityResolver.mode(forEntityID: WidgetCityResolver.currentLocationID),
                       .currentLocation,
                       "「当前位置」哨兵必须判为 .currentLocation（绝不落进 .fixed："
                       + "否则会被当成坐标 id 去目录里查，永远落空）")
    }

    /// 哨兵 id 与 City.makeID 产物格式互斥（R-C5 / R-C6，格式面防撞）。
    ///
    /// ⚠️ PRD §4.7.2 实施注意：**新哨兵必须纳入同一套断言** —— 漏了会出现
    /// 「坐标城市被误判为哨兵 / 哨兵被误判为坐标」的**双向静默错**（编译通过、CI 全绿）。
    func testSentinelIDsAreMutuallyExclusive() {
        // makeID 产物形如 "39.90,116.41"：数字+逗号+小数点，不可能等于两个哨兵 id。
        let coordinateID = City.makeID(latitude: 39.90, longitude: 116.41)
        XCTAssertNotEqual(coordinateID, WidgetCityResolver.followAppID)
        XCTAssertNotEqual(coordinateID, WidgetCityResolver.currentLocationID)

        XCTAssertFalse(WidgetCityResolver.followAppID.contains(","))
        XCTAssertFalse(WidgetCityResolver.currentLocationID.contains(","),
                       "哨兵 id 一律不含逗号 → 与坐标 id 格式互斥（R-C5 / R-C6）")

        XCTAssertNotEqual(WidgetCityResolver.followAppID,
                          WidgetCityResolver.currentLocationID,
                          "两个哨兵必须互异（混淆会把「跟随 App」与「当前位置」互换语义）")
    }

    // MARK: - ⑫ 原始容器读取三态（替代旧 loadReadOnly：不再注入 initial()）

    func testRawCitiesLoadedAdoptsCitiesVerbatim() throws {
        let store = try XCTUnwrap(store)
        let cities = [City.beijingDefault, Self.hangzhou]
        try store.saveCities(cities)

        let raw = WidgetCityCatalog.rawCities(from: store.loadCities())

        XCTAssertEqual(raw, cities, ".loaded 必须原样采用城市列表（含顺序）")
    }

    func testRawCitiesMissingYieldsEmptyWithoutPersisting() throws {
        let store = try XCTUnwrap(store)
        // 键缺失 → 空数组（**不是** initial() 的北京）。

        let raw = WidgetCityCatalog.rawCities(from: store.loadCities())

        XCTAssertTrue(raw.isEmpty, "missing → []（绝非 [北京]：容器真空 ≠ 用户选了北京）")
        XCTAssertEqual(store.loadCities(), .missing,
                       "widget 只读：missing 态读取后必须仍是 missing（无任何写入）")
    }

    func testRawCitiesCorruptYieldsEmptyWithoutPersisting() throws {
        let store = try XCTUnwrap(store)
        let defaults = try XCTUnwrap(defaults)
        let corruptBytes = Data("[{ not valid json".utf8)
        defaults.set(corruptBytes, forKey: AppGroup.citiesKey)

        let raw = WidgetCityCatalog.rawCities(from: store.loadCities())

        XCTAssertTrue(raw.isEmpty, "corrupt → []（绝不依赖坏数据、也绝不用北京兜底）")
        XCTAssertEqual(defaults.data(forKey: AppGroup.citiesKey), corruptBytes,
                       "widget 只读：corrupt 态绝不覆盖写（字节保全）")
        XCTAssertEqual(store.loadCities(), .corrupt,
                       "读取后仍必须可判为 corrupt（未被改写）")
    }

    // MARK: - ⑬ 快照归属判定（AC-C6 数据侧"不冒充"的判定单元）

    func testSnapshotOwnershipJudgment() {
        // 判定单元：City.makeID(snapshot.location) == 目标城市 id（R-C2）。
        let beijingLocation = LocationInfo.beijing

        // 同城市 → true（快照可用）。
        XCTAssertTrue(City.makeID(latitude: beijingLocation.latitude,
                                  longitude: beijingLocation.longitude)
                      == City.beijingDefault.id,
                      "快照坐标与目标城市同址 → 归属成立")

        // 异城市（北京快照 vs 杭州目标）→ false（payload 必须置 nil，不冒充）。
        XCTAssertFalse(City.makeID(latitude: beijingLocation.latitude,
                                   longitude: beijingLocation.longitude)
                       == Self.hangzhou.id,
                       "北京快照不得归属杭州实例（AC-C6）")
    }

    // MARK: - ⑭ 「当前位置」+ 拿到坐标 → 用该坐标建城（AC-C14）

    func testCurrentLocationResolvesLocatedFixIntoCurrentLocationCity() async {
        let outcome = await WidgetCityResolver.resolveOutcome(
            selection: selection(WidgetCityResolver.currentLocationID),
            container: container(cities: [], selectedID: nil),
            builtIn: WidgetBuiltInCities.cities,
            location: { .located(latitude: 30.25, longitude: 120.17) })

        XCTAssertEqual(outcome.city?.id, City.makeID(latitude: 30.25, longitude: 120.17),
                       "坐标必须进 `City.makeID`（与容器 / 内置目录同一 id 口径，"
                       + "否则容器归属判定永远命不中）")
        XCTAssertEqual(outcome.city?.name, WidgetLocationResolver.currentLocationName,
                       "展示名 = AC-C14 明文的「当前位置」（不反查地名，故无额外联网）")
        XCTAssertEqual(outcome.city?.isCurrentLocation, true)
        XCTAssertNil(outcome.emptyReason, "拿到坐标 → **不是**空态，应继续走取数阶梯")
    }

    // MARK: - ⑮⑯ 「当前位置」的两个空态必须**分开**（Apple 第 6 点）

    func testCurrentLocationUnauthorizedYieldsActionableEmptyState() async {
        let outcome = await WidgetCityResolver.resolveOutcome(
            selection: selection(WidgetCityResolver.currentLocationID),
            container: container(cities: [City.beijingDefault],
                                 selectedID: City.beijingDefault.id),
            builtIn: WidgetBuiltInCities.cities,
            location: { .notAuthorized })

        XCTAssertEqual(outcome, .locationNotAuthorized)
        XCTAssertNil(outcome.city, "未授权 → 无城市（绝不拿容器里的北京顶上）")
        XCTAssertEqual(outcome.emptyReason, .locationNotAuthorized)
        XCTAssertNotEqual(outcome.emptyReason, .locationUnavailable,
                          "Apple 明文：未授权 ≠ 已授权但拿不到 —— 用户动作不同，禁止合并成一种")
    }

    func testCurrentLocationUnavailableYieldsHonestEmptyState() async {
        let outcome = await WidgetCityResolver.resolveOutcome(
            selection: selection(WidgetCityResolver.currentLocationID),
            container: container(cities: [City.beijingDefault],
                                 selectedID: City.beijingDefault.id),
            builtIn: WidgetBuiltInCities.cities,
            location: { .unavailable })

        XCTAssertEqual(outcome, .locationUnavailable)
        XCTAssertNil(outcome.city, "本轮拿不到 → 无城市（不伪造任何坐标）")
        XCTAssertEqual(outcome.emptyReason, .locationUnavailable)
        XCTAssertNotEqual(outcome.emptyReason, .noCity,
                          "用户**已经选过**「当前位置」→ 不能退化成「请配置城市」那种提示")
    }

    // MARK: - ⑰ 定位路径**绝不**回落北京（决策 #4 / PRD §4.7.2 实施注意）

    func testNoLocationOutcomeEverFallsBackToBeijing() async {
        let fixes: [WidgetLocationOutcome] = [
            .located(latitude: 30.25, longitude: 120.17),
            .notAuthorized,
            .unavailable,
        ]

        for fix in fixes {
            // 容器里**放着北京**做诱饵：主 App 的 LocationProvider 在失败时回落 `.beijing`，
            // 小组件若照搬就会出现「顶着北京标题显示空态」的幽灵北京。
            let outcome = await WidgetCityResolver.resolveOutcome(
                selection: selection(WidgetCityResolver.currentLocationID),
                container: container(cities: [City.beijingDefault],
                                     selectedID: City.beijingDefault.id),
                builtIn: WidgetBuiltInCities.cities,
                location: { fix })

            guard let city = outcome.city else {
                continue    // 空态本就没有城市，自然不是北京（⑮⑯ 已各自断言）
            }
            XCTAssertNotEqual(city.id, City.beijingDefault.id,
                              "定位路径绝不回落北京（北京是防御性默认城市，不是用户的城市归属）")
        }
    }

    // MARK: - ⑱⑲ 定位开销：只在该取点的时候取点，且恰好一次

    func testNonCurrentLocationConfigNeverTouchesLocationProvider() async {
        let (fix, calls) = countingFix(result: .located(latitude: 30.25, longitude: 120.17))

        let followApp = await WidgetCityResolver.resolveOutcome(
            selection: selection(WidgetCityResolver.followAppID),
            container: container(cities: [Self.hangzhou], selectedID: Self.hangzhou.id),
            builtIn: WidgetBuiltInCities.cities,
            location: fix)
        XCTAssertEqual(followApp.city?.id, Self.hangzhou.id, "跟随 App 走容器，与定位无关")

        let fixed = await WidgetCityResolver.resolveOutcome(
            selection: selection(Self.hangzhou.id),
            container: container(cities: [Self.hangzhou], selectedID: nil),
            builtIn: WidgetBuiltInCities.cities,
            location: fix)
        XCTAssertEqual(fixed.city?.id, Self.hangzhou.id, "固定城市走目录，与定位无关")

        let count = await calls()
        XCTAssertEqual(count, 0,
                       "没配「当前位置」的实例必须**零**定位开销（取点闭包一次都不许调）")
    }

    func testCurrentLocationConfigUsesLocationExactlyOnce() async {
        let (fix, calls) = countingFix(result: .located(latitude: 30.25, longitude: 120.17))

        _ = await WidgetCityResolver.resolveOutcome(
            selection: selection(WidgetCityResolver.currentLocationID),
            container: container(cities: [], selectedID: nil),
            builtIn: WidgetBuiltInCities.cities,
            location: fix)

        let count = await calls()
        XCTAssertEqual(count, 1, "「当前位置」必须**恰好**取点一次（不多取、不重复消耗预算）")
    }
}

// MARK: - 测试夹具

/// 取点计数器（`async` 环境下用 `actor`：计数访问天然串行，不需额外加锁）。
private actor FixCounter {

    private let result: WidgetLocationOutcome
    private var count = 0

    init(result: WidgetLocationOutcome) {
        self.result = result
    }

    func next() -> WidgetLocationOutcome {
        count += 1
        return result
    }

    func calls() -> Int { count }
}

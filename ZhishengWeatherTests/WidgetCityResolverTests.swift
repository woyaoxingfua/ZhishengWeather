//
//  WidgetCityResolverTests.swift
//  ZhishengWeatherTests
//
//  F-C 桌面小组件城市选择：Core 解析器 + 只读载入 + 快照归属判定（AC-C9 主体）。
//  覆盖：
//    ① resolve(.followApp) → selectedCity（AC-C2 数据侧）；
//    ② resolve(.fixed) 命中 → 该城市（AC-C3 数据侧）；
//    ③ resolve(.fixed 已删 id) → 回退 followApp 结果（AC-C5 解析层）；
//    ④ 空目录 → nil（空表兜底，AC-C9）；
//    ⑤ mode(forEntityID:)：哨兵 id → .followApp，城市 id → .fixed；
//    ⑥ loadReadOnly 三态：loaded 原样采用 + 坏 selectedID 回退第一项；
//       missing / corrupt → 内存 initial 且**不落盘**（E-1 纪律在 widget 侧延续）；
//    ⑦ 快照归属判定：makeID(北京坐标) == 北京.id（true）≠ 杭州.id（false）
//       （AC-C6 数据侧"不冒充"的判定单元）。
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

    /// 双城市目录：[北京, 杭州]，选中杭州。
    private static var twoCityDirectory: CityDirectory {
        CityDirectory(cities: [City.beijingDefault, hangzhou], selectedID: hangzhou.id)
    }

    // MARK: - ① followApp → selectedCity（AC-C2 数据侧）

    func testResolveFollowAppReturnsSelectedCity() {
        let directory = Self.twoCityDirectory

        XCTAssertEqual(WidgetCityResolver.resolve(.followApp, directory: directory)?.id,
                       Self.hangzhou.id,
                       "followApp 必须解析为主 App 当前选中城市（AC-C2）")
    }

    // MARK: - ② fixed 命中（AC-C3 数据侧）

    func testResolveFixedHitReturnsThatCity() {
        let directory = Self.twoCityDirectory

        XCTAssertEqual(WidgetCityResolver.resolve(.fixed(cityID: City.beijingDefault.id),
                                                 directory: directory)?.id,
                       City.beijingDefault.id,
                       "fixed 命中目录项必须返回该城市，而非选中城市（AC-C3）")
        XCTAssertEqual(WidgetCityResolver.resolve(.fixed(cityID: Self.hangzhou.id),
                                                 directory: directory)?.id,
                       Self.hangzhou.id)
    }

    // MARK: - ③ fixed 未命中 → 回退 followApp（AC-C5 解析层）

    func testResolveFixedMissFallsBackToFollowAppResult() {
        let directory = Self.twoCityDirectory

        XCTAssertEqual(WidgetCityResolver.resolve(.fixed(cityID: "no,such,id"),
                                                 directory: directory)?.id,
                       Self.hangzhou.id,
                       "fixed 已删/坏值必须回退为 followApp 的解析结果（AC-C5）")
    }

    // MARK: - ④ 空目录 → nil（AC-C9 空表兜底）

    func testResolveEmptyDirectoryReturnsNil() {
        // 理论不可达（CityDirectory 不变式 ≥1），仅 corrupt/missing 防御路径。
        let directory = CityDirectory(cities: [], selectedID: "39.90,116.41")

        XCTAssertNil(WidgetCityResolver.resolve(.followApp, directory: directory),
                     "空目录 followApp → nil（UI 走暂无数据空态）")
        XCTAssertNil(WidgetCityResolver.resolve(.fixed(cityID: "39.90,116.41"),
                                                directory: directory),
                     "空目录 fixed 未命中 → nil")
    }

    // MARK: - ⑤ mode(forEntityID:)：哨兵判定集中

    func testModeForEntityIDMapsSentinelAndCityID() {
        XCTAssertEqual(WidgetCityResolver.mode(forEntityID: WidgetCityResolver.followAppID),
                       .followApp,
                       "哨兵 id 必须判为 .followApp")
        XCTAssertEqual(WidgetCityResolver.mode(forEntityID: City.beijingDefault.id),
                       .fixed(cityID: City.beijingDefault.id),
                       "城市 id 必须判为 .fixed（携带该 id）")
    }

    /// 哨兵 id 与 City.makeID 产物格式互斥（R-C5，格式面防撞）。
    func testSentinelIDNeverCollidesWithMakeIDFormat() {
        // makeID 产物形如 "39.90,116.41"：数字+逗号+小数点，不可能等于 "follow-app"。
        XCTAssertNotEqual(City.makeID(latitude: 39.90, longitude: 116.41),
                          WidgetCityResolver.followAppID)
        XCTAssertFalse(WidgetCityResolver.followAppID.contains(","))
    }

    // MARK: - ⑥ loadReadOnly 三态（widget 侧 E-1，仅"不落盘"差异）

    func testLoadReadOnlyLoadedAdoptsCitiesAndFallsBackSelection() throws {
        let store = try XCTUnwrap(store)
        let cities = [City.beijingDefault, Self.hangzhou]
        try store.saveCities(cities)
        // 坏 selectedID：不指向任何项 → loadReadOnly 需按既有规则回退第一项。
        try store.saveSelectedCityID("no,such,id")

        let directory = CityDirectory.loadReadOnly(from: store)

        XCTAssertEqual(directory.cities, cities, ".loaded 必须原样采用城市列表")
        XCTAssertEqual(directory.selectedCity?.id, City.beijingDefault.id,
                       "坏 selectedID 必须回退第一项")
    }

    func testLoadReadOnlyMissingDoesNotPersist() throws {
        let store = try XCTUnwrap(store)
        // 键缺失 → 内存 initial，绝不落盘（首启落盘是主 App 的职责，AC-B1）。

        let directory = CityDirectory.loadReadOnly(from: store)

        XCTAssertEqual(directory, CityDirectory.initial(),
                       "missing → 内存 initial（[北京] + 选中北京）")
        XCTAssertEqual(store.loadCities(), .missing,
                       "widget 只读：missing 态读取后必须仍是 missing（无任何写入）")
    }

    func testLoadReadOnlyCorruptDoesNotPersist() throws {
        let store = try XCTUnwrap(store)
        let defaults = try XCTUnwrap(defaults)
        let corruptBytes = Data("[{ not valid json".utf8)
        defaults.set(corruptBytes, forKey: AppGroup.citiesKey)

        let directory = CityDirectory.loadReadOnly(from: store)

        XCTAssertEqual(directory, CityDirectory.initial(),
                       "corrupt → 内存 initial（不依赖坏数据）")
        XCTAssertEqual(defaults.data(forKey: AppGroup.citiesKey), corruptBytes,
                       "widget 只读：corrupt 态绝不覆盖写（字节保全）")
        XCTAssertEqual(store.loadCities(), .corrupt,
                       "读取后仍必须可判为 corrupt（未被改写）")
    }

    // MARK: - ⑦ 快照归属判定（AC-C6 数据侧"不冒充"的判定单元）

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
}

//
//  WeatherViewModelCityInitTests.swift
//  ZhishengWeatherTests
//
//  F-B 核验裁定补充：锁定 VM init 城市目录三分支行为（F-B 的最后一笔）。
//    - .missing（键缺失）→ 初始目录 [北京] + **立即落盘**；
//    - .corrupt（坏 JSON）→ 内存回退初始目录 + **绝不落盘覆盖**（字节保全）+ 日志；
//    - .loaded → 直接采用；
//    - selectedID 坏值 → CityDirectory 回退第一项，同样**不落盘覆盖**。
//
//  使用临时 UserDefaults suite（测试 bundle 无 App Group 权限）；
//  init 为同步路径，无网络依赖（store 未预热时 loadSnapshot 为 nil）。
//

import XCTest
@testable import ZhishengWeather

@MainActor
final class WeatherViewModelCityInitTests: XCTestCase {

    private var suiteName: String = ""
    private var defaults: UserDefaults?
    private var store: AppGroupStore?

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 临时 suite：避免依赖真实 App Group 权限。
        let name = "zs.test.vm.\(UUID().uuidString)"
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

    // MARK: - .missing：键缺失 → 初始目录 + 立即落盘

    func testMissingKeyInitAdoptsInitialDirectoryAndPersistsImmediately() throws {
        let store = try XCTUnwrap(store)
        let vm = WeatherViewModel(store: store)

        XCTAssertEqual(vm.directory, CityDirectory.initial(),
                       "键缺失必须回退初始目录 [北京] + 选中北京")
        XCTAssertEqual(vm.directory.selectedCity?.id, City.beijingDefault.id)

        // 立即落盘：写入的是合法初始结构（不违反"不清数据"纪律），
        // 模拟"重启"后能以 .loaded 读回同一份初始目录。
        guard case .loaded(let persisted) = store.loadCities() else {
            return XCTFail("missing 分支必须立即落盘初始目录")
        }
        XCTAssertEqual(persisted, CityDirectory.initial().cities)
    }

    // MARK: - .corrupt：坏 JSON → 内存回退 + 绝不覆盖写

    func testCorruptJSONInitFallsBackInMemoryWithoutOverwriting() throws {
        let store = try XCTUnwrap(store)
        let defaults = try XCTUnwrap(defaults)
        let corruptBytes = Data("[{ not valid json".utf8)
        defaults.set(corruptBytes, forKey: AppGroup.citiesKey)

        let vm = WeatherViewModel(store: store)

        XCTAssertEqual(vm.directory, CityDirectory.initial(),
                       "坏 JSON 时本次启动在内存中回退初始目录")
        // 裁定核心：corrupt 分支绝不落盘覆盖，坏字节原样保留（留给用户显式操作时修正）。
        XCTAssertEqual(defaults.data(forKey: AppGroup.citiesKey), corruptBytes,
                       "corrupt 分支不得覆盖写既有字节")
        XCTAssertEqual(store.loadCities(), .corrupt,
                       "VM 读取后 store 数据仍必须可判为 corrupt（未被改写）")
    }

    // MARK: - .loaded：正常载入 + 选中项保持

    func testStoredCitiesInitAdoptsDirectoryAndKeepsSelection() throws {
        let store = try XCTUnwrap(store)
        let cities = [
            City.beijingDefault,
            City(name: "杭州", latitude: 30.25, longitude: 120.17, isCurrentLocation: false)
        ]
        try store.saveCities(cities)
        try store.saveSelectedCityID(cities[1].id)

        let vm = WeatherViewModel(store: store)

        XCTAssertEqual(vm.directory.cities, cities)
        XCTAssertEqual(vm.directory.selectedCity?.id, cities[1].id)
    }

    // MARK: - selectedID 坏值：回退第一项 + 不落盘覆盖

    func testCorruptSelectedIDFallsBackToFirstCityWithoutOverwrite() throws {
        let store = try XCTUnwrap(store)
        let cities = [
            City.beijingDefault,
            City(name: "杭州", latitude: 30.25, longitude: 120.17, isCurrentLocation: false)
        ]
        try store.saveCities(cities)
        let bogusID = "no,such,id"
        try store.saveSelectedCityID(bogusID)

        let vm = WeatherViewModel(store: store)

        XCTAssertEqual(vm.directory.selectedCity?.id, City.beijingDefault.id,
                       "选中 id 不指向任何项 → 回退第一项（北京）")
        XCTAssertEqual(store.selectedCityID, bogusID,
                       "裁定一致性：坏值回退不落盘覆盖，原字节保留")
        XCTAssertEqual(vm.directory.cities, cities,
                       "selectedID 坏值只影响选中项，不得改动城市列表")
    }
}

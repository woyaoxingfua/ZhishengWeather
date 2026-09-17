//
//  WidgetCityCatalogTests.swift
//  ZhishengWeatherTests
//
//  城市目录纯函数（ARCH §7.5 / §12.2）：可见城市合并去重保序、按 id 查找优先级、
//  规范坐标回填（"%.2f,%.2f" 往返稳定 + 越界 / 怪值拒绝）。
//
//  纪律：全部调用**真实函数**并**注入**输入（不手工模拟实现的假设）—— P-18。
//

import XCTest
@testable import ZhishengWeather

final class WidgetCityCatalogTests: XCTestCase {

    // MARK: - Helpers

    private static func city(_ name: String, _ latitude: Double, _ longitude: Double) -> City {
        City(name: name, latitude: latitude, longitude: longitude, isCurrentLocation: false)
    }

    private let a = WidgetCityCatalogTests.city("A城", 10.00, 20.00)
    private let b = WidgetCityCatalogTests.city("B城", 30.00, 40.00)
    private let c = WidgetCityCatalogTests.city("C城", 50.00, 60.00)

    // MARK: - 合并去重保序

    func testVisibleCitiesKeepsContainerFirstAndAppendsNonDuplicateBuiltIn() {
        let visible = WidgetCityCatalog.visibleCities(container: [a, b], builtIn: [b, c])

        XCTAssertEqual(visible.map(\.id), [a.id, b.id, c.id],
                       "容器在前（保序）+ 内置未重复项追加在末（B 不重复出现）")
        XCTAssertEqual(visible.count, 3, "去重后总数为 3")
    }

    func testVisibleCitiesDeduplicatesWithinContainer() {
        let visible = WidgetCityCatalog.visibleCities(container: [a, a, b], builtIn: [])

        XCTAssertEqual(visible.map(\.id), [a.id, b.id],
                       "容器内部重复也要去重（先出现者胜）")
    }

    func testVisibleCitiesIsEmptyWhenBothSourcesAreEmpty() {
        XCTAssertTrue(WidgetCityCatalog.visibleCities(container: [], builtIn: []).isEmpty,
                      "两者皆空 → 空数组（调用方负责前置哨兵；不在此注入默认城市）")
    }

    // MARK: - 查找优先级

    func testCityForIDPrefersContainerThenBuiltIn() {
        // 同 id 两岸都有 → 容器项胜出。
        let containerA = WidgetCityCatalogTests.city("A城·容器", 10.00, 20.00)
        let hit = WidgetCityCatalog.city(forID: a.id, container: [containerA], builtIn: [a])
        XCTAssertEqual(hit?.name, "A城·容器", "容器优先（全量元数据）")

        // 容器未命中 → 内置。
        let builtInHit = WidgetCityCatalog.city(forID: b.id, container: [containerA], builtIn: [b])
        XCTAssertEqual(builtInHit?.id, b.id, "容器未命中 → 查内置目录")

        // 都未命中 → nil（绝不回退成任意城市）。
        XCTAssertNil(WidgetCityCatalog.city(forID: "no,such,id", container: [containerA], builtIn: [b]))
    }

    // MARK: - 规范坐标回填

    func testCanonicalIDRoundTripForPositiveCoordinates() {
        let backfilled = WidgetCityCatalog.city(fromCanonicalID: "30.25,120.17", name: "苏州")

        XCTAssertEqual(backfilled?.id, "30.25,120.17", "规范坐标 id 必须往返稳定")
        XCTAssertEqual(backfilled?.latitude, 30.25)
        XCTAssertEqual(backfilled?.longitude, 120.17)
        XCTAssertEqual(backfilled?.name, "苏州", "展示名由配置携带，不伪造")
    }

    func testCanonicalIDRoundTripForNegativeCoordinates() {
        let backfilled = WidgetCityCatalog.city(fromCanonicalID: "-33.87,151.21", name: "悉尼")

        XCTAssertEqual(backfilled?.id, "-33.87,151.21",
                       "负值坐标同样往返稳定（南半球 / 西经）")
    }

    func testNonCanonicalOrOutOfRangeIDsAreRejected() {
        XCTAssertNil(WidgetCityCatalog.city(fromCanonicalID: "abc", name: "x"),
                     "非数字 → nil")
        XCTAssertNil(WidgetCityCatalog.city(fromCanonicalID: "1,2,3", name: "x"),
                     "三段 → nil")
        XCTAssertNil(WidgetCityCatalog.city(fromCanonicalID: "200,0", name: "x"),
                     "纬度越界 → nil（绝不用非法坐标去取数）")
        XCTAssertNil(WidgetCityCatalog.city(fromCanonicalID: "0,200", name: "x"),
                     "经度越界 → nil")
        XCTAssertNil(WidgetCityCatalog.city(fromCanonicalID: "1,2", name: "x"),
                     "非规范串（未补零）→ nil（重启后 id 会变，属不稳定值）")
        XCTAssertNil(WidgetCityCatalog.city(fromCanonicalID: "30.250,120.170", name: "x"),
                     "非规范串（三位小数）→ nil")
    }

    // MARK: - 原始容器读取

    func testRawCitiesMapsThreeStatesWithoutInjection() {
        XCTAssertEqual(WidgetCityCatalog.rawCities(from: .loaded([a, b])), [a, b],
                       ".loaded → 原样（保序）")
        XCTAssertTrue(WidgetCityCatalog.rawCities(from: .missing).isEmpty,
                      ".missing → []（不注入 initial() 的北京）")
        XCTAssertTrue(WidgetCityCatalog.rawCities(from: .corrupt).isEmpty,
                      ".corrupt → []（不依赖坏数据、不注入默认城市）")
    }
}

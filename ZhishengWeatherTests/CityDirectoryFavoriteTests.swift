//
//  CityDirectoryFavoriteTests.swift
//  ZhishengWeatherTests
//
//  A2-6 星标（AC-A2-18/19/20）：displayCities 稳定置顶、toggle 不改写数组
//  顺序与 selectedID、旧 JSON 缺 isFavorite 解码 nil。
//

import XCTest
@testable import ZhishengWeather

final class CityDirectoryFavoriteTests: XCTestCase {

    /// 构造目录：北京 / 杭州 / 米兰（顺序固定，便于验证"组内保持原序"）。
    private func makeDirectory() -> CityDirectory {
        var d = CityDirectory.initial()
        d.add(City(name: "杭州", latitude: 30.25, longitude: 120.17, isCurrentLocation: false))
        d.add(City(name: "米兰", latitude: 45.46, longitude: 9.19, isCurrentLocation: false))
        return d
    }

    // MARK: - displayCities 稳定置顶（AC-A2-18）

    func testFavoritesFirstWithStableInGroupOrder() {
        var d = makeDirectory()
        // 米兰、北京收藏（非连续收藏，验证组内原序：米兰在收藏组内应仍在北京前？不——
        // 原序是 [北京, 杭州, 米兰] → 收藏组 [北京, 米兰]，非收藏组 [杭州]）。
        d.toggleFavorite(d.cities[2].id)  // 米兰
        d.toggleFavorite(d.cities[0].id)  // 北京

        let display = d.displayCities
        XCTAssertEqual(display.map(\.name), ["北京", "米兰", "杭州"],
                       "收藏项置顶且组内保持原序（北京先于米兰）")
    }

    func testDisplayCitiesWithoutFavoritesEqualsOriginalOrder() {
        let d = makeDirectory()
        XCTAssertEqual(d.displayCities.map(\.name), ["北京", "杭州", "米兰"])
    }

    // MARK: - toggle 不破坏不变式（AC-B9 / AC-A2-20）

    func testToggleDoesNotMutateCitiesOrderOrSelection() {
        var d = makeDirectory()
        let originalOrder = d.cities.map(\.name)
        let originalSelected = d.selectedID

        d.toggleFavorite(d.cities[1].id)

        XCTAssertEqual(d.cities.map(\.name), originalOrder,
                       "toggle 不得改写 cities 数组顺序（读取时排序裁定）")
        XCTAssertEqual(d.selectedID, originalSelected,
                       "toggle 不得改写 selectedID（AC-B9）")
        XCTAssertEqual(d.cities[1].isFavorite, true)
    }

    func testToggleTwiceRestoresState() {
        var d = makeDirectory()
        let id = d.cities[1].id
        d.toggleFavorite(id)
        XCTAssertEqual(d.cities[1].isFavorite, true)
        d.toggleFavorite(id)
        XCTAssertEqual(d.cities[1].isFavorite, false,
                       "第二次 toggle 应从 true 变 false（非 nil）")
    }

    func testToggleUnknownIDIsNoOp() {
        var d = makeDirectory()
        d.toggleFavorite("0.00,0.00")
        XCTAssertEqual(d.cities.map(\.name), ["北京", "杭州", "米兰"])
    }

    // MARK: - 旧 JSON 兼容（AC-A2-19）

    func testLegacyCityJSONWithoutIsFavoriteDecodes() throws {
        let json = """
        [
          { "id": "39.90,116.41", "name": "北京", "latitude": 39.9042,
            "longitude": 116.4074, "isCurrentLocation": false }
        ]
        """
        let cities = try JSONDecoder().decode([City].self, from: Data(json.utf8))
        XCTAssertNil(cities[0].isFavorite, "旧 JSON 缺键 → nil（视为未收藏）")
        XCTAssertEqual(cities[0].name, "北京")
    }

    func testCityRoundTripsWithIsFavorite() throws {
        var city = City(name: "杭州", latitude: 30.25, longitude: 120.17,
                        isCurrentLocation: false)
        city.isFavorite = true
        let data = try JSONEncoder().encode([city])
        let decoded = try XCTUnwrap(JSONDecoder().decode([City].self, from: data).first)
        XCTAssertEqual(decoded.isFavorite, true)
        XCTAssertEqual(decoded, city)
    }

    // MARK: - displayCities 与 Widget 读取隔离（R-A2P1-5）

    func testDisplayCitiesDoesNotAffectPersistedArrayForWidget() {
        var d = makeDirectory()
        d.toggleFavorite(d.cities[2].id)  // 米兰收藏

        // 展示顺序变化，但 loadCities 读到的持久化数组不变（Widget resolver 消费后者）。
        XCTAssertEqual(d.displayCities.first?.name, "米兰")
        XCTAssertEqual(d.cities.map(\.name), ["北京", "杭州", "米兰"],
                       "持久化数组顺序保持用户意图（Widget/拖动语义安全）")
    }
}

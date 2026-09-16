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

    // MARK: - 稳定置顶（多城，组内相对序）

    /// 4 城、两个收藏（米兰 + 哈尔滨）→ 收藏组置顶且组内保持原相对序，
    /// 非收藏组亦保持原相对序。
    func testDisplayCitiesPinsFavoritesPreservingRelativeOrder() {
        var d = CityDirectory.initial()                       // [北京]
        d.add(City(name: "杭州", latitude: 30.25, longitude: 120.17, isCurrentLocation: false))
        d.add(City(name: "米兰", latitude: 45.46, longitude: 9.19, isCurrentLocation: false))
        d.add(City(name: "哈尔滨", latitude: 45.75, longitude: 126.65, isCurrentLocation: false))
        // 原序 = [北京, 杭州, 米兰, 哈尔滨]；add 会切换选中，故先记录 toggle 前的选中项。
        let selectedBefore = d.selectedID
        d.toggleFavorite(d.cities[3].id)  // 哈尔滨
        d.toggleFavorite(d.cities[2].id)  // 米兰

        // 收藏组按原序：米兰(idx2) 先于 哈尔滨(idx3)；非收藏组：北京 先于 杭州。
        XCTAssertEqual(d.displayCities.map(\.name), ["米兰", "哈尔滨", "北京", "杭州"],
                       "收藏置顶且组内保持原相对序（AC-A2-18）")
        XCTAssertEqual(d.selectedID, selectedBefore, "置顶不得漂移 selectedID")
        XCTAssertEqual(d.cities.map(\.name), ["北京", "杭州", "米兰", "哈尔滨"],
                       "置顶只改派生展示序，绝不改写持久化数组顺序")
    }

    // MARK: - 展示序 ≠ 存储序：拖动 / 删除必须按 id（D-1 连带坑）

    /// 置顶使展示序与存储序错位后，`moveDisplay` 必须命中**展示序对应城市（按 id）**，
    /// 而非拿展示序下标去索引存储序数组。
    func testMoveDisplayResolvesByIDWhenDisplayOrderDiffersFromStored() {
        var d = makeDirectory()                 // 存储序 = [北京, 杭州, 米兰]
        d.toggleFavorite(d.cities[2].id)        // 米兰收藏 → 展示序 = [米兰, 北京, 杭州]
        XCTAssertEqual(d.displayCities.map(\.name), ["米兰", "北京", "杭州"])

        // 拖动展示序下标 1（北京）到末尾（toOffset = 3）。
        d.moveDisplay(fromOffsets: IndexSet(integer: 1), toOffset: 3)

        // 若误按存储序下标移动，会错误地移动 cities[1] = 杭州。
        XCTAssertEqual(d.cities.map(\.name), ["米兰", "杭州", "北京"],
                       "必须按 id 命中展示序中的北京，而非存储序下标 1 的杭州")
        XCTAssertEqual(d.displayCities.map(\.name), ["米兰", "杭州", "北京"],
                       "置顶后新存储序即展示序（米兰仍在收藏组置顶）")
    }

    /// 收藏组内部的展示序拖动同样按 id 生效。
    func testMoveDisplayWithinFavoritesGroupResolvesByID() {
        var d = CityDirectory.initial()
        d.add(City(name: "杭州", latitude: 30.25, longitude: 120.17, isCurrentLocation: false))
        d.add(City(name: "米兰", latitude: 45.46, longitude: 9.19, isCurrentLocation: false))
        // 存储序 = [北京, 杭州, 米兰]
        d.toggleFavorite(d.cities[0].id)  // 北京收藏
        d.toggleFavorite(d.cities[2].id)  // 米兰收藏
        XCTAssertEqual(d.displayCities.map(\.name), ["北京", "米兰", "杭州"])

        // 拖动展示序下标 1（米兰）到 0 → 米兰置前。
        d.moveDisplay(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertEqual(d.displayCities.map(\.name), ["米兰", "北京", "杭州"],
                       "收藏组内拖动按 id 生效（米兰与北京换位）")
    }

    /// 置顶后删除：展示序下标 0 = 米兰（收藏项），必须删掉米兰而非存储序首项北京。
    func testDeleteResolvedByIDWhenDisplayOrderDiffersFromStored() {
        var d = makeDirectory()                 // 存储序 = [北京, 杭州, 米兰]
        d.toggleFavorite(d.cities[2].id)        // 米兰收藏 → 展示序 = [米兰, 北京, 杭州]

        // 模拟列表侧 handleDelete：展示序 offset → id。
        let display = d.displayCities
        let targetID = display[0].id
        XCTAssertEqual(display[0].name, "米兰")

        XCTAssertTrue(d.remove(targetID))
        XCTAssertEqual(d.cities.map(\.name), ["北京", "杭州"],
                       "必须删掉米兰（按 id），而非存储序下标 0 的北京")
        XCTAssertEqual(d.displayCities.map(\.name), ["北京", "杭州"])
    }

    /// 置顶后删除非收藏项（展示序下标 2 = 杭州）。
    func testDeleteNonFavoriteByIDWhenDisplayOrderDiffersFromStored() {
        var d = makeDirectory()
        d.toggleFavorite(d.cities[2].id)        // 展示序 = [米兰, 北京, 杭州]

        let targetID = d.displayCities[2].id     // 杭州
        XCTAssertEqual(d.displayCities[2].name, "杭州")
        XCTAssertTrue(d.remove(targetID))
        XCTAssertEqual(d.cities.map(\.name), ["北京", "米兰"], "删除杭州后仅剩北京与米兰")
    }

    // MARK: - 纯函数 CityDirectory.moved（复刻 Array.move 语义）

    func testMovedHelperMatchesArrayMoveSemantics() {
        let ids = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(CityDirectory.moved(ids, fromOffsets: IndexSet([0, 1]), toOffset: 3),
                       ["c", "a", "b", "d", "e"])
        XCTAssertEqual(CityDirectory.moved(ids, fromOffsets: IndexSet(integer: 2), toOffset: 0),
                       ["c", "a", "b", "d", "e"])
        XCTAssertEqual(CityDirectory.moved(ids, fromOffsets: IndexSet(integer: 0), toOffset: 3),
                       ["b", "c", "a", "d", "e"])
        XCTAssertEqual(CityDirectory.moved(ids, fromOffsets: IndexSet(integer: 4), toOffset: 0),
                       ["e", "a", "b", "c", "d"])
        // 越界 offset → 原样返回（不崩）。
        XCTAssertEqual(CityDirectory.moved(ids, fromOffsets: IndexSet(integer: 99), toOffset: 0),
                       ids)
    }
}

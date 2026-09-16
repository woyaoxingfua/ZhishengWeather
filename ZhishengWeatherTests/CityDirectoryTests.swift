//
//  CityDirectoryTests.swift
//  ZhishengWeatherTests
//
//  F-B：CityDirectory 纯值逻辑（AC-B15 ≥7 用例 → 实写 10 条，不联网、无时钟）。
//  覆盖：initial / add 去重（0.01° 容差两侧）/ remove（含仅剩 1 项、删当前项回退）/
//        upsert（首次新增 / 与手动城市重合 / isFallback no-op / 就地更新不变式）。
//  注：拖动排序的**展示序**语义（UI 实际使用的那套）在 CityDirectoryFavoriteTests；
//      旧的**存储序** move 及其用例属死路径（UI 不再调用），已随死代码一并删除。
//

import XCTest
@testable import ZhishengWeather

final class CityDirectoryTests: XCTestCase {

    // MARK: - Helpers

    /// 按坐标+名称构造手动城市。
    private func city(_ name: String, lat: Double, lon: Double) -> City {
        City(name: name, latitude: lat, longitude: lon, isCurrentLocation: false)
    }

    /// 定位结果（isFallback 可控）。
    private func location(lat: Double, lon: Double, fallback: Bool = false) -> LocationInfo {
        LocationInfo(name: "当前位置", latitude: lat, longitude: lon, isFallback: fallback)
    }

    // MARK: - ① initial

    func testInitialStateIsBeijingSelected() {
        let directory = CityDirectory.initial()

        XCTAssertEqual(directory.cities.map(\.name), ["北京"], "AC-B1：首次安装仅北京")
        XCTAssertEqual(directory.cities.count, 1)
        XCTAssertEqual(directory.selectedID, directory.cities.first?.id)
        XCTAssertEqual(directory.selectedCity?.id, City.beijingDefault.id)
    }

    // MARK: - ② add 新城市

    func testAddNewCityAppendsAndSelects() {
        var directory = CityDirectory.initial()
        let hangzhou = city("杭州", lat: 30.25, lon: 120.17)

        let added = directory.add(hangzhou)

        XCTAssertTrue(added, "新城市应返回 true")
        XCTAssertEqual(directory.cities.map(\.name), ["北京", "杭州"], "追加到列表尾部")
        XCTAssertEqual(directory.selectedID, hangzhou.id, "新增后切为选中（AC-B5）")
    }

    // MARK: - ③ add 重复（AC-B8 去重容差两侧）

    func testAddDuplicateWithinToleranceDeduplicates() {
        var directory = CityDirectory.initial()
        // 差 0.009°：39.8951 与 39.9041 均规范化为 "39.90" → 视为同一城市。
        let first = city("城市甲", lat: 39.8951, lon: 116.40)
        let second = city("城市乙", lat: 39.9041, lon: 116.40)
        XCTAssertTrue(directory.add(first))
        XCTAssertTrue(directory.cities.contains(where: { $0.id == first.id }))

        let addedAgain = directory.add(second)

        XCTAssertFalse(addedAgain, "规范化 id 相同（差 0.009°）应去重，不新增")
        XCTAssertEqual(directory.cities.count, 2, "目录仍只有 北京 + 城市甲")
        XCTAssertEqual(directory.selectedID, second.id, "去重时仍要切换选中（AC-B8）")
    }

    func testAddOutsideToleranceDoesNotDeduplicate() {
        var directory = CityDirectory.initial()
        // 差 0.02°：39.90 与 39.92 → 不同规范化 id → 不去重。
        let first = city("城市甲", lat: 39.90, lon: 116.40)
        let second = city("城市乙", lat: 39.92, lon: 116.40)
        XCTAssertTrue(directory.add(first))

        let added = directory.add(second)

        XCTAssertTrue(added, "差 0.02° 超出 0.01° 容差，应作为新城市追加")
        XCTAssertEqual(directory.cities.count, 3)
    }

    // MARK: - ④ remove 普通项

    func testRemoveNonSelectedCityKeepsSelection() {
        var directory = CityDirectory.initial()
        let hangzhou = city("杭州", lat: 30.25, lon: 120.17)
        XCTAssertTrue(directory.add(hangzhou))
        // 选中切回北京（非删除目标）。
        XCTAssertTrue(directory.select(City.beijingDefault.id))

        let removed = directory.remove(hangzhou.id)

        XCTAssertTrue(removed)
        XCTAssertEqual(directory.cities.map(\.name), ["北京"])
        XCTAssertEqual(directory.selectedID, City.beijingDefault.id, "删非选中项不动选中")
    }

    // MARK: - ⑤ remove 当前项 → 回退第一项（AC-B10）

    func testRemoveSelectedCityFallsBackToFirstRemaining() {
        var directory = CityDirectory.initial()
        XCTAssertTrue(directory.add(city("杭州", lat: 30.25, lon: 120.17)))
        XCTAssertTrue(directory.add(city("米兰", lat: 45.46, lon: 9.19)))
        // 此时选中 = 米兰（最后添加）。

        let removed = directory.remove(city("米兰", lat: 45.46, lon: 9.19).id)

        XCTAssertTrue(removed)
        XCTAssertEqual(directory.selectedID, directory.cities.first?.id,
                       "删除当前选中项应自动选中剩余列表第一项（AC-B10）")
        XCTAssertEqual(directory.selectedCity?.name, "北京")
    }

    // MARK: - ⑥ remove 仅剩 1 项 → no-op（AC-B11）

    func testRemoveLastRemainingCityIsNoOp() {
        var directory = CityDirectory.initial()
        XCTAssertEqual(directory.cities.count, 1)

        let removed = directory.remove(City.beijingDefault.id)

        XCTAssertFalse(removed, "仅剩 1 项时删除必须被拒绝（AC-B11）")
        XCTAssertEqual(directory.cities.count, 1)
        XCTAssertEqual(directory.selectedCity?.name, "北京")
    }

    func testRemoveUnknownIDIsNoOp() {
        var directory = CityDirectory.initial()

        XCTAssertFalse(directory.remove("0.00,0.00"), "不存在的 id 应 no-op")
        XCTAssertEqual(directory.cities.count, 1)
    }

    // MARK: - ⑦ upsert：首次定位新增"当前位置"

    func testUpsertFirstLocationAppendsCurrentLocation() {
        var directory = CityDirectory.initial()

        let changed = directory.upsertCurrentLocation(location(lat: 31.23, lon: 121.47))

        XCTAssertTrue(changed)
        XCTAssertEqual(directory.cities.count, 2)
        let current = directory.cities.last
        XCTAssertEqual(current?.name, "当前位置")
        XCTAssertTrue(current?.isCurrentLocation ?? false, "不变式：新增项标记为当前位置")
        XCTAssertEqual(current?.id, City.makeID(latitude: 31.23, longitude: 121.47))
    }

    // MARK: - ⑧ upsert：与手动城市重合 → 不新增（Q5）

    func testUpsertOverlappingManualCityDoesNotAdd() {
        var directory = CityDirectory.initial()
        // 手动添加"杭州"，其规范化 id 与随后定位结果一致。
        XCTAssertTrue(directory.add(city("杭州", lat: 30.25, lon: 120.17)))

        let changed = directory.upsertCurrentLocation(location(lat: 30.251, lon: 120.172))

        XCTAssertFalse(changed, "坐标重合（规范化 id 相同）应视为同一城市，不新增不改名（Q5）")
        XCTAssertEqual(directory.cities.count, 2)
        XCTAssertEqual(directory.cities.last?.name, "杭州", "手动城市名不被覆盖")
        XCTAssertFalse(directory.cities.last?.isCurrentLocation ?? true,
                       "手动城市不因 upsert 变为当前位置项")
    }

    // MARK: - ⑨ upsert：isFallback=true → no-op（AC-B3）

    func testUpsertFallbackLocationIsNoOp() {
        var directory = CityDirectory.initial()

        let changed = directory.upsertCurrentLocation(location(lat: 39.90, lon: 116.41,
                                                               fallback: true))

        XCTAssertFalse(changed, "定位被拒/失败/超时（isFallback）必须 no-op（AC-B3）")
        XCTAssertEqual(directory.cities.count, 1, "不得新增'当前位置'项")
        XCTAssertFalse(directory.cities.contains(where: { $0.isCurrentLocation }))
    }

    // MARK: - ⑩ upsert：已有"当前位置"项 → 就地更新（不变式至多一项）

    func testUpsertUpdatesExistingCurrentLocationInPlace() {
        var directory = CityDirectory.initial()
        XCTAssertTrue(directory.upsertCurrentLocation(location(lat: 31.23, lon: 121.47)))
        XCTAssertEqual(directory.cities.count, 2)

        // 用户移动到新坐标 → 规范化 id 变化 → 就地更新而非新增。
        let changed = directory.upsertCurrentLocation(location(lat: 39.90, lon: 116.41))

        XCTAssertTrue(changed)
        XCTAssertEqual(directory.cities.count, 2, "不变式：列表中至多一个'当前位置'项")
        let currentItems = directory.cities.filter { $0.isCurrentLocation }
        XCTAssertEqual(currentItems.count, 1)
        XCTAssertEqual(currentItems.first?.id,
                       City.makeID(latitude: 39.90, longitude: 116.41),
                       "坐标更新后 id 应同步规范化")
        XCTAssertEqual(directory.cities.map(\.name), ["北京", "当前位置"])
    }

    /// ⑩ 补充：选中的"当前位置"项被就地更新后，选中 id 应跟随新 id。
    func testUpsertFollowsSelectionWhenCurrentLocationIDChanges() {
        var directory = CityDirectory.initial()
        XCTAssertTrue(directory.upsertCurrentLocation(location(lat: 31.23, lon: 121.47)))
        // 选中"当前位置"项。
        let oldID = City.makeID(latitude: 31.23, longitude: 121.47)
        XCTAssertTrue(directory.select(oldID))

        XCTAssertTrue(directory.upsertCurrentLocation(location(lat: 22.54, lon: 114.06)))

        XCTAssertEqual(directory.selectedID,
                       City.makeID(latitude: 22.54, longitude: 114.06),
                       "选中的当前位置项坐标更新后，选中 id 应跟随")
    }
}

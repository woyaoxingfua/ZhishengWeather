//
//  HomeSectionTests.swift
//  ZhishengWeatherTests
//
//  A2-7 模块排序/隐藏持久化（AC-A2-21/22/23）：
//   - 默认顺序 / 自定义顺序回读 / 未知标识过滤 / 缺失区块补齐 / 损坏回默认；
//   - 隐藏集合同理；reset 清两键；
//   - 全部走独立 UserDefaults suite，不污染真机数据。
//

import XCTest
@testable import ZhishengWeather

@MainActor
final class HomeSectionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // HomeSectionOrder 直用 standard —— 用例前清键防跨用例污染。
        UserDefaults.standard.removeObject(forKey: HomeSection.storageKey)
        UserDefaults.standard.removeObject(forKey: HomeSection.storageKey + ".hidden")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: HomeSection.storageKey)
        UserDefaults.standard.removeObject(forKey: HomeSection.storageKey + ".hidden")
        super.tearDown()
    }

    // MARK: - 默认顺序

    func testDefaultOrderMatchesDeclaration() {
        let order = HomeSectionOrder.current()
        XCTAssertEqual(order, HomeSection.defaultOrder)
        XCTAssertEqual(order.count, 7, "7 个可排序区块（Hero/页脚不参与）")
        // 首项为昨日对比（与主屏默认一致）。
        XCTAssertEqual(order.first, .yesterday)
    }

    // MARK: - 自定义顺序回读

    func testCustomOrderRoundTrips() {
        let custom: [HomeSection] = [.moon, .hourly, .daily, .metrics,
                                     .airQuality, .lifeIndex, .yesterday]
        HomeSectionOrder.save(custom)
        XCTAssertEqual(HomeSectionOrder.current(), custom)
    }

    // MARK: - 未知标识过滤 + 缺失补齐

    func testUnknownIdentifiersFilteredAndMissingAppended() {
        // 存一个含未知标识 + 缺失区块的序列。
        UserDefaults.standard.set(
            ["moon", "bogus_section", "hourly"],
            forKey: HomeSection.storageKey)
        let order = HomeSectionOrder.current()
        // 未知标识被过滤，缺失区块按默认序补齐尾部。
        XCTAssertEqual(order.first, .moon)
        XCTAssertEqual(order[1], .hourly)
        XCTAssertEqual(order.count, 7, "补齐后必须为全量 7 区块")
    }

    func testCorruptedStorageFallsBackToDefault() {
        // 存非枚举原始值（全部未知）→ 回默认。
        UserDefaults.standard.set(["x", "y"], forKey: HomeSection.storageKey)
        XCTAssertEqual(HomeSectionOrder.current(), HomeSection.defaultOrder)
    }

    // MARK: - 隐藏集合

    func testHiddenSetRoundTrips() {
        HomeSectionOrder.saveHidden([.airQuality, .lifeIndex])
        XCTAssertEqual(HomeSectionOrder.hidden(), [.airQuality, .lifeIndex])
    }

    // MARK: - 恢复默认（AC-A2-22）

    func testResetClearsBothKeys() {
        HomeSectionOrder.save([.moon, .hourly, .daily, .metrics,
                               .airQuality, .lifeIndex, .yesterday])
        HomeSectionOrder.saveHidden([.moon])
        HomeSectionOrder.reset()
        XCTAssertEqual(HomeSectionOrder.current(), HomeSection.defaultOrder)
        XCTAssertTrue(HomeSectionOrder.hidden().isEmpty)
    }
}

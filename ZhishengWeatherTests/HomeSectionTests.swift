//
//  HomeSectionTests.swift
//  ZhishengWeatherTests
//
//  A2-7 模块排序/隐藏持久化（AC-A2-21/22/23）：
//   - 默认顺序 / 自定义顺序回读 / 未知标识过滤 / 缺失区块补齐 / 损坏回默认；
//   - 隐藏集合同理；reset 清两键；
//   - 全部走独立 UserDefaults suite（`zs.test.homeSection.<UUID>`），
//     tearDown 清空该 suite，**不写** `UserDefaults.standard`（真机 App 数据）。
//

import XCTest
@testable import ZhishengWeather

@MainActor
final class HomeSectionTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    /// 被测对象：读与写绑**同一个**注入 store。
    private var order: HomeSectionOrder!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "zs.test.homeSection.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        order = HomeSectionOrder(defaults: defaults)
    }

    override func tearDown() {
        if let defaults, let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        order = nil
        super.tearDown()
    }

    // MARK: - 默认顺序

    func testDefaultOrderMatchesDeclaration() {
        let order = self.order.current()
        XCTAssertEqual(order, HomeSection.defaultOrder)
        XCTAssertEqual(order.count, 7, "7 个可排序区块（Hero/页脚不参与）")
        // 首项为昨日对比（与主屏默认一致）。
        XCTAssertEqual(order.first, .yesterday)
    }

    // MARK: - 自定义顺序回读

    func testCustomOrderRoundTrips() {
        let custom: [HomeSection] = [.moon, .hourly, .daily, .metrics,
                                     .airQuality, .lifeIndex, .yesterday]
        order.save(custom)
        XCTAssertEqual(order.current(), custom)
    }

    // MARK: - 未知标识过滤 + 缺失补齐

    func testUnknownIdentifiersFilteredAndMissingAppended() {
        // 存一个含未知标识 + 缺失区块的序列。
        defaults.set(
            ["moon", "bogus_section", "hourly"],
            forKey: HomeSection.storageKey)
        let current = order.current()
        // 未知标识被过滤，缺失区块按默认序补齐尾部。
        XCTAssertEqual(current.first, .moon)
        XCTAssertEqual(current[1], .hourly)
        XCTAssertEqual(current.count, 7, "补齐后必须为全量 7 区块")
    }

    func testCorruptedStorageFallsBackToDefault() {
        // 存非枚举原始值（全部未知）→ 回默认。
        defaults.set(["x", "y"], forKey: HomeSection.storageKey)
        XCTAssertEqual(order.current(), HomeSection.defaultOrder)
    }

    // MARK: - 隐藏集合

    func testHiddenSetRoundTrips() {
        order.saveHidden([.airQuality, .lifeIndex])
        XCTAssertEqual(order.hidden(), [.airQuality, .lifeIndex])
    }

    // MARK: - 恢复默认（AC-A2-22）

    func testResetClearsBothKeys() {
        order.save([.moon, .hourly, .daily, .metrics,
                    .airQuality, .lifeIndex, .yesterday])
        order.saveHidden([.moon])
        order.reset()
        XCTAssertEqual(order.current(), HomeSection.defaultOrder)
        XCTAssertTrue(order.hidden().isEmpty)
    }

    // MARK: - 注入缝完整性（回归守卫）

    /// 读写只落注入的 suite：`UserDefaults.standard`（真机 App 数据）逐字不变。
    /// 这是「注入缝只用了半条」缺陷形态的守卫。
    func testPersistenceDoesNotTouchStandardDefaults() {
        let storedBefore = UserDefaults.standard.stringArray(forKey: HomeSection.storageKey)
        let hiddenBefore = UserDefaults.standard.stringArray(forKey: HomeSection.storageKey + ".hidden")

        order.save([.moon, .hourly, .daily, .metrics,
                    .airQuality, .lifeIndex, .yesterday])
        order.saveHidden([.moon])

        // 值确实写进了注入的 suite。
        XCTAssertEqual(defaults.stringArray(forKey: HomeSection.storageKey)?.first, "moon")
        XCTAssertEqual(defaults.stringArray(forKey: HomeSection.storageKey + ".hidden"), ["moon"])

        // standard 未被触碰。
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: HomeSection.storageKey), storedBefore)
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: HomeSection.storageKey + ".hidden"), hiddenBefore)
    }
}

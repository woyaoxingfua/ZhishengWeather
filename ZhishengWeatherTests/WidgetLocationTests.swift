//
//  WidgetLocationTests.swift
//  ZhishengWeatherTests
//
//  P1-C7「当前位置」：定位结果 → 城市阶梯产出的**纯映射**（`WidgetLocationResolver`）。
//
//  为什么单列一个文件：这是本轮唯一一处「**系统 API 的结果** → 用户看到什么」的判定面。
//  真机能不能拿到定位，CI 永远验不了；但「拿到 / 没资格 / 拿不到」各自**该显示什么**
//  必须能在 CI 里钉死 —— 否则真机上只能靠肉眼判断「是不是又幽灵北京了」。
//
//  覆盖：
//    ① 拿到坐标 → `.resolved(City)`，id 走 `City.makeID`、名「当前位置」、
//       `isCurrentLocation = true`；
//    ② 未获资格 → `.locationNotAuthorized`；
//    ③ 已获资格但拿不到 → `.locationUnavailable`；
//    ④ 两态**互斥且都与 `.noCity` 不同**（Apple 第 6 点：禁止合并）；
//    ⑤ **绝不回落**：三条路径里没有一条产出北京（决策 #4）；
//    ⑥ 取点预算有界（> 0 且不超过取数硬上限）；
//    ⑦ 展示名 = AC-C14 明文的「当前位置」。
//
//  全部 guard case，无 try! / 强解包（SC-31 纪律）。
//

import XCTest
@testable import ZhishengWeather

final class WidgetLocationTests: XCTestCase {

    // MARK: - ① 拿到坐标 → 用该坐标建城（AC-C14）

    func testLocatedFixBecomesCurrentLocationCity() {
        let outcome = WidgetLocationResolver.outcome(fix: .located(latitude: 30.25,
                                                                   longitude: 120.17))

        guard let city = outcome.city else {
            return XCTFail("拿到坐标必须解析出城市（否则小组件永远空态）")
        }
        XCTAssertEqual(city.id, City.makeID(latitude: 30.25, longitude: 120.17),
                       "坐标必须经 `City.makeID` 规范化 —— 与容器 / 内置目录同一 id 口径，"
                       + "否则容器归属判定（AC-C6）永远命不中")
        XCTAssertEqual(city.latitude, 30.25, accuracy: 1e-9)
        XCTAssertEqual(city.longitude, 120.17, accuracy: 1e-9)
        XCTAssertEqual(city.name, "当前位置", "AC-C14 明文：城市名「当前位置」")
        XCTAssertTrue(city.isCurrentLocation)
        XCTAssertNil(outcome.emptyReason, "有城市 → 不是空态（应继续走取数阶梯）")
    }

    /// 时区缺省是**有意**的（不反查地名 → 不额外联网）：已知限制，不臆造。
    func testLocatedFixCarriesNoFabricatedTimeZone() {
        let outcome = WidgetLocationResolver.outcome(fix: .located(latitude: 30.25,
                                                                   longitude: 120.17))

        XCTAssertNil(outcome.city?.timeZoneIdentifier,
                     "不反地理编码 → 拿不到 IANA 时区；此处必须**留空**由设备时区兜底，"
                     + "绝不硬编码 Asia/Shanghai（那会在境外显示错的时刻）")
    }

    // MARK: - ②③ 两个空态

    func testNotAuthorizedFixYieldsActionableEmptyState() {
        let outcome = WidgetLocationResolver.outcome(fix: .notAuthorized)

        XCTAssertEqual(outcome, .locationNotAuthorized)
        XCTAssertNil(outcome.city, "未授权 → 无城市（不伪造坐标、不回落北京）")
        XCTAssertEqual(outcome.emptyReason, .locationNotAuthorized)
    }

    func testUnavailableFixYieldsHonestEmptyState() {
        let outcome = WidgetLocationResolver.outcome(fix: .unavailable)

        XCTAssertEqual(outcome, .locationUnavailable)
        XCTAssertNil(outcome.city)
        XCTAssertEqual(outcome.emptyReason, .locationUnavailable)
    }

    // MARK: - ④ 两态互斥（Apple 第 6 点）

    func testTheTwoLocationEmptyReasonsAreDistinctFromEachOtherAndFromNoCity() {
        let unauthorized = WidgetLocationResolver.outcome(fix: .notAuthorized).emptyReason
        let unavailable = WidgetLocationResolver.outcome(fix: .unavailable).emptyReason

        guard let unauthorized, let unavailable else {
            return XCTFail("两个定位空态的 emptyReason 都不得为 nil")
        }
        XCTAssertNotEqual(unauthorized, unavailable,
                          "未授权 ≠ 已授权但拿不到：用户动作不同，禁止合并成一种")
        XCTAssertNotEqual(unauthorized, .noCity,
                          "用户**已选过**「当前位置」→ 提示不能退化成「请配置城市」")
        XCTAssertNotEqual(unavailable, .noCity)
    }

    // MARK: - ⑤ 绝不回落（决策 #4 / PRD §4.7.2 实施注意）

    /// 主 App 的 `LocationProvider` 在拒绝 / 失败时回落 `.beijing`；
    /// 小组件若照搬，就是「顶着北京标题显示空态」的幽灵北京。
    func testNoLocationOutcomeEverResolvesBeijing() {
        let fixes: [WidgetLocationOutcome] = [
            .located(latitude: 30.25, longitude: 120.17),
            .notAuthorized,
            .unavailable,
        ]

        for fix in fixes {
            let outcome = WidgetLocationResolver.outcome(fix: fix)
            guard let city = outcome.city else {
                continue    // 空态本就没有城市，自然不是北京（②③ 已各自断言）
            }
            XCTAssertNotEqual(city.id, City.beijingDefault.id,
                              "定位路径绝不回落北京（北京是防御性默认城市，不是用户的城市归属）")
        }
    }

    // MARK: - ⑥ 取点预算有界

    func testFixBudgetIsBoundedAndWithinTheFetchBudgetOrder() {
        XCTAssertGreaterThan(WidgetLocationResolver.fixBudget, 0, "预算必须为正（零预算恒超时）")
        XCTAssertLessThanOrEqual(WidgetLocationResolver.fixBudget,
                                 WidgetDataResolver.fetchBudget,
                                 "定位预算不超过取数硬上限 —— 两者串联的最坏总耗时才可控")
    }

    // MARK: - ⑦ 展示名口径（与配置界面哨兵实体同源）

    func testCurrentLocationNameMatchesTheACWording() {
        XCTAssertEqual(WidgetLocationResolver.currentLocationName, "当前位置",
                       "AC-C14 明文：城市名「当前位置」；`WidgetCityEntity.currentLocation` "
                       + "也取自本常量，故改名会同时改到配置界面（有意）")
    }
}

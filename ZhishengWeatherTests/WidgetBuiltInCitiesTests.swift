//
//  WidgetBuiltInCitiesTests.swift
//  ZhishengWeatherTests
//
//  C1 内置城市目录（ARCH §7.3 / §12.1）：数量、首项复用、id 唯一、
//  无哨兵冲突、坐标合法、名称非空。
//
//  为什么必须有这些断言：内置目录是「容器永久为空」场景下选择器**唯一**的真实
//  城市来源；坐标写错 / id 撞车都会让 L1 自力取数取到**别的地方**的天气
//  ——静态检查抓不到，只有单测能兜住（P-18 纪律）。
//

import XCTest
@testable import ZhishengWeather

final class WidgetBuiltInCitiesTests: XCTestCase {

    func testCitiesCountIsExpected() {
        XCTAssertEqual(WidgetBuiltInCities.cities.count, 34,
                       "4 直辖市 + 27 省会/自治区首府 + 3 港澳台 = 34（ARCH §7.3 表）")
    }

    func testCitiesContainBeijingDefaultReusedFromSharedTruth() {
        XCTAssertTrue(WidgetBuiltInCities.cities.contains(City.beijingDefault),
                      "首项必须**复用** City.beijingDefault（不引入第二套默认坐标）")
        XCTAssertEqual(WidgetBuiltInCities.cities.first, City.beijingDefault,
                       "北京必须是第一项（展示顺序：直辖市在前）")
    }

    func testCityIDsAreUnique() {
        let ids = WidgetBuiltInCities.cities.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count,
                       "id 必须互不重复（2 位小数规范化后无碰撞，A7）")
    }

    func testNoCityIDEqualsSentinel() {
        XCTAssertFalse(WidgetBuiltInCities.cities.contains { $0.id == WidgetCityResolver.followAppID },
                       "内置城市 id 不得等于哨兵 id（否则哨兵语义被击穿）")
    }

    func testCoordinatesAreWithinValidRanges() {
        for city in WidgetBuiltInCities.cities {
            XCTAssertTrue((-90.0...90.0).contains(city.latitude),
                          "纬度越界：\(city.name) \(city.latitude)")
            XCTAssertTrue((-180.0...180.0).contains(city.longitude),
                          "经度越界：\(city.name) \(city.longitude)")
        }
    }

    func testEveryCityHasNameAndCanonicalIDRoundTrip() {
        for city in WidgetBuiltInCities.cities {
            XCTAssertFalse(city.name.isEmpty, "城市名不得为空")
            XCTAssertEqual(City.makeID(latitude: city.latitude, longitude: city.longitude),
                           city.id,
                           "id 必须是 City.makeID 的产物（往返稳定）：\(city.name)")
            XCTAssertNotNil(city.timeZoneIdentifier,
                            "内置城市必须携带 IANA 时区（异地时刻渲染用）：\(city.name)")
        }
    }
}

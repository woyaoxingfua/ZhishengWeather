//
//  WidgetBuiltInCitiesTests.swift
//  ZhishengWeatherTests
//
//  C1 内置城市目录（ARCH §7.3 / §12.1）：数量、首项**坐标同源**、id 唯一、
//  无哨兵冲突、坐标合法、名称非空、**每条都带 IANA 时区**。
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

    /// 首项必须与 App 默认北京**坐标同源**（同 lat/lon → 同 `City.makeID` id）。
    ///
    /// ⚠️ **不能**断言整值相等（如 `cities.first == City.beijingDefault`）：
    /// `City` 是**合成 `Equatable`**（`Core/Models/City.swift`），会连
    /// `timeZoneIdentifier` / `admin1` 一起比较；而 `City.beijingDefault` **按契约
    /// tz = nil**（`WeatherTimeFormatterTests` 用它验证「城市无时区 → 回退设备时区」），
    /// 本表条目则**一律携带 IANA 时区**（见下方
    /// `testEveryCityHasNameAndCanonicalIDRoundTrip`）。两条性质**逻辑上不可同时成立**
    /// —— 原先那对互相矛盾的断言正是 CI run 35214688790 的红点。
    /// 收窄到**真实不变式**：坐标同源；时区由下面那条测试独立覆盖（守卫一条没丢）。
    func testFirstCitySharesBeijingCoordinateTruth() {
        XCTAssertEqual(WidgetBuiltInCities.cities.first?.id,
                       City.beijingDefault.id,
                       "首项必须是北京**同一坐标真源**：id 由 City.makeID 从坐标派生，id 相等即坐标相等")
        XCTAssertEqual(WidgetBuiltInCities.cities.first?.name,
                       City.beijingDefault.name,
                       "首项展示名也必须与 App 默认北京同源")
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

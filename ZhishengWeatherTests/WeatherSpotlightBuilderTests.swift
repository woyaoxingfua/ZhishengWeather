//
//  WeatherSpotlightBuilderTests.swift
//  ZhishengWeatherTests
//
//  `WeatherSpotlightBuilder` / `WeatherSpotlight`（Core 纯逻辑）单测。
//
//  重点守卫两条：
//   ① **无快照不得出现温度数字**（索引是增强能力，绝不编造 —— 与 UI 侧
//      「nil → --，绝不显示 0 冒充」同一条纪律）；
//   ② **uniqueIdentifier 稳定**（不稳定会让系统索引堆条、且无法按 identifier
//      删除陈旧条目）。
//

import XCTest
@testable import ZhishengWeather

final class WeatherSpotlightBuilderTests: XCTestCase {

    // MARK: - Helpers

    /// 手工城市（带行政区，便于断言关键词）。
    private func city(_ name: String, lat: Double, lon: Double, admin1: String? = nil) -> City {
        City(name: name, latitude: lat, longitude: lon,
             isCurrentLocation: false, country: "中国", admin1: admin1)
    }

    /// 成功取到的样本快照（温度 20℃ / 天气码 1）。
    private func snapshot(temperature: Double = 20, weatherCode: Int = 1) -> WeatherSnapshot {
        WeatherSnapshot(location: .beijing,
                        temperature: temperature,
                        apparentTemperature: temperature - 1,
                        weatherCode: weatherCode,
                        windSpeed: 2,
                        windDirection: 90,
                        humidity: 50,
                        isDay: true,
                        hourly: [HourlyPoint(time: Date(),
                                             temperature: temperature,
                                             weatherCode: weatherCode)],
                        dailyHigh: 25,
                        dailyLow: 15,
                        fetchedAt: Date())
    }

    // MARK: - ① 有快照：描述含温度与天气文案

    func testItemWithSnapshotContainsTemperatureAndCondition() throws {
        let city: City = city("杭州", lat: 30.25, lon: 120.17, admin1: "浙江")
        let item: WeatherSpotlightItem = WeatherSpotlightBuilder.item(city: city,
                                                                      snapshot: snapshot(temperature: 20.4))
        let description: String = try XCTUnwrap(item.contentDescription, "有快照时应有描述")

        XCTAssertTrue(description.contains("20°C"), "描述应含真实温度，实际：\(description)")
        let condition: String = WMOCodeMapper.description(for: 1)
        XCTAssertTrue(description.contains(condition), "描述应含天气文案「\(condition)」，实际：\(description)")
    }

    func testItemsMapSnapshotsByCityID() throws {
        let hangzhou: City = city("杭州", lat: 30.25, lon: 120.17)
        let beijing: City = city("北京", lat: 39.9042, lon: 116.4074)

        let items: [WeatherSpotlightItem] = WeatherSpotlightBuilder.items(
            cities: [hangzhou, beijing],
            snapshotByCityID: [hangzhou.id: snapshot(temperature: 20)]
        )

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].cityID, hangzhou.id)
        XCTAssertEqual(items[1].cityID, beijing.id)
        let first: String = try XCTUnwrap(items[0].contentDescription)
        let second: String = try XCTUnwrap(items[1].contentDescription)
        XCTAssertTrue(first.contains("20°C"))
        // 北京无快照 → 静态文案（见下方红卫）
        XCTAssertFalse(second.contains("°C"))
    }

    // MARK: - ② 红卫：无快照不得出现温度数字

    func testItemWithoutSnapshotHasNoTemperatureDigits() throws {
        let city: City = city("北京", lat: 39.9042, lon: 116.4074, admin1: "北京")
        let item: WeatherSpotlightItem = WeatherSpotlightBuilder.item(city: city, snapshot: nil)
        let description: String = try XCTUnwrap(item.contentDescription, "无快照时给静态文案")

        let digits: [Character] = description.filter { $0.isNumber }
        XCTAssertTrue(digits.isEmpty,
                     "🔴 无快照时描述里绝不能出现任何数字（0℃ / 未知 都属编造），实际：\(description)")
        XCTAssertFalse(description.contains("°"), "无快照时不得出现温度符号，实际：\(description)")
        XCTAssertEqual(description, WeatherSpotlightBuilder.placeholderDescription)
    }

    func testItemWithoutSnapshotStillKeepsTitleAndKeywords() {
        let city: City = city("北京", lat: 39.9042, lon: 116.4074, admin1: "北京")
        let item: WeatherSpotlightItem = WeatherSpotlightBuilder.item(city: city, snapshot: nil)

        XCTAssertEqual(item.title, "北京")
        XCTAssertEqual(item.cityID, city.id)
        XCTAssertTrue(item.keywords.contains("北京"), "关键词应含城市名")
        XCTAssertTrue(item.keywords.contains("天气"), "关键词应含通用词，便于搜索命中")
    }

    func testKeywordsIncludeAdmin1WhenPresent() {
        let city: City = city("杭州", lat: 30.25, lon: 120.17, admin1: "浙江")
        let item: WeatherSpotlightItem = WeatherSpotlightBuilder.item(city: city, snapshot: nil)
        XCTAssertTrue(item.keywords.contains("浙江"), "关键词应含所属行政区（去歧义）")
    }

    // MARK: - ③ uniqueIdentifier 稳定且互不相等

    func testUniqueIdentifierIsStableAcrossBuilds() throws {
        let city: City = city("杭州", lat: 30.25, lon: 120.17)
        let first: [WeatherSpotlightItem] = WeatherSpotlightBuilder.items(
            cities: [city], snapshotByCityID: [:])
        let second: [WeatherSpotlightItem] = WeatherSpotlightBuilder.items(
            cities: [city], snapshotByCityID: [city.id: snapshot(temperature: 26)])

        XCTAssertEqual(first[0].uniqueIdentifier, second[0].uniqueIdentifier,
                       "同一城市每次生成的 identifier 必须相同（温度变了也不变）")
    }

    func testUniqueIdentifierDiffersBetweenCities() {
        let a: City = city("杭州", lat: 30.25, lon: 120.17)
        let b: City = city("北京", lat: 39.9042, lon: 116.4074)
        let items: [WeatherSpotlightItem] = WeatherSpotlightBuilder.items(
            cities: [a, b], snapshotByCityID: [:])

        XCTAssertNotEqual(items[0].uniqueIdentifier, items[1].uniqueIdentifier)
        XCTAssertTrue(items[0].uniqueIdentifier.hasPrefix(WeatherSpotlight.domainIdentifier),
                      "identifier 应带域前缀，便于按域整体删除")
    }

    func testCityIDFromUniqueIdentifierRoundTrip() throws {
        let city: City = city("杭州", lat: 30.25, lon: 120.17)
        let item: WeatherSpotlightItem = WeatherSpotlightBuilder.item(city: city, snapshot: nil)
        let parsed: String? = WeatherSpotlight.cityID(fromUniqueIdentifier: item.uniqueIdentifier)
        XCTAssertEqual(try XCTUnwrap(parsed), city.id)

        XCTAssertNil(WeatherSpotlight.cityID(fromUniqueIdentifier: "com.other.app.39.90,116.41"),
                     "非本域的 identifier 必须返回 nil，绝不返回半个字符串")
    }

    // MARK: - ④ userInfo 往返

    func testUserInfoRoundTrip() {
        let cityID: String = City.makeID(latitude: 30.25, longitude: 120.17)
        let userInfo: [AnyHashable: Any] = WeatherSpotlight.userInfo(cityID: cityID)

        XCTAssertEqual(WeatherSpotlight.cityID(fromUserInfo: userInfo), cityID)
    }

    func testUserInfoParsingRejectsNilAndWrongType() {
        XCTAssertNil(WeatherSpotlight.cityID(fromUserInfo: nil), "无 userInfo 时应返回 nil")
        XCTAssertNil(WeatherSpotlight.cityID(fromUserInfo: ["other": "39.90,116.41"]),
                     "键不匹配应返回 nil")
        XCTAssertNil(WeatherSpotlight.cityID(fromUserInfo: [
            AnyHashable("com.zhisheng.weather.cityID"): 42
        ]), "类型不是 String 时应返回 nil（绝不尝试强转后崩）")
    }

    func testActivityTitleAndTypeConstants() {
        XCTAssertEqual(WeatherSpotlight.activityTitle(cityName: "杭州"), "杭州天气")
        XCTAssertEqual(WeatherSpotlight.activityType, "com.zhisheng.weather.viewCity",
                       "🔴 变更此常量必须同步 Config/ZhishengWeather-Info.plist 的 NSUserActivityTypes")
    }
}

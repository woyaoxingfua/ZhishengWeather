//
//  WeatherActivityContentBuilderTests.swift
//  ZhishengWeatherTests
//
//  「取数成功 → ContentState 构造」纯函数单测（与 Core 的纯函数单测同款风格）：
//  温度换算 + 单位符号、WMO 码 → 中文现象名、按城市时区格式化更新时间、
//  以及「无数据字段即 nil」的诚实空态 —— 逐项锁定，不依赖 ActivityKit、不依赖活动是否在跑。
//

import XCTest
@testable import ZhishengWeather

@MainActor
final class WeatherActivityContentBuilderTests: XCTestCase {

    /// ℃ 偏好套（缺键即 celsius，与 UnitPreference 缺省一致）。
    private var celsiusSuite: UserDefaults!
    /// ℉ 偏好套（显式写 fahrenheit）。
    private var fahrenheitSuite: UserDefaults!
    /// 上海时区（固定，确定性渲染）。
    private let shanghai = TimeZone(identifier: "Asia/Shanghai") ?? .current

    override func setUp() {
        super.setUp()
        celsiusSuite = UserDefaults(suiteName: "zs.test.liveactivity.builder.celsius.\(UUID().uuidString)")
        fahrenheitSuite = UserDefaults(suiteName: "zs.test.liveactivity.builder.fahrenheit.\(UUID().uuidString)")
        // fahrenheit 套显式写入，与 celsius 套形成对照。
        fahrenheitSuite.set("fahrenheit", forKey: UnitPreference.temperatureKey)
    }

    override func tearDown() {
        celsiusSuite.removePersistentDomain(forName: celsiusSuite.persistentDomainName ?? "")
        fahrenheitSuite.removePersistentDomain(forName: fahrenheitSuite.persistentDomainName ?? "")
        super.tearDown()
    }

    /// 全量真实数据 → 四个字段都非空且文案正确。
    func testFullRealDataBuildsAllFields() {
        // 固定取数时刻，保证时区格式化结果可复现。
        let updated = Date(timeIntervalSince1970: 1_695_000_000)
        let unit = UnitPreference(defaults: celsiusSuite)
        let content = WeatherActivityContentBuilder.buildContentState(
            cityName: "北京",
            temperatureCelsius: 26,
            weatherCode: 0,
            isDay: true,
            updatedAt: updated,
            timeZone: shanghai,
            unit: unit)
        XCTAssertEqual(content.cityName, "北京")
        XCTAssertEqual(content.temperatureText, "26℃", "℃ 偏好下温度文案为 26℃")
        XCTAssertEqual(content.conditionText, "晴", "WMO 码 0 → 晴")
        XCTAssertNotNil(content.updatedAtText, "有取数时刻 → 更新时间文案非空")
        // 格式 "MM-dd HH:mm" 恒为 11 个字符（如 09-17 15:20），锁住格式不被改崩。
        XCTAssertEqual(content.updatedAtText?.count, 11)
    }

    /// 单位偏好为 ℉ 时温度换算正确（26℃ → 78.8 → 79℉）。
    func testFahrenheitConversion() {
        let unit = UnitPreference(defaults: fahrenheitSuite)
        let content = WeatherActivityContentBuilder.buildContentState(
            cityName: "北京",
            temperatureCelsius: 26,
            weatherCode: 0,
            isDay: true,
            updatedAt: nil,
            timeZone: shanghai,
            unit: unit)
        XCTAssertEqual(content.temperatureText, "79℉", "26℃ 经 ℉ 偏好换算为 79℉，与主 App 展示一致")
    }

    /// WMO 码 → 中文现象名（日/夜描述共用，与卡片一致）。
    func testWeatherCodeMapping() {
        let unit = UnitPreference(defaults: celsiusSuite)
        let overcast = WeatherActivityContentBuilder.buildContentState(
            cityName: nil, temperatureCelsius: nil, weatherCode: 3,
            isDay: true, updatedAt: nil, timeZone: shanghai, unit: unit).conditionText
        let thunder = WeatherActivityContentBuilder.buildContentState(
            cityName: nil, temperatureCelsius: nil, weatherCode: 95,
            isDay: false, updatedAt: nil, timeZone: shanghai, unit: unit).conditionText
        XCTAssertEqual(overcast, "阴")
        XCTAssertEqual(thunder, "雷阵雨")
    }

    /// 无数据字段即 nil（诚实空态，绝不填伪数据）。
    func testMissingDataYieldsNilFieldsHonestEmpty() {
        let unit = UnitPreference(defaults: celsiusSuite)
        let content = WeatherActivityContentBuilder.buildContentState(
            cityName: nil, temperatureCelsius: nil, weatherCode: nil,
            isDay: true, updatedAt: nil, timeZone: shanghai, unit: unit)
        XCTAssertNil(content.cityName)
        XCTAssertNil(content.temperatureText)
        XCTAssertNil(content.conditionText)
        XCTAssertNil(content.updatedAtText, "无取数时刻 → 更新时间文案为 nil，绝不编造")
    }
}

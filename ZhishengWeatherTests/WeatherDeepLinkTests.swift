//
//  WeatherDeepLinkTests.swift
//  ZhishengWeatherTests
//
//  `WeatherDeepLink`（Core 纯逻辑）单测：URL 生成 / 解析往返、既有 refresh
//  行为守卫、非法形态归入 .unknown。
//
//  本类标 @MainActor 只为引用 `AppRouter.refreshURLString`（既有常量，其
//  宿主类型 AppRouter 是 @MainActor）——用它做「既有 refresh 深链」的红卫
//  比再写一遍字面量更强：字面量被改、本用例会红。
//

import XCTest
@testable import ZhishengWeather

@MainActor
final class WeatherDeepLinkTests: XCTestCase {

    // MARK: - 往返（含带逗号的坐标 id）

    func testCityURLRoundTripWithCommaCoordinateID() throws {
        let cityID: String = City.makeID(latitude: 39.9042, longitude: 116.4074)
        XCTAssertEqual(cityID, "39.90,116.41", "前置：makeID 的 \"%.2f,%.2f\" 形态")

        let url: URL = try XCTUnwrap(WeatherDeepLink.url(forCityID: cityID),
                                     "坐标 id 必须能生成深链 URL")
        XCTAssertEqual(url.scheme, "zhisheng")

        let route: WeatherDeepLinkRoute = WeatherDeepLink.parse(url)
        guard case .city(let parsedID) = route else {
            XCTFail("往返解析应得到 .city，实际：\(route)")
            return
        }
        XCTAssertEqual(parsedID, cityID, "带逗号的坐标 id 编码后必须原样解回")
    }

    func testCityURLPercentEncodesTheComma() throws {
        let url: URL = try XCTUnwrap(WeatherDeepLink.url(forCityID: City.makeID(latitude: 30.25, longitude: 120.17)))
        // 逗号在 path 里必须被编码：否则不同系统对 path 的解码策略差异会让
        // id 变形（id 变形 = 切城失效）。
        XCTAssertTrue(url.absoluteString.contains("%2C"), "逗号应编码为 %2C，实际：\(url.absoluteString)")
    }

    func testCityURLWithUnencodedCommaStillParses() throws {
        // 兜底：外部（如别的系统组件）直接给未编码形态时也要能解析。
        let url: URL = try XCTUnwrap(URL(string: "zhisheng://city/39.90,116.41"))
        guard case .city(let cityID) = WeatherDeepLink.parse(url) else {
            XCTFail("未编码逗号的路径也应解析出城市 id")
            return
        }
        XCTAssertEqual(cityID, "39.90,116.41")
    }

    // MARK: - 红卫：既有 refresh 行为不得被改坏

    func testRefreshURLStillParsesAsRefresh() throws {
        let url: URL = try XCTUnwrap(URL(string: AppRouter.refreshURLString),
                                     "既有 refresh 深链常量必须仍是合法 URL")
        XCTAssertEqual(WeatherDeepLink.parse(url), .refresh,
                       "🔴 zhisheng://refresh 必须仍解析为 .refresh（既有行为）")
    }

    func testRefreshHostIgnoresPath() throws {
        let url: URL = try XCTUnwrap(URL(string: "zhisheng://refresh/whatever"))
        XCTAssertEqual(WeatherDeepLink.parse(url), .refresh,
                       "refresh 不看 path，避免新增 city 路由时被误判")
    }

    // MARK: - 非法形态 → .unknown

    func testForeignSchemeIsUnknown() throws {
        let url: URL = try XCTUnwrap(URL(string: "https://example.com/refresh"))
        XCTAssertEqual(WeatherDeepLink.parse(url), .unknown, "非 zhisheng scheme 必须忽略")
    }

    func testMissingHostIsUnknown() throws {
        let url: URL = try XCTUnwrap(URL(string: "zhisheng://"))
        XCTAssertEqual(WeatherDeepLink.parse(url), .unknown, "空 host 必须忽略")
    }

    func testUnknownHostIsUnknown() throws {
        let url: URL = try XCTUnwrap(URL(string: "zhisheng://other"))
        XCTAssertEqual(WeatherDeepLink.parse(url), .unknown, "未知 host 必须忽略（既有语义）")
    }

    func testCityWithoutIDIsUnknown() throws {
        let bare: URL = try XCTUnwrap(URL(string: "zhisheng://city"))
        XCTAssertEqual(WeatherDeepLink.parse(bare), .unknown, "city 缺 id 必须忽略")

        let slashOnly: URL = try XCTUnwrap(URL(string: "zhisheng://city/"))
        XCTAssertEqual(WeatherDeepLink.parse(slashOnly), .unknown, "city 后仅有斜杠 = 空 id")
    }
}

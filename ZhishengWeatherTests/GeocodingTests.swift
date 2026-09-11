//
//  GeocodingTests.swift
//  ZhishengWeatherTests
//
//  F-B：geocoding 链路静态用例（不联网）。
//  覆盖：endpoint 拼装（参数/中文编码/空白拒绝）、DTO 解码（无 results 键、
//        admin1/timezone 缺失）、mapper 全字段映射 + id 规范化、results nil → 空数组。
//

import XCTest
@testable import ZhishengWeather

final class GeocodingTests: XCTestCase {

    // MARK: - Endpoint

    /// URL 含 name / count=10 / language=zh / format=json。
    func testURLContainsNameCountLanguageAndFormat() throws {
        let url = try XCTUnwrap(GeocodingEndpoint.url(name: "杭州"))

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "geocoding-api.open-meteo.com")
        XCTAssertEqual(url.path, "/v1/search")

        let query = try queryItems(url)
        XCTAssertEqual(query["name"], "杭州")
        XCTAssertEqual(query["count"], "10")
        XCTAssertEqual(query["language"], "zh")
        XCTAssertEqual(query["format"], "json")
    }

    /// 中文百分号编码正确（URLQueryItem 走 URLComponents 自动编码）。
    func testURLEncodesChineseName() throws {
        let url = try XCTUnwrap(GeocodingEndpoint.url(name: "哈尔滨"))

        // 绝对串里应出现百分号编码（非原始中文裸传由 queryItems 解码侧验证）。
        XCTAssertTrue(url.absoluteString.contains("%"),
                      "中文 name 应被百分号编码：\(url.absoluteString)")

        // 解码回读必须无损。
        let query = try queryItems(url)
        XCTAssertEqual(query["name"], "哈尔滨")
    }

    /// 空白 name → nil（调用方收敛为 WeatherError.badURL）。
    func testURLReturnsNilForBlankName() {
        XCTAssertNil(GeocodingEndpoint.url(name: ""))
        XCTAssertNil(GeocodingEndpoint.url(name: "   "))
        XCTAssertNil(GeocodingEndpoint.url(name: "\n\t "))
    }

    /// 自定义 count / language 透传。
    func testURLPassesCustomCountAndLanguage() throws {
        let url = try XCTUnwrap(GeocodingEndpoint.url(name: "Milano", count: 5, language: "en"))
        let query = try queryItems(url)
        XCTAssertEqual(query["count"], "5")
        XCTAssertEqual(query["language"], "en")
    }

    // MARK: - DTO 解码

    /// 正常 results 解码。
    func testDTODecodesResults() throws {
        let json = """
        {
          "results": [
            { "name": "杭州", "latitude": 30.25, "longitude": 120.17,
              "country": "中国", "admin1": "浙江", "timezone": "Asia/Shanghai" },
            { "name": "杭州东站", "latitude": 30.29, "longitude": 120.21 }
          ]
        }
        """
        let dto = try JSONDecoder().decode(GeocodingResponse.self, from: Data(json.utf8))

        let results = try XCTUnwrap(dto.results, "results 键存在时必须解码为数组")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].name, "杭州")
        XCTAssertEqual(results[0].admin1, "浙江")
        XCTAssertEqual(results[0].timezone, "Asia/Shanghai")
    }

    /// ⚠️ 无 results 键（服务端无命中时不返回该键）→ 解码成功且 results == nil
    ///（AC-B19 数据侧：无命中 ≠ 解码失败）。
    func testDTOResultsKeyMissingDecodesAsNil() throws {
        let json = #"{"generationtime_ms": 0.5}"#
        let dto = try JSONDecoder().decode(GeocodingResponse.self, from: Data(json.utf8))

        XCTAssertNil(dto.results, "无 results 键必须解码为 nil，绝不能抛解码错误")
    }

    /// admin1 / timezone 缺失 → nil（AC-B20 数据侧）。
    func testDTOAdmin1AndTimezoneMissingDecodesAsNil() throws {
        let json = """
        { "results": [ { "name": "某地", "latitude": 1.0, "longitude": 2.0 } ] }
        """
        let dto = try JSONDecoder().decode(GeocodingResponse.self, from: Data(json.utf8))

        let place = try XCTUnwrap(dto.results?.first)
        XCTAssertNil(place.country)
        XCTAssertNil(place.admin1, "admin1 缺失必须为 nil（不得渲染 'null'）")
        XCTAssertNil(place.timezone)
    }

    // MARK: - Mapper

    /// Place → City 全字段映射 + id 规范化。
    func testMapperMapsAllFieldsAndNormalizesID() throws {
        let response = GeocodingResponse(results: [
            GeocodingResponse.Place(name: "杭州",
                                    latitude: 39.9042,
                                    longitude: 116.4074,
                                    country: "中国",
                                    admin1: "浙江",
                                    timezone: "Asia/Shanghai")
        ])

        let cities = GeocodingMapper.cities(from: response)

        XCTAssertEqual(cities.count, 1)
        let city = try XCTUnwrap(cities.first)
        XCTAssertEqual(city.id, "39.90,116.41", "id 必须经 makeID 规范化（唯一入口）")
        XCTAssertEqual(city.name, "杭州")
        XCTAssertEqual(city.latitude, 39.9042, accuracy: 1e-9)
        XCTAssertEqual(city.longitude, 116.4074, accuracy: 1e-9)
        XCTAssertEqual(city.country, "中国")
        XCTAssertEqual(city.admin1, "浙江")
        XCTAssertEqual(city.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertFalse(city.isCurrentLocation, "搜索候选一律不是'当前位置'项")
    }

    /// results nil → 空数组（空数组语义 = 无命中，交由状态机转 .empty）。
    func testMapperResultsNilProducesEmptyArray() {
        let response = GeocodingResponse(results: nil)
        XCTAssertTrue(GeocodingMapper.cities(from: response).isEmpty)
    }

    // MARK: - Helpers

    private func queryItems(_ url: URL) throws -> [String: String] {
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(components.queryItems)
        return Dictionary(items.map { ($0.name, $0.value ?? "") },
                          uniquingKeysWith: { first, _ in first })
    }
}

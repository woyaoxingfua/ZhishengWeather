//
//  AirQualityResponseTests.swift
//  ZhishengWeatherTests
//
//  空气 DTO 解码边界（不联网）：
//   - 全字段正常解码（美标 / 欧标并存）
//   - 部分字段缺失 → 该可选字段 nil，其余保留
//   - 字段显式 null → nil
//   - 响应缺 current 整键 → current == nil（上游按回退处理）
//   - 整段 JSON 为空对象 → 不抛，current == nil
//

import XCTest
@testable import ZhishengWeather

final class AirQualityResponseTests: XCTestCase {

    private let decoder: JSONDecoder = JSONDecoder()

    // MARK: - 全字段

    func testDecodesAllFieldsIncludingBothAqiStandards() throws {
        let json = """
        {
          "current": {
            "pm2_5": 30.9, "pm10": 93.1, "carbon_monoxide": 552.0,
            "nitrogen_dioxide": 18.4, "sulphur_dioxide": 4.2, "ozone": 71.0,
            "us_aqi": 78, "european_aqi": 53
          }
        }
        """.data(using: .utf8)!

        let dto = try XCTUnwrap(try decoder.decode(AirQualityResponse.self, from: json))
        let current = try XCTUnwrap(dto.current)
        XCTAssertEqual(try XCTUnwrap(current.pm2_5), 30.9, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(current.pm10), 93.1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(current.carbon_monoxide), 552.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(current.nitrogen_dioxide), 18.4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(current.sulphur_dioxide), 4.2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(current.ozone), 71.0, accuracy: 1e-9)
        XCTAssertEqual(current.us_aqi, 78)
        XCTAssertEqual(current.european_aqi, 53)
    }

    // MARK: - 部分缺失

    func testDecodesWhenSomeFieldsMissing() throws {
        // 仅给 pm2_5 与 us_aqi，其余键缺。
        let json = """
        {
          "current": { "pm2_5": 12.0, "us_aqi": 45 }
        }
        """.data(using: .utf8)!

        let current = try XCTUnwrap(try decoder.decode(AirQualityResponse.self, from: json).current)
        XCTAssertEqual(try XCTUnwrap(current.pm2_5), 12.0, accuracy: 1e-9)
        XCTAssertEqual(current.us_aqi, 45)
        XCTAssertNil(current.pm10)
        XCTAssertNil(current.carbon_monoxide)
        XCTAssertNil(current.nitrogen_dioxide)
        XCTAssertNil(current.sulphur_dioxide)
        XCTAssertNil(current.ozone)
        XCTAssertNil(current.european_aqi)
    }

    func testDecodesExplicitNullAsNil() throws {
        let json = """
        {
          "current": {
            "pm2_5": null, "pm10": null, "carbon_monoxide": null,
            "nitrogen_dioxide": null, "sulphur_dioxide": null, "ozone": null,
            "us_aqi": null, "european_aqi": null
          }
        }
        """.data(using: .utf8)!

        let current = try XCTUnwrap(try decoder.decode(AirQualityResponse.self, from: json).current)
        XCTAssertNil(current.pm2_5)
        XCTAssertNil(current.pm10)
        XCTAssertNil(current.carbon_monoxide)
        XCTAssertNil(current.nitrogen_dioxide)
        XCTAssertNil(current.sulphur_dioxide)
        XCTAssertNil(current.ozone)
        XCTAssertNil(current.us_aqi)
        XCTAssertNil(current.european_aqi)
    }

    // MARK: - 结构缺失（AC-A2-5：无结果键）

    func testMissingCurrentKeyProducesNilCurrent() throws {
        let json = "{ \"timezone\": \"Asia/Shanghai\" }".data(using: .utf8)!
        let dto = try decoder.decode(AirQualityResponse.self, from: json)
        XCTAssertNil(dto.current, "响应缺 current 整键必须映射为 nil，解码不得抛错")
    }

    func testEmptyObjectDoesNotThrow() throws {
        let json = "{}".data(using: .utf8)!
        let dto = try decoder.decode(AirQualityResponse.self, from: json)
        XCTAssertNil(dto.current)
    }
}

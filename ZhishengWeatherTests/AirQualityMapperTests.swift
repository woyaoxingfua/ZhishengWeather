//
//  AirQualityMapperTests.swift
//  ZhishengWeatherTests
//
//  空气 DTO → 领域模型映射（AC-A2-5，≥5 用例）：正常映射 / 缺 current /
//  部分字段缺失 / 负值净化 / 美标优先欧标独立。纯构造不联网。
//

import XCTest
@testable import ZhishengWeather

final class AirQualityMapperTests: XCTestCase {

    private let fullJSON = """
    {
      "current": {
        "pm2_5": 30.9, "pm10": 93.1, "carbon_monoxide": 552.0,
        "nitrogen_dioxide": 18.4, "sulphur_dioxide": 4.2, "ozone": 71.0,
        "us_aqi": 78, "european_aqi": 53
      }
    }
    """.data(using: .utf8)!

    private func decode(_ json: String) throws -> AirQualityResponse {
        try JSONDecoder().decode(AirQualityResponse.self, from: Data(json.utf8))
    }

    func testMapsAllFields() throws {
        let air = AirQualityMapper.map(try decode(fullJSON))
        XCTAssertEqual(air.usAqi, 78)
        XCTAssertEqual(air.europeanAqi, 53)
        XCTAssertEqual(try XCTUnwrap(air.pm25), 30.9, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(air.pm10), 93.1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(air.ozone), 71.0, accuracy: 1e-9)
        XCTAssertEqual(air.level, .moderate)
    }

    func testMissingCurrentBlockMapsToAllNilFields() throws {
        let air = AirQualityMapper.map(try decode("{ \"timezone\": \"UTC\" }"))
        XCTAssertNil(air.usAqi)
        XCTAssertNil(air.pm25)
        XCTAssertEqual(air.level, .unknown)
    }

    func testPartialFieldsPreservedOthersNil() throws {
        let air = AirQualityMapper.map(try decode(
            "{ \"current\": { \"pm2_5\": 12.0, \"us_aqi\": 45 } }"))
        XCTAssertEqual(try XCTUnwrap(air.pm25), 12.0, accuracy: 1e-9)
        XCTAssertEqual(air.usAqi, 45)
        XCTAssertNil(air.pm10)
        XCTAssertNil(air.ozone)
    }

    func testNegativeValuesSanitizedToNil() throws {
        // 浓度不可能为负：-5 → nil，不崩、不冒充合法读数（AC-A2-5）。
        let air = AirQualityMapper.map(try decode(
            "{ \"current\": { \"pm10\": -5.0, \"us_aqi\": -1, \"pm2_5\": 20.0 } }"))
        XCTAssertNil(air.pm10)
        XCTAssertNil(air.usAqi)
        XCTAssertEqual(try XCTUnwrap(air.pm25), 20.0, accuracy: 1e-9)
    }

    func testUsAqiDrivesLevelEuIndependent() throws {
        // 美标 40=优；欧标 120 不参与着色（Q2）。
        let air = AirQualityMapper.map(try decode(
            "{ \"current\": { \"us_aqi\": 40, \"european_aqi\": 120 } }"))
        XCTAssertEqual(air.level, .good)
        XCTAssertEqual(air.europeanAqi, 120)
    }
}

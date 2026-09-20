//
//  AirQualityMapperTests.swift
//  ZhishengWeatherTests
//
//  空气 DTO → 领域模型映射（AC-A2-5 + P2 / D-B11，≥5 用例）：
//  正常映射 / 缺 current / 部分字段缺失 / 负值净化 / 美标优先欧标独立；
//  P2 追加逐时趋势：正常映射 / 末尾 null → nil 缺口 / `0` 保留为 `0` /
//  负值净化 / 旧 JSON 无 hourly → nil / time 缺失或为空 → nil /
//  值数组短于 time → 越界为 nil / 时刻 null → 跳过 / 截到 24 条。纯构造不联网。
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
    """

    private func decode(_ json: String) throws -> AirQualityResponse {
        try JSONDecoder().decode(AirQualityResponse.self, from: Data(json.utf8))
    }

    private func air(_ json: String) throws -> AirQuality {
        AirQualityMapper.map(try decode(json))
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

    // MARK: - P2 逐时趋势（D-C4 / D-B11）

    func testMapsHourlyTrendPoints() throws {
        let result = try air("""
        {
          "hourly": {
            "time": [1789833600, 1789837200, 1789840800],
            "us_aqi": [40, 80, 165],
            "pm2_5": [10.0, 20.0, 30.0],
            "pm10": [40.0, 50.0, 60.0]
          }
        }
        """)
        let hourly = try XCTUnwrap(result.hourly)
        XCTAssertEqual(hourly.count, 3)
        XCTAssertEqual(hourly[0].usAqi, 40)
        XCTAssertEqual(hourly[1].usAqi, 80)
        XCTAssertEqual(hourly[2].usAqi, 165)
        XCTAssertEqual(try XCTUnwrap(hourly[0].pm25), 10.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(hourly[2].pm25), 30.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(hourly[1].pm10), 50.0, accuracy: 1e-9)
        // 时刻按既有 unixtime 纪律（epoch 秒）解析，步长 3600s。
        XCTAssertEqual(hourly[0].time.timeIntervalSince1970, 1_789_833_600, accuracy: 1e-3)
        XCTAssertEqual(hourly[1].time.timeIntervalSince(hourly[0].time), 3600, accuracy: 1e-3)
        XCTAssertEqual(hourly[1].id, hourly[1].time)
    }

    /// 末尾 null → 该点该字段 nil（曲线上的缺口），其余点不受影响。
    func testHourlyTrailingNullBecomesNilGap() throws {
        let result = try air("""
        {
          "hourly": {
            "time": [1789833600, 1789837200, 1789840800],
            "us_aqi": [50, 60, null],
            "pm2_5": [10.0, 20.0, null],
            "pm10": [30.0, 40.0, null]
          }
        }
        """)
        let hourly = try XCTUnwrap(result.hourly)
        XCTAssertEqual(hourly.count, 3, "缺口点仍保留（承载如实的缺口位置），不跳过")
        XCTAssertEqual(hourly[0].usAqi, 50)
        XCTAssertEqual(hourly[1].usAqi, 60)
        XCTAssertNil(hourly[2].usAqi, "末尾 null → nil，绝不补 0")
        XCTAssertNil(hourly[2].pm25)
        XCTAssertNil(hourly[2].pm10)
    }

    /// `0` 与 nil 严格区分：`0` 原样保留为 `0`，不得被净化成 nil。
    func testHourlyZeroPreservedAsZero() throws {
        let result = try air("""
        {
          "hourly": {
            "time": [1789833600, 1789837200],
            "us_aqi": [0, null],
            "pm2_5": [0.0, null],
            "pm10": [null, 0.0]
          }
        }
        """)
        let hourly = try XCTUnwrap(result.hourly)
        XCTAssertEqual(hourly[0].usAqi, 0, "0 是合法读数，必须原样保留为 0")
        XCTAssertNil(hourly[1].usAqi)
        XCTAssertEqual(try XCTUnwrap(hourly[0].pm25), 0.0, accuracy: 1e-9)
        XCTAssertNil(hourly[1].pm25)
        XCTAssertNil(hourly[0].pm10)
        XCTAssertEqual(try XCTUnwrap(hourly[1].pm10), 0.0, accuracy: 1e-9)
    }

    func testHourlyNegativeValuesSanitizedToNil() throws {
        let result = try air("""
        { "hourly": { "time": [1789833600], "us_aqi": [-1], "pm2_5": [-5.0], "pm10": [12.0] } }
        """)
        let hourly = try XCTUnwrap(result.hourly)
        XCTAssertEqual(hourly.count, 1)
        XCTAssertNil(hourly[0].usAqi)
        XCTAssertNil(hourly[0].pm25)
        XCTAssertEqual(try XCTUnwrap(hourly[0].pm10), 12.0, accuracy: 1e-9)
    }

    /// 旧 JSON（无 hourly 键）→ `air.hourly == nil`（趋势区整块隐藏，AC-B24）。
    func testMissingHourlyBlockYieldsNilHourly() throws {
        let result = try air("{ \"current\": { \"us_aqi\": 78 } }")
        XCTAssertNil(result.hourly)
        XCTAssertEqual(result.usAqi, 78, "缺逐时块不影响实况字段")
    }

    func testEmptyOrMissingTimeYieldsNilHourly() throws {
        XCTAssertNil(try air("{ \"hourly\": { \"us_aqi\": [50] } }").hourly)
        XCTAssertNil(try air("{ \"hourly\": { \"time\": [], \"us_aqi\": [] } }").hourly)
    }

    /// 只有 time、无任何值数组 → 仍产出"缺口点"（位置如实，值全 nil；
    /// UI 侧按"全无 AQI 值"整块隐藏）。
    func testTimeOnlyYieldsGapPointsWithNilValues() throws {
        let result = try air("{ \"hourly\": { \"time\": [1789833600, 1789837200] } }")
        let hourly = try XCTUnwrap(result.hourly)
        XCTAssertEqual(hourly.count, 2)
        XCTAssertNil(hourly[0].usAqi)
        XCTAssertNil(hourly[1].usAqi)
    }

    /// 值数组比 time 短 → 越界处为 nil，不崩、不串位。
    func testShorterValueArraysBecomeNilBeyondTheirLength() throws {
        let result = try air("""
        { "hourly": { "time": [1789833600, 1789837200, 1789840800], "us_aqi": [50] } }
        """)
        let hourly = try XCTUnwrap(result.hourly)
        XCTAssertEqual(hourly.count, 3)
        XCTAssertEqual(hourly[0].usAqi, 50)
        XCTAssertNil(hourly[1].usAqi)
        XCTAssertNil(hourly[2].usAqi)
    }

    /// 时刻元素 null → 跳过该点（无时刻无法定位，绝不编造时刻）。
    func testNullTimestampIsSkipped() throws {
        let result = try air("""
        { "hourly": { "time": [1789833600, null, 1789840800], "us_aqi": [50, 60, 120] } }
        """)
        let hourly = try XCTUnwrap(result.hourly)
        XCTAssertEqual(hourly.count, 2)
        XCTAssertEqual(hourly[0].usAqi, 50)
        XCTAssertEqual(hourly[1].usAqi, 120, "跳过的点不得让后续值串位")
    }

    /// 服务端忽略 `forecast_hours`、套用 120h 默认窗口时，mapper 仍截到 24 条。
    func testHourlyTruncatedToTwentyFourPoints() throws {
        let times = (0..<30).map { String(1_789_833_600 + $0 * 3600) }
        let values = (0..<30).map { String(40 + $0) }
        let json = """
        { "hourly": { "time": [\(times.joined(separator: ","))],
                      "us_aqi": [\(values.joined(separator: ","))] } }
        """
        let hourly = try XCTUnwrap(try air(json).hourly)
        XCTAssertEqual(hourly.count, 24, "必须截到 24 条（与端点 forecast_hours=24 一致）")
        XCTAssertEqual(try XCTUnwrap(hourly.first).usAqi, 40)
        XCTAssertEqual(try XCTUnwrap(hourly.last).usAqi, 63)
        XCTAssertEqual(AirQualityMapper.maxHourlyAQICount, 24)
    }
}

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
//  P2 修订（D-B11）追加逐时块 `hourly` 的解码边界：
//   - 整键可选（旧 JSON 无 hourly → nil，解码不抛）
//   - **元素可选**：末尾 null 元素必须容忍（真机事故：元素非可选 → 整包解码失败）
//   - `0` 解码为 `0`，与 null 严格区分
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
        XCTAssertNil(dto.hourly, "P2 逐时块缺键同样为 nil")
    }

    // MARK: - P2 逐时块（D-B11）
    //
    //  实测形态（2026-09-20 探针，forecast_hours=24）：time/us_aqi/pm2_5/pm10
    //  等长 24 条，time 为 epoch 秒、步长 3600s。

    func testDecodesHourlyBlock() throws {
        let json = """
        {
          "current": { "us_aqi": 100 },
          "hourly": {
            "time": [1789833600, 1789837200, 1789840800],
            "us_aqi": [50, 60, 120],
            "pm2_5": [10.5, 20.0, 30.25],
            "pm10": [40.0, 50.0, 60.0]
          }
        }
        """.data(using: .utf8)!

        let dto = try decoder.decode(AirQualityResponse.self, from: json)
        let hourly = try XCTUnwrap(dto.hourly)
        let times = try XCTUnwrap(hourly.time)
        XCTAssertEqual(times.count, 3)
        XCTAssertEqual(times[0], 1_789_833_600, "time 必须是 epoch 秒（timeformat=unixtime）")
        XCTAssertEqual(times[1], 1_789_837_200, "步长 3600s")
        let aqi = try XCTUnwrap(hourly.us_aqi)
        XCTAssertEqual(aqi.count, 3)
        XCTAssertEqual(aqi[0], 50)
        XCTAssertEqual(aqi[1], 60)
        XCTAssertEqual(aqi[2], 120)
        let pm25 = try XCTUnwrap(hourly.pm2_5)
        let pm10 = try XCTUnwrap(hourly.pm10)
        XCTAssertEqual(try XCTUnwrap(pm25[2]), 30.25, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(pm10[0]), 40.0, accuracy: 1e-9)
    }

    /// ★ 末尾 null 容忍（本仓库真机事故）：逐时**值数组末位为 null**（默认 120 小时
    /// 窗口的尾段实测就是 null）→ 整包解码**必须成功**，该元素为 nil、其余元素不受影响。
    /// 修复前元素写成非可选会让合成解码器抛错，主屏与小组件同时无数据。
    func testHourlyTrailingNullElementDecodesWithoutThrowing() throws {
        let json = """
        {
          "current": { "us_aqi": 100 },
          "hourly": {
            "time": [1789833600, 1789837200, 1789840800],
            "us_aqi": [50, 60, null],
            "pm2_5": [10.0, 20.0, null],
            "pm10": [30.0, 40.0, null]
          }
        }
        """.data(using: .utf8)!

        let dto = try decoder.decode(AirQualityResponse.self, from: json)
        let hourly = try XCTUnwrap(dto.hourly)
        let aqi = try XCTUnwrap(hourly.us_aqi)
        XCTAssertEqual(aqi.count, 3, "null 元素不得改变数组长度")
        XCTAssertEqual(aqi[0], 50, "前段元素不受末尾 null 影响")
        XCTAssertEqual(aqi[1], 60)
        XCTAssertNil(aqi[2], "末尾 null 元素必须解码为 nil（元素非可选会整包解码失败）")
        let pm25 = try XCTUnwrap(hourly.pm2_5)
        let pm10 = try XCTUnwrap(hourly.pm10)
        XCTAssertNil(pm25[2])
        XCTAssertNil(pm10[2])
        XCTAssertEqual(try XCTUnwrap(dto.current).us_aqi, 100, "实况块不受逐时 null 影响")
    }

    /// `0` 是合法读数，必须解码为 `0`，**绝不与 null 混淆**。
    func testHourlyZeroDecodesAsZeroNotNil() throws {
        let json = """
        {
          "hourly": {
            "time": [1789833600, 1789837200],
            "us_aqi": [0, null],
            "pm2_5": [0.0, null],
            "pm10": [null, 0.0]
          }
        }
        """.data(using: .utf8)!

        let hourly = try XCTUnwrap(try decoder.decode(AirQualityResponse.self, from: json).hourly)
        let aqi = try XCTUnwrap(hourly.us_aqi)
        XCTAssertEqual(aqi[0], 0, "0 必须解码为 0 而非 nil")
        XCTAssertNil(aqi[1], "null 必须为 nil")
        let pm25 = try XCTUnwrap(hourly.pm2_5)
        let pm10 = try XCTUnwrap(hourly.pm10)
        XCTAssertEqual(try XCTUnwrap(pm25[0]), 0.0, accuracy: 1e-9)
        XCTAssertNil(pm25[1])
        XCTAssertNil(pm10[0])
        XCTAssertEqual(try XCTUnwrap(pm10[1]), 0.0, accuracy: 1e-9)
    }

    /// 旧 JSON（不含任何新键）解码必须成功，新字段全 nil（向后兼容）。
    func testLegacyJSONWithoutHourlyDecodesWithNilHourly() throws {
        let json = """
        { "current": { "pm2_5": 30.9, "us_aqi": 78 } }
        """.data(using: .utf8)!
        let dto = try decoder.decode(AirQualityResponse.self, from: json)
        XCTAssertNil(dto.hourly, "旧响应无 hourly 键 → nil，不得抛错")
        XCTAssertEqual(try XCTUnwrap(dto.current).us_aqi, 78)
    }

    func testHourlyEmptyObjectDecodesToAllNilKeys() throws {
        let json = "{ \"hourly\": {} }".data(using: .utf8)!
        let hourly = try XCTUnwrap(try decoder.decode(AirQualityResponse.self, from: json).hourly)
        XCTAssertNil(hourly.time)
        XCTAssertNil(hourly.us_aqi)
        XCTAssertNil(hourly.pm2_5)
        XCTAssertNil(hourly.pm10)
    }

    func testHourlyExplicitNullValuesDecodeToNilArrays() throws {
        let json = """
        { "hourly": { "time": null, "us_aqi": null, "pm2_5": null, "pm10": null } }
        """.data(using: .utf8)!
        let hourly = try XCTUnwrap(try decoder.decode(AirQualityResponse.self, from: json).hourly)
        XCTAssertNil(hourly.time)
        XCTAssertNil(hourly.us_aqi)
        XCTAssertNil(hourly.pm2_5)
        XCTAssertNil(hourly.pm10)
    }
}

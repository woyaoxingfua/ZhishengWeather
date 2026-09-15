//
//  OpenMeteoDecodingTests.swift
//  ZhishengWeatherTests
//
//  内联 JSON 解码 + 映射为 WeatherSnapshot 的字段对齐校验（不联网）。
//  覆盖：daily 存在 / 缺失 / 为空 / 长度不足；数组长度不齐；hourly 为空；
//        timezone=auto + unixtime 语义；截窗（12 条上限、首项=now）。
//

import XCTest
@testable import ZhishengWeather

final class OpenMeteoDecodingTests: XCTestCase {

    /// 测试基准时刻（epoch 秒）。
    private let baseEpoch = 1_700_000_000

    // MARK: - 解码 + 字段对齐

    func testDecodeAndMapFields() throws {
        let dto = try decode(includeDaily: true)
        let now = Date(timeIntervalSince1970: TimeInterval(baseEpoch))
        let snapshot = OpenMeteoMapper.map(dto, location: .beijing, now: now)

        XCTAssertEqual(snapshot.location.name, "北京")
        XCTAssertEqual(snapshot.temperature, 23.4, accuracy: 0.001)
        XCTAssertEqual(snapshot.apparentTemperature, 21.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.weatherCode, 2)
        XCTAssertEqual(snapshot.humidity, 58)
        XCTAssertEqual(snapshot.windSpeed, 3.2, accuracy: 0.001)
        XCTAssertEqual(snapshot.windDirection, 135.0, accuracy: 0.001)
        XCTAssertTrue(snapshot.isDay)
        XCTAssertEqual(snapshot.fetchedAt, now)
    }

    func testDecodesTimezoneAndUTCOffset() throws {
        let dto = try decode(includeDaily: true)
        XCTAssertEqual(dto.timezone, "Asia/Shanghai")
        XCTAssertEqual(dto.utc_offset_seconds, 28_800)
    }

    /// `timeformat=unixtime`：时间字段为 epoch 秒，映射后应等于对应绝对时刻。
    func testUnixtimeSemanticsProduceAbsoluteInstants() throws {
        let dto = try decode(includeDaily: true)
        XCTAssertEqual(dto.current.time, baseEpoch)
        XCTAssertEqual(dto.hourly.time.first, baseEpoch - 3 * 3_600)

        let snapshot = OpenMeteoMapper.map(dto, location: .beijing,
                                           now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))
        // 窗口首项应为「当前小时」的 epoch 绝对时刻
        let first = try XCTUnwrap(snapshot.hourly.first)
        XCTAssertEqual(first.time.timeIntervalSince1970, Double(baseEpoch), accuracy: 0.5)
    }

    // MARK: - daily 高低温（v1.1）

    func testDailyHighLowFromDaily() throws {
        let snapshot = try map(includeDaily: true)
        XCTAssertEqual(snapshot.dailyHigh, 26.1, accuracy: 0.001)
        XCTAssertEqual(snapshot.dailyLow, 15.2, accuracy: 0.001)
    }

    func testMissingDailyFallsBackToHourlyWindow() throws {
        let dto = try decode(includeDaily: false)
        XCTAssertNil(dto.daily)

        let snapshot = OpenMeteoMapper.map(dto, location: .beijing,
                                           now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))

        let expectedHigh = snapshot.hourly.map(\.temperature).max() ?? .nan
        let expectedLow = snapshot.hourly.map(\.temperature).min() ?? .nan
        XCTAssertEqual(snapshot.dailyHigh, expectedHigh, accuracy: 0.0001)
        XCTAssertEqual(snapshot.dailyLow, expectedLow, accuracy: 0.0001)
        XCTAssertFalse(snapshot.hourly.isEmpty)
    }

    func testDailyWithEmptyArraysFallsBackToHourlyWindow() throws {
        let dto = try decode(json: Self.makeJSON(baseEpoch: baseEpoch, daily: .empty))
        let snapshot = OpenMeteoMapper.map(dto, location: .beijing,
                                           now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))
        let expectedHigh = snapshot.hourly.map(\.temperature).max() ?? .nan
        let expectedLow = snapshot.hourly.map(\.temperature).min() ?? .nan
        XCTAssertEqual(snapshot.dailyHigh, expectedHigh, accuracy: 0.0001)
        XCTAssertEqual(snapshot.dailyLow, expectedLow, accuracy: 0.0001)
    }

    func testDailyWithShortArraysFallsBackIndependently() throws {
        // temperature_2m_min 为空 → 低温回退；max 有值 → 采用 30.0
        let dto = try decode(json: Self.makeJSON(baseEpoch: baseEpoch, daily: .shortMaxOnly))
        let snapshot = OpenMeteoMapper.map(dto, location: .beijing,
                                           now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))
        XCTAssertEqual(snapshot.dailyHigh, 30.0, accuracy: 0.0001)
        let expectedLow = snapshot.hourly.map(\.temperature).min() ?? .nan
        XCTAssertEqual(snapshot.dailyLow, expectedLow, accuracy: 0.0001)
    }

    // MARK: - 逐小时截窗

    func testHourlyWindowStartsAtNowAndCapsAtTwentyFour() throws {
        let dto = try decode(includeDaily: true)
        let now = Date(timeIntervalSince1970: TimeInterval(baseEpoch))
        let snapshot = OpenMeteoMapper.map(dto, location: .beijing, now: now)

        // 数据源覆盖 [base-3h, base+20h] 共 24 点，now=base → 窗口 = base..base+20h
        // 共 21 点（不足 24 按实际渲染，AC-A1-5）。
        XCTAssertEqual(snapshot.hourly.count, 21)
        XCTAssertEqual(snapshot.hourly.first?.time, now)
        XCTAssertEqual(snapshot.hourly.last?.time,
                       Date(timeIntervalSince1970: TimeInterval(baseEpoch + 20 * 3_600)))
    }

    // MARK: - 数组长度不齐 / hourly 为空

    func testMismatchedArrayLengthsDoNotCrash() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai",
          "utc_offset_seconds": 28800,
          "current": { "time": 1700000000, "temperature_2m": 20.0, "relative_humidity_2m": 50,
                       "apparent_temperature": 19.0, "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 0 },
          "hourly": { "time": [1700000000, 1700003600], "temperature_2m": [20.0], "weather_code": [1, 1] },
          "daily": null
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        let snapshot = OpenMeteoMapper.map(dto, location: .beijing,
                                           now: Date(timeIntervalSince1970: 1_700_000_000))
        // 三数组最小长度为 1，故截窗后仅 1 个点；不崩溃。
        XCTAssertEqual(snapshot.hourly.count, 1)
        XCTAssertFalse(snapshot.isDay)
        XCTAssertEqual(snapshot.dailyHigh, 20.0, accuracy: 0.0001)
    }

    func testEmptyHourlyDecodesAndMapsSafely() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai",
          "utc_offset_seconds": 28800,
          "current": { "time": 1700000000, "temperature_2m": 20.0, "relative_humidity_2m": 50,
                       "apparent_temperature": 19.0, "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1 },
          "hourly": { "time": [], "temperature_2m": [], "weather_code": [] },
          "daily": { "time": [1700000000], "temperature_2m_max": [26.1], "temperature_2m_min": [15.2] }
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        let snapshot = OpenMeteoMapper.map(dto, location: .beijing,
                                           now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(snapshot.hourly.isEmpty)
        // hourly 为空也不应崩溃，高低温仍可取自 daily
        XCTAssertEqual(snapshot.dailyHigh, 26.1, accuracy: 0.0001)
        XCTAssertEqual(snapshot.dailyLow, 15.2, accuracy: 0.0001)
    }

    // MARK: - F-A 逐日 DTO 解码

    /// 完整 5 数组 daily → 解码成功且字段齐全（含 null 元素 → [Int?] 的 nil）。
    func testDailyBlockWithAllFiveArraysDecodes() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai",
          "utc_offset_seconds": 28800,
          "current": { "time": 1700000000, "temperature_2m": 20.0, "relative_humidity_2m": 50,
                       "apparent_temperature": 19.0, "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1 },
          "hourly": { "time": [1700000000], "temperature_2m": [20.0], "weather_code": [1] },
          "daily": {
            "time": [1700000000, 1700086400, 1700172800],
            "temperature_2m_max": [26.1, 24.0, 25.5],
            "temperature_2m_min": [15.2, 14.0, 13.5],
            "weather_code": [0, 61, 3],
            "precipitation_probability_max": [10, 80, null]
          }
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        let daily = try XCTUnwrap(dto.daily)
        XCTAssertEqual(daily.time.count, 3)
        XCTAssertEqual(daily.temperature_2m_max, [26.1, 24.0, 25.5])
        XCTAssertEqual(daily.temperature_2m_min, [15.2, 14.0, 13.5])
        XCTAssertEqual(daily.weather_code, [0, 61, 3])

        let precip = try XCTUnwrap(daily.precipitation_probability_max)
        XCTAssertEqual(precip[0], 10)
        XCTAssertEqual(precip[1], 80)
        XCTAssertNil(precip[2], "JSON null 元素必须解码为 nil（AC-A5）")
    }

    /// precipitation_probability_max 整键缺失 → 解码为 nil（不炸、不连累其他字段）。
    func testDailyWithoutPrecipitationKeyDecodes() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai",
          "utc_offset_seconds": 28800,
          "current": { "time": 1700000000, "temperature_2m": 20.0, "relative_humidity_2m": 50,
                       "apparent_temperature": 19.0, "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1 },
          "hourly": { "time": [1700000000], "temperature_2m": [20.0], "weather_code": [1] },
          "daily": {
            "time": [1700000000],
            "temperature_2m_max": [26.1],
            "temperature_2m_min": [15.2],
            "weather_code": [0]
          }
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        let daily = try XCTUnwrap(dto.daily)
        XCTAssertNil(daily.precipitation_probability_max,
                     "precip 整键缺失必须解码为 nil")
        XCTAssertEqual(daily.weather_code, [0])
    }

    /// daily 无 weather_code 键 → 键级可选，整个响应解码成功（偏差备案 D-1 的目标）。
    func testDailyWeatherCodeKeyMissingStillDecodes() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai",
          "utc_offset_seconds": 28800,
          "current": { "time": 1700000000, "temperature_2m": 20.0, "relative_humidity_2m": 50,
                       "apparent_temperature": 19.0, "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1 },
          "hourly": { "time": [1700000000], "temperature_2m": [20.0], "weather_code": [1] },
          "daily": {
            "time": [1700000000],
            "temperature_2m_max": [26.1],
            "temperature_2m_min": [15.2],
            "precipitation_probability_max": [10]
          }
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        let daily = try XCTUnwrap(dto.daily)
        XCTAssertNil(daily.weather_code, "weather_code 键缺失必须解码为 nil（D-1）")
        XCTAssertEqual(daily.precipitation_probability_max, [10])
    }

    // MARK: - A1 DTO 解码（pressure 双键 / sunrise/sunset 字符串）

    /// pressure 双键齐全 → 解码成功且值透传（D-A1）。
    func testCurrentPressureKeysDecode() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai",
          "utc_offset_seconds": 28800,
          "current": { "time": 1700000000, "temperature_2m": 20.0, "relative_humidity_2m": 50,
                       "apparent_temperature": 19.0, "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1,
                       "pressure_msl": 1013.2, "surface_pressure": 1008.7 },
          "hourly": { "time": [1700000000], "temperature_2m": [20.0], "weather_code": [1] },
          "daily": null
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        XCTAssertEqual(dto.current.pressure_msl ?? -1, 1013.2, accuracy: 0.001)
        XCTAssertEqual(dto.current.surface_pressure ?? -1, 1008.7, accuracy: 0.001)

        let snapshot = OpenMeteoMapper.map(dto, location: .beijing,
                                           now: Date(timeIntervalSince1970: 1_700_000_000))
        // mapper 回退语义：msl 优先（ARCH-A1 §1.1）。
        XCTAssertEqual(snapshot.pressureMSL ?? -1, 1013.2, accuracy: 0.001)
    }

    /// pressure 键缺失 → 解码成功（不炸）且 snapshot.pressureMSL == nil（不冒充 0）。
    func testCurrentPressureKeysMissingDecodeSafely() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai",
          "utc_offset_seconds": 28800,
          "current": { "time": 1700000000, "temperature_2m": 20.0, "relative_humidity_2m": 50,
                       "apparent_temperature": 19.0, "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1 },
          "hourly": { "time": [1700000000], "temperature_2m": [20.0], "weather_code": [1] },
          "daily": null
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        XCTAssertNil(dto.current.pressure_msl)
        XCTAssertNil(dto.current.surface_pressure)

        let snapshot = OpenMeteoMapper.map(dto, location: .beijing,
                                           now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(snapshot.pressureMSL, "双键均缺失 → nil（AC-A1-3：-- 而非 0）")
    }

    /// pressure 仅 msl 缺 → mapper 回退 surface（AC-A1-1 fallback 语义）。
    func testPressureFallsBackToSurfaceWhenMSLMissing() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai",
          "utc_offset_seconds": 28800,
          "current": { "time": 1700000000, "temperature_2m": 20.0, "relative_humidity_2m": 50,
                       "apparent_temperature": 19.0, "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1,
                       "pressure_msl": null, "surface_pressure": 1008.7 },
          "hourly": { "time": [1700000000], "temperature_2m": [20.0], "weather_code": [1] },
          "daily": null
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        let snapshot = OpenMeteoMapper.map(dto, location: .beijing,
                                           now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(snapshot.pressureMSL ?? -1, 1008.7, accuracy: 0.001,
                       "msl 为 null 时必须回退 surface_pressure")
    }

    /// daily.sunrise/sunset 正常解码为 String 数组（DTO 只存 String，A1-4 铁律 4）。
    func testDailySunriseSunsetDecodeAsStrings() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai",
          "utc_offset_seconds": 28800,
          "current": { "time": 1700000000, "temperature_2m": 20.0, "relative_humidity_2m": 50,
                       "apparent_temperature": 19.0, "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1 },
          "hourly": { "time": [1700000000], "temperature_2m": [20.0], "weather_code": [1] },
          "daily": {
            "time": [1700000000, 1700086400],
            "temperature_2m_max": [26.1, 24.0],
            "temperature_2m_min": [15.2, 14.0],
            "weather_code": [0, 1],
            "sunrise": ["2026-09-11T05:53", "2026-09-12T05:54"],
            "sunset": ["2026-09-11T18:22", null]
          }
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        let daily = try XCTUnwrap(dto.daily)
        XCTAssertEqual(daily.sunrise?.first, "2026-09-11T05:53")
        XCTAssertNil(daily.sunset?[1], "sunset null 元素必须解码为 nil（极地日期形态）")

        // mapper 注入：今日行的字符串经 ISOTimeStringDecoder 解码为 Date。
        let snapshot = OpenMeteoMapper.map(dto, location: .beijing,
                                           now: Date(timeIntervalSince1970: TimeInterval(1_700_000_000)))
        XCTAssertNotNil(snapshot.sunrise, "今日行 sunrise 字符串合法 → 解码出 Date")
        XCTAssertNotNil(snapshot.sunset)
    }

    /// daily.sunrise 整键缺失 → 解码成功（不炸）且 snapshot.sunrise == nil。
    func testDailySunriseKeyMissingDecodesSafely() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai",
          "utc_offset_seconds": 28800,
          "current": { "time": 1700000000, "temperature_2m": 20.0, "relative_humidity_2m": 50,
                       "apparent_temperature": 19.0, "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1 },
          "hourly": { "time": [1700000000], "temperature_2m": [20.0], "weather_code": [1] },
          "daily": {
            "time": [1700000000],
            "temperature_2m_max": [26.1],
            "temperature_2m_min": [15.2]
          }
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        let snapshot = OpenMeteoMapper.map(dto, location: .beijing,
                                           now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(snapshot.sunrise)
        XCTAssertNil(snapshot.sunset)
    }

    /// sunrise 坏串 → snapshot.sunrise == nil（不炸、不冒充，AC-A1-12 降级面）。
    func testDailySunriseMalformedStringYieldsNilSnapshotSunrise() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai",
          "utc_offset_seconds": 28800,
          "current": { "time": 1700000000, "temperature_2m": 20.0, "relative_humidity_2m": 50,
                       "apparent_temperature": 19.0, "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1 },
          "hourly": { "time": [1700000000], "temperature_2m": [20.0], "weather_code": [1] },
          "daily": {
            "time": [1700000000],
            "temperature_2m_max": [26.1],
            "temperature_2m_min": [15.2],
            "sunrise": ["not-a-date"],
            "sunset": ["2026-09-11T18:22"]
          }
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        let snapshot = OpenMeteoMapper.map(dto, location: .beijing,
                                           now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(snapshot.sunrise, "坏串必须映射为 nil（UI 隐藏该段）")
        XCTAssertNotNil(snapshot.sunset, "好串不受坏串影响")
    }

    // MARK: - Helpers

    /// `includeDaily == false` 时写 `"daily": null`（模拟服务端未返回 daily）。
    private func decode(includeDaily: Bool) throws -> OpenMeteoResponse {
        let json = Self.makeJSON(baseEpoch: baseEpoch, daily: includeDaily ? .present : .none)
        return try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
    }

    private func decode(json: String) throws -> OpenMeteoResponse {
        try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
    }

    private func map(includeDaily: Bool) throws -> WeatherSnapshot {
        let dto = try decode(includeDaily: includeDaily)
        return OpenMeteoMapper.map(dto, location: .beijing,
                                   now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))
    }

    private enum DailyMode { case present, empty, shortMaxOnly, none }

    /// 生成内联 JSON：hourly 覆盖 [base-3h, base+20h] 共 24 条，便于验证截窗。
    private static func makeJSON(baseEpoch: Int, daily: DailyMode) -> String {
        let times = (0..<24).map { baseEpoch - 3 * 3_600 + $0 * 3_600 }
        let temperatures = (0..<24).map { 20.0 + Double($0) * 0.1 }
        let codes = (0..<24).map { $0 % 3 }

        let timeJSON = "[" + times.map(String.init).joined(separator: ",") + "]"
        let tempJSON = "[" + temperatures.map { String(format: "%.1f", $0) }.joined(separator: ",") + "]"
        let codeJSON = "[" + codes.map(String.init).joined(separator: ",") + "]"

        let dailyJSON: String
        switch daily {
        case .present:
            dailyJSON = #"{"time": [\#(baseEpoch)], "temperature_2m_max": [26.1], "temperature_2m_min": [15.2]}"#
        case .empty:
            dailyJSON = #"{"time": [], "temperature_2m_max": [], "temperature_2m_min": []}"#
        case .shortMaxOnly:
            dailyJSON = #"{"time": [\#(baseEpoch)], "temperature_2m_max": [30.0], "temperature_2m_min": []}"#
        case .none:
            dailyJSON = "null"
        }

        return """
        {
          "timezone": "Asia/Shanghai",
          "utc_offset_seconds": 28800,
          "current": {
            "time": \(baseEpoch),
            "temperature_2m": 23.4,
            "relative_humidity_2m": 58,
            "apparent_temperature": 21.0,
            "weather_code": 2,
            "wind_speed_10m": 3.2,
            "wind_direction_10m": 135.0,
            "is_day": 1
          },
          "hourly": { "time": \(timeJSON), "temperature_2m": \(tempJSON), "weather_code": \(codeJSON) },
          "daily": \(dailyJSON)
        }
        """
    }

    /// A2-2：daily.uv_index_max 解码（元素/整键可选，null → nil）。
    func testDecodesUvIndexMaxOptionalArrays() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai", "utc_offset_seconds": 28800,
          "current": { "time": 1700000000, "temperature_2m": 20.0,
                       "relative_humidity_2m": 50, "apparent_temperature": 19.0,
                       "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1 },
          "hourly": { "time": [1700000000], "temperature_2m": [20.0], "weather_code": [1] },
          "daily": { "time": [1699958400],
                     "temperature_2m_max": [26.0], "temperature_2m_min": [15.0],
                     "weather_code": null, "precipitation_probability_max": null,
                     "sunrise": null, "sunset": null,
                     "uv_index_max": [7.5, null] }
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: json.data(using: .utf8)!)
        let uv = try XCTUnwrap(dto.daily?.uv_index_max)
        XCTAssertEqual(uv[0], 7.5)
        XCTAssertNil(uv[1])
    }

    /// A2-2：daily 整键缺 uv_index_max → nil（服务端未返回不炸）。
    func testMissingUvIndexMaxKeyDecodesAsNil() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai", "utc_offset_seconds": 28800,
          "current": { "time": 1700000000, "temperature_2m": 20.0,
                       "relative_humidity_2m": 50, "apparent_temperature": 19.0,
                       "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1 },
          "hourly": { "time": [1700000000], "temperature_2m": [20.0], "weather_code": [1] }
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: json.data(using: .utf8)!)
        XCTAssertNil(dto.daily)
    }
}

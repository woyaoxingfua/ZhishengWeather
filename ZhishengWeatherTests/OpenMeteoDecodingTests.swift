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
        // v1.6：DTO 数组元素已改为可选，显式声明字面量类型以锁死"元素值不变"。
        XCTAssertEqual(daily.temperature_2m_max, [26.1, 24.0, 25.5] as [Double?])
        XCTAssertEqual(daily.temperature_2m_min, [15.2, 14.0, 13.5] as [Double?])
        let weatherCodes = try XCTUnwrap(daily.weather_code)
        XCTAssertEqual(weatherCodes, [0, 61, 3] as [Int?])

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
        let weatherCodes = try XCTUnwrap(daily.weather_code)
        XCTAssertEqual(weatherCodes, [0] as [Int?])
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

    /// daily.sunrise/sunset 支持 **ISO 字符串形态**（run37 起 DTO 为 FlexibleTime，
    /// 部分部署仍可能返回 ISO 墙钟字符串；真机主流形态见 epoch 用例）。
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
        XCTAssertEqual(sunTime(daily.sunrise)?.isoString, "2026-09-11T05:53")
        XCTAssertEqual(sunTime(daily.sunset)?.isoString, "2026-09-11T18:22")
        XCTAssertNil(sunTime(daily.sunset, at: 1), "sunset null 元素必须解码为 nil（极地日期形态）")

        // mapper 注入：今日行的字符串经 ISOTimeStringDecoder 解码为 Date。
        let snapshot = OpenMeteoMapper.map(dto, location: .beijing,
                                           now: Date(timeIntervalSince1970: TimeInterval(1_700_000_000)))
        XCTAssertNotNil(snapshot.sunrise, "今日行 sunrise 字符串合法 → 解码出 Date")
        XCTAssertNotNil(snapshot.sunset)
    }

    /// ★ 真机回归（run37）：`timeformat=unixtime` 下 API 返回 epoch 数字，
    /// DTO 双态容忍解码必须通过，并归一为正确 Date。
    /// 修复前该 JSON 直接抛 typeMismatch → 真机 100% 报"格式问题"。
    func testEpochFormSunriseDecodesAndMaps() throws {
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
            "weather_code": [0],
            "sunrise": [1789422908],
            "sunset": [1789472520]
          }
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        let daily = try XCTUnwrap(dto.daily)
        XCTAssertEqual(sunTime(daily.sunrise)?.epochSeconds, 1_789_422_908,
                       "epoch 数字必须解为 .epoch，而非解码失败")
        XCTAssertEqual(sunTime(daily.sunset)?.epochSeconds, 1_789_472_520)

        let snapshot = OpenMeteoMapper.map(dto, location: .beijing,
                                           now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(snapshot.sunrise, Date(timeIntervalSince1970: 1_789_422_908),
                       "epoch 直译，不做 +8h 位移")
        XCTAssertEqual(snapshot.sunset, Date(timeIntervalSince1970: 1_789_472_520))
    }

    /// 混合形态：数组内首元素 epoch、次元素 ISO 字符串——逐元素独立判定。
    func testMixedFormSunTimesDecodePerElement() throws {
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
            "sunrise": [1789422908],
            "sunset": ["2026-09-11T18:22"]
          }
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        let daily = try XCTUnwrap(dto.daily)
        XCTAssertEqual(sunTime(daily.sunrise)?.epochSeconds, 1_789_422_908)
        XCTAssertEqual(sunTime(daily.sunset)?.isoString, "2026-09-11T18:22")
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

    /// 取 `[FlexibleTime?]?` 指定下标的元素（默认首个）。
    ///
    /// ⚠️ **双层可选陷阱**：DTO 里 sunrise/sunset 是 `[FlexibleTime?]?`
    /// （数组可缺 + 元素可 null），故 `times.first` 的类型是
    /// `FlexibleTime??`。直接写 `times.first?.isoString` 只能解一层，
    /// **编译失败**（`value of optional type 'FlexibleTime?' must be
    /// unwrapped`）——CI run35 实测教训。统一走本助手返回扁平 `FlexibleTime?`。
    private func sunTime(_ times: [FlexibleTime?]?, at index: Int = 0) -> FlexibleTime? {
        guard let times, times.indices.contains(index) else { return nil }
        return times[index]
    }

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

    // MARK: - B1 遥测字段（visibility / dew_point_2m / cloud_cover / wind_gusts_10m）

    /// B1：四字段齐全 → 解码 + 映射透传。
    func testCurrentB1TelemetryFieldsDecodeAndMap() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai", "utc_offset_seconds": 28800,
          "current": { "time": 1700000000, "temperature_2m": 20.0,
                       "relative_humidity_2m": 50, "apparent_temperature": 19.0,
                       "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1,
                       "visibility": 16000.0, "dew_point_2m": 8.5,
                       "cloud_cover": 42, "wind_gusts_10m": 7.5 },
          "hourly": { "time": [1700000000], "temperature_2m": [20.0], "weather_code": [1] },
          "daily": null
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        let snapshot = OpenMeteoMapper.map(dto, location: .beijing,
                                           now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(snapshot.visibility ?? -1, 16000.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.dewPoint ?? -1, 8.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.cloudCover ?? -1, 42.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.windGusts ?? -1, 7.5, accuracy: 0.001)
    }

    /// B1：四键整键缺失 → 解码成功（不炸）且映射为 nil（"绝不显示 0"）。
    func testMissingB1TelemetryKeysDecodeAndMapToNil() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai", "utc_offset_seconds": 28800,
          "current": { "time": 1700000000, "temperature_2m": 20.0,
                       "relative_humidity_2m": 50, "apparent_temperature": 19.0,
                       "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1 },
          "hourly": { "time": [1700000000], "temperature_2m": [20.0], "weather_code": [1] },
          "daily": null
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        let snapshot = OpenMeteoMapper.map(dto, location: .beijing,
                                           now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(snapshot.visibility, "缺键 → nil（UI 显示 --，不冒充 0）")
        XCTAssertNil(snapshot.dewPoint)
        XCTAssertNil(snapshot.cloudCover)
        XCTAssertNil(snapshot.windGusts)
    }

    // MARK: - B1-2 短时降水 DTO 解码 + 映射

    /// minutely_15 块齐全 → 解码成功 + 映射为窗口点（自当前窗起）。
    /// 真机实测形态：键名 time / precipitation / precipitation_probability；
    /// time 为 epoch 秒（900s 间隔）；概率元素可为 null。
    func testMinutely15BlockDecodesAndMaps() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai", "utc_offset_seconds": 28800,
          "current": { "time": 1700000000, "temperature_2m": 20.0,
                       "relative_humidity_2m": 50, "apparent_temperature": 19.0,
                       "weather_code": 61, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1 },
          "hourly": { "time": [1700000000], "temperature_2m": [20.0], "weather_code": [61] },
          "daily": null,
          "minutely_15": {
            "time": [1700000000, 1700000900, 1700001800, 1700002700],
            "precipitation": [0.0, 1.2, 0.4, 0.0],
            "precipitation_probability": [0, 80, 60, null]
          }
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        let block = try XCTUnwrap(dto.minutely_15)
        XCTAssertEqual(block.time.count, 4)
        XCTAssertEqual(block.precipitation?[1], 1.2)
        XCTAssertNil(block.precipitation_probability?[3], "null 元素必须解码为 nil")

        let snapshot = OpenMeteoMapper.map(dto, location: .beijing,
                                           now: Date(timeIntervalSince1970: 1_700_000_000))
        let points = try XCTUnwrap(snapshot.minutely15)
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(points.first?.precipitation ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(points[1].precipitation, 1.2, accuracy: 1e-9)
        XCTAssertNil(points.last?.probability, "概率 null → nil（不冒充 0）")
    }

    /// minutely_15 整块缺失 → dto.minutely_15 与 snapshot.minutely15 均为 nil（不连累主链路解码）。
    func testMinutely15KeyMissingDecodesToNilSnapshot() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai", "utc_offset_seconds": 28800,
          "current": { "time": 1700000000, "temperature_2m": 20.0,
                       "relative_humidity_2m": 50, "apparent_temperature": 19.0,
                       "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1 },
          "hourly": { "time": [1700000000], "temperature_2m": [20.0], "weather_code": [1] },
          "daily": null
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        XCTAssertNil(dto.minutely_15)
        let snapshot = OpenMeteoMapper.map(dto, location: .beijing,
                                           now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(snapshot.minutely15, "块缺失 → nil（短时降水卡整卡隐藏，AC-B1-9）")
    }
}

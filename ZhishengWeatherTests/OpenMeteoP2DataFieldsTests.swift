//
//  OpenMeteoP2DataFieldsTests.swift
//  ZhishengWeatherTests
//
//  P2 数据补全（用户诉求"补全数据吧…先把天气做好吧"）单测。
//  覆盖：Endpoint 新字段出现在 URL、末尾 null 容忍、0 与 nil 不可混淆、
//  旧缓存兼容（不含新键的旧 JSON 解码成功且新字段全 nil）、mapper 搬运。
//
//  纪律红线：0 是合法值（UI 显示 "0 mm"），只有 null 才转 nil（UI 显示 "--"）。
//  Core 两个 target 共用，本文件不联网、不依赖时序。
//

import XCTest
@testable import ZhishengWeather

final class OpenMeteoP2DataFieldsTests: XCTestCase {

    private let baseEpoch = 1_700_000_000

    // MARK: - 1. Endpoint 新字段出现在 URL（不新增 query 参数，配额仍 ×1）

    func testEndpointCurrentContainsP2Fields() throws {
        let url = try XCTUnwrap(OpenMeteoEndpoint.url(latitude: 0, longitude: 0))
        let current = try XCTUnwrap(try queryItems(url)["current"])
        let fields = current.split(separator: ",").map(String.init)
        for field in ["precipitation", "rain", "showers", "snowfall", "uv_index"] {
            XCTAssertTrue(fields.contains(field), "current 缺少 P2 字段 \(field)，实际=\(current)")
        }
    }

    func testEndpointHourlyContainsP2Fields() throws {
        let url = try XCTUnwrap(OpenMeteoEndpoint.url(latitude: 0, longitude: 0))
        let hourly = try XCTUnwrap(try queryItems(url)["hourly"])
        let fields = hourly.split(separator: ",").map(String.init)
        for field in ["precipitation", "wind_speed_10m", "wind_gusts_10m", "apparent_temperature"] {
            XCTAssertTrue(fields.contains(field), "hourly 缺少 P2 字段 \(field)，实际=\(hourly)")
        }
    }

    func testEndpointDailyContainsP2Fields() throws {
        let url = try XCTUnwrap(OpenMeteoEndpoint.url(latitude: 0, longitude: 0))
        let daily = try XCTUnwrap(try queryItems(url)["daily"])
        let fields = daily.split(separator: ",").map(String.init)
        for field in ["precipitation_sum", "rain_sum", "snowfall_sum", "wind_speed_10m_max",
                      "wind_gusts_10m_max", "wind_direction_10m_dominant", "daylight_duration",
                      "sunshine_duration", "apparent_temperature_max", "apparent_temperature_min"] {
            XCTAssertTrue(fields.contains(field), "daily 缺少 P2 字段 \(field)，实际=\(daily)")
        }
    }

    /// 加字段不新增第二个请求：current / hourly / daily 各只出现一次。
    func testEndpointP2FieldsShareSingleRequest() throws {
        let url = try XCTUnwrap(OpenMeteoEndpoint.url(latitude: 0, longitude: 0))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(items.filter { $0.name == "current" }.count, 1)
        XCTAssertEqual(items.filter { $0.name == "hourly" }.count, 1)
        XCTAssertEqual(items.filter { $0.name == "daily" }.count, 1)
    }

    // MARK: - 2. 末尾 null 容忍（本轮最高风险点，真机崩溃同源）

    /// hourly 新增数组字段尾段 null：解码必须成功，对应点该字段为 nil，其余点不为 nil。
    func testHourlyNewFieldTrailingNullsDecodeAndMap() throws {
        let dto = try decodeResponse(
            hourlyTimes: (0..<6).map { baseEpoch + $0 * 3_600 },
            hourlyTemps: [20.0, 21.0, 22.0, 23.0, 24.0, 25.0],
            hourlyCodes: [1, 1, 1, 1, 1, 1],
            hourlyPrecipitation: [0.0, 1.5, 2.0, nil, nil, 0.0]
        )

        // 解码层：长度仍为 6，尾段 null 如实为 nil，非末尾 0 保留。
        let hourly = dto.hourly
        XCTAssertEqual(hourly.precipitation?.count, 6, "null 元素不计为缺项，长度仍为 6")
        XCTAssertEqual(hourly.precipitation?[0], 0.0, accuracy: 1e-9, "下标 0 为 0，是合法值")
        XCTAssertNil(hourly.precipitation?[3], "下标 3 为 null → nil")
        XCTAssertNil(hourly.precipitation?[4], "下标 4 为 null → nil")
        XCTAssertEqual(hourly.precipitation?[5], 0.0, accuracy: 1e-9, "末尾 0 仍是 0，不是 null")

        let snapshot = OpenMeteoMapper.map(dto,
                                          location: .beijing,
                                          now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))
        XCTAssertEqual(snapshot.hourly.count, 6, "温度/现象码齐全 → 6 行全保留")
        XCTAssertEqual(snapshot.hourly[0].precipitation, 0.0, accuracy: 1e-9, "0 不能转 nil")
        XCTAssertEqual(snapshot.hourly[1].precipitation, 1.5, accuracy: 1e-9)
        XCTAssertNil(snapshot.hourly[3].precipitation, "null 元素 → 该点该字段 nil")
        XCTAssertNil(snapshot.hourly[4].precipitation)
        XCTAssertEqual(snapshot.hourly[5].precipitation, 0.0, accuracy: 1e-9)
    }

    /// daily 新增数组字段末行 null：解码成功、末行对应字段为 nil、非末行 0 保留。
    func testDailyNewFieldTrailingNullsDecodeAndMap() throws {
        let dto = try decodeResponse(
            hourlyTimes: [baseEpoch], hourlyTemps: [20.0], hourlyCodes: [1],
            dailyJSON: """
            {
              "time": [\(baseEpoch), \(baseEpoch + 86_400), \(baseEpoch + 2 * 86_400)],
              "temperature_2m_max": [27.0, 26.0, 25.0],
              "temperature_2m_min": [17.0, 16.0, 15.0],
              "weather_code": [2, 3, 1],
              "precipitation_sum": [0.0, 5.5, null],
              "wind_speed_10m_max": [3.0, 4.0, null],
              "daylight_duration": [43200.0, 43000.0, null]
            }
            """
        )

        let daily = try XCTUnwrap(dto.daily)
        XCTAssertNil(daily.precipitation_sum?[2], "末行 null → nil")
        XCTAssertNil(daily.wind_speed_10m_max?[2])
        XCTAssertNil(daily.daylight_duration?[2])
        XCTAssertEqual(daily.precipitation_sum?[0], 0.0, accuracy: 1e-9, "非末行 0 保留")
        XCTAssertEqual(daily.daylight_duration?[0], 43200.0, accuracy: 1e-9, "秒原值透传")

        let snapshot = OpenMeteoMapper.map(dto,
                                          location: .beijing,
                                          now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))
        let list = try XCTUnwrap(snapshot.daily)
        XCTAssertEqual(list.count, 3, "末行必需字段齐全 → 不丢弃，只是新字段为 nil")
        XCTAssertEqual(list[0].precipitationSum, 0.0, accuracy: 1e-9, "0 mm 合法值")
        XCTAssertEqual(list[1].precipitationSum, 5.5, accuracy: 1e-9)
        XCTAssertEqual(list[1].windSpeedMax, 4.0, accuracy: 1e-9)
        XCTAssertEqual(list[0].daylightDuration, 43200.0, accuracy: 1e-9)
        XCTAssertNil(list[2].precipitationSum, "末行 null → 该字段 nil")
        XCTAssertNil(list[2].windSpeedMax)
        XCTAssertNil(list[2].daylightDuration)
    }

    // MARK: - 3. 0 与 nil 不可混淆（实况四降水键 + UV）

    func testCurrentPrecipitationZeroPreservedNotNil() throws {
        let dto = try decodeResponse(
            hourlyTimes: [baseEpoch], hourlyTemps: [20.0], hourlyCodes: [1],
            currentExtra: ", \"precipitation\": 0.0, \"rain\": 0.0, \"showers\": 0.0, \"snowfall\": 0.0, \"uv_index\": 3.5"
        )
        let snapshot = OpenMeteoMapper.map(dto,
                                          location: .beijing,
                                          now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))
        XCTAssertEqual(snapshot.precipitation, 0.0, accuracy: 1e-9, "0 mm 是合法值，不是 nil")
        XCTAssertEqual(snapshot.rain, 0.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.showers, 0.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.snowfall, 0.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.uvIndex, 3.5, accuracy: 1e-9)
    }

    func testCurrentPrecipitationNilWhenAbsent() throws {
        // 服务端整组省略四降水键（或旧缓存）→ 全 nil，绝不合成 0.0。
        let dto = try decodeResponse(
            hourlyTimes: [baseEpoch], hourlyTemps: [20.0], hourlyCodes: [1]
        )
        let snapshot = OpenMeteoMapper.map(dto,
                                          location: .beijing,
                                          now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))
        XCTAssertNil(snapshot.precipitation)
        XCTAssertNil(snapshot.rain)
        XCTAssertNil(snapshot.showers)
        XCTAssertNil(snapshot.snowfall)
        XCTAssertNil(snapshot.uvIndex)
    }

    // MARK: - 4. 旧缓存兼容（不含任何新键的旧 JSON 解码必须成功，新字段全 nil）

    func testOldCacheWithoutNewKeysDecodesAndMapsToNil() throws {
        // 模拟旧版写盘：current 无四降水/uv，hourly 无 precipitation，daily 无新增字段。
        let dto = try decodeResponse(
            hourlyTimes: (0..<3).map { baseEpoch + $0 * 3_600 },
            hourlyTemps: [20.0, 21.0, 22.0],
            hourlyCodes: [1, 1, 1],
            dailyJSON: """
            {
              "time": [\(baseEpoch), \(baseEpoch + 86_400)],
              "temperature_2m_max": [27.0, 26.0],
              "temperature_2m_min": [17.0, 16.0],
              "weather_code": [2, 3]
            }
            """
        )

        // 解码层新字段全为 nil（整键缺失）。
        XCTAssertNil(dto.current.precipitation)
        XCTAssertNil(dto.current.uv_index)
        XCTAssertNil(dto.hourly.precipitation)
        XCTAssertNil(dto.daily?.precipitation_sum)
        XCTAssertNil(dto.daily?.daylight_duration)

        let snapshot = OpenMeteoMapper.map(dto,
                                          location: .beijing,
                                          now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))
        XCTAssertNil(snapshot.precipitation)
        XCTAssertNil(snapshot.uvIndex)
        XCTAssertNil(snapshot.hourly.first?.precipitation)
        let list = try XCTUnwrap(snapshot.daily)
        XCTAssertNil(list[0].precipitationSum)
        XCTAssertNil(list[0].daylightDuration)
        XCTAssertNil(list[0].windSpeedMax)
    }

    // MARK: - Helpers

    private func queryItems(_ url: URL) throws -> [String: String] {
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(components.queryItems)
        return Dictionary(items.map { ($0.name, $0.value ?? "") },
                          uniquingKeysWith: { first, _ in first })
    }

    /// 解码一份内联 JSON；hourly 数组元素可为 null（真机截断日形态）。
    /// - currentExtra：拼在 current 对象末尾的额外键值（带前导逗号），用于注入 P2 实况字段。
    /// - hourlyPrecipitation：注入 hourly.precipitation（末尾 null 容忍用例）。
    private func decodeResponse(hourlyTimes: [Int],
                                hourlyTemps: [Double?],
                                hourlyCodes: [Int?],
                                hourlyPrecipitation: [Double?]? = nil,
                                currentExtra: String = "",
                                dailyJSON: String? = nil) throws -> OpenMeteoResponse {
        let dailySegment: String = {
            guard let dailyJSON else { return "" }
            return ",\n  \"daily\": \(dailyJSON)"
        }()
        let hourlyExtras: [String] = {
            var parts: [String] = []
            if let hp = hourlyPrecipitation {
                parts.append("\"precipitation\": \(jsonArray(hp))")
            }
            return parts
        }()
        let hourlyExtraBody = hourlyExtras.isEmpty ? "" : ", " + hourlyExtras.joined(separator: ", ")
        let json = """
        {
          "timezone": "Asia/Shanghai",
          "utc_offset_seconds": 28800,
          "current": { "time": \(baseEpoch), "temperature_2m": 19.0, "relative_humidity_2m": 50,
                       "apparent_temperature": 18.0, "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1\(currentExtra) },
          "hourly": { "time": \(jsonArray(hourlyTimes)),
                      "temperature_2m": \(jsonArray(hourlyTemps)),
                      "weather_code": \(jsonArray(hourlyCodes))\(hourlyExtraBody) }\(dailySegment)
        }
        """
        return try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
    }

    private func jsonArray(_ values: [Double?]) -> String {
        "[" + values.map { $0.map { String($0) } ?? "null" }.joined(separator: ", ") + "]"
    }

    private func jsonArray(_ values: [Int?]) -> String {
        "[" + values.map { $0.map { String($0) } ?? "null" }.joined(separator: ", ") + "]"
    }

    private func jsonArray(_ values: [Int]) -> String {
        "[" + values.map { String($0) }.joined(separator: ", ") + "]"
    }
}

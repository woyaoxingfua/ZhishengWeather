//
//  OpenMeteoNullToleranceTests.swift
//  ZhishengWeatherTests
//
//  null 容忍红卫测试（v1.6）：锁死「Open-Meteo 返回 null 元素不得拖垮整包解码」。
//
//  真机背景（北京 39.9042,116.4074，forecast_days=16 + past_days=1，
//  请求参数与 `Core/Networking/OpenMeteoEndpoint.swift` 逐字相同）：
//    · hourly 408 条，其中**下标 399..407（共 9 条）**的 temperature_2m 与
//      weather_code 为 null（第 16 天是"截断日"，只填到下午）；
//    · daily 17 行，**下标 16** 的 temperature_2m_max / _min / weather_code /
//      uv_index_max 全为 null。
//  修复前 DTO 声明成 `[Double]` / `[Int]`，合成解码器遇 null 直接抛
//  DecodingError，codingPath 形如 `hourly.temperature_2m.Index 399` ——
//  **整包解码失败**，主屏无数据、WidgetKit 小组件也无数据（Core 两个 target 共用）。
//
//  本文件的用例按真机形态等比缩放（不联网、不依赖时序），覆盖：
//   a) 逐小时尾段 null → 解码必须成功，且 mapper 跳过 null 行（含"只有一个为 null"）；
//   b) daily 截断日整行 null → 解码成功、整行丢弃、todayIndex 落空时走回退链；
//   c) 昨日行含 null → yesterday == nil。
//

import XCTest
@testable import ZhishengWeather

final class OpenMeteoNullToleranceTests: XCTestCase {

    /// 测试基准时刻（epoch 秒），即"当前小时"。
    private let baseEpoch = 1_700_000_000

    // MARK: - a) 逐小时 null 元素

    /// 真机崩溃的**直接回归用例**：hourly 尾段 9 有效 + 3 null，
    /// 解码必须成功（修复前在此抛 DecodingError → 主屏/小组件全空）。
    func testHourlyTrailingNullsDecodeSuccessfully() throws {
        let dto = try decodeResponse(
            hourlyTimes: (0..<12).map { baseEpoch + $0 * 3_600 },
            // 三类不对称形态（真机是"温度与现象码同时 null"，这里刻意拆开，
            // 证明跳过判据是"任一为 null"而非"两者同时缺失"）：
            //   下标 9 ：温度 null + 现象码有值(5)
            //   下标 10：温度有值(26.0) + 现象码 null
            //   下标 11：两者皆 null
            hourlyTemps: [20.0, 20.5, 21.0, 21.5, 22.0, 22.5, 23.0, 23.5, 24.0, nil, 26.0, nil],
            hourlyCodes: [1, 1, 2, 2, 3, 3, 1, 1, 2, 5, nil, nil]
        )

        XCTAssertEqual(dto.hourly.time.count, 12)
        XCTAssertEqual(dto.hourly.temperature_2m.count, 12, "null 元素不计为缺项，长度仍为 12")
        XCTAssertEqual(dto.hourly.weather_code.count, 12)
        // 元素级 null 必须如实解码为 nil，不得被静默填 0。
        XCTAssertNil(dto.hourly.temperature_2m[9], "下标 9 温度为 null")
        XCTAssertNil(dto.hourly.temperature_2m[11], "下标 11 温度为 null")
        XCTAssertNil(dto.hourly.weather_code[10], "下标 10 现象码为 null")
        XCTAssertNil(dto.hourly.weather_code[11], "下标 11 现象码为 null")
        // 下标 9：温度 null 但现象码**有值** —— 用于证明跳过是"任一为 null"触发，
        // 而非两边同时缺失才跳过。
        XCTAssertNotNil(dto.hourly.weather_code[9], "下标 9 的现象码有值，只有温度为 null")
        XCTAssertNotNil(dto.hourly.temperature_2m[10], "下标 10 的温度有值，只有现象码为 null")
    }

    /// mapper 侧：null 行不构造 HourlyPoint（温度或现象码任一为 null 即跳过），
    /// 且不得编造 0℃ / 0（晴）。
    func testMapperSkipsHourlyRowsWithAnyNullElement() throws {
        let dto = try decodeResponse(
            hourlyTimes: (0..<12).map { baseEpoch + $0 * 3_600 },
            // 三类不对称形态（真机是"温度与现象码同时 null"，这里刻意拆开，
            // 证明跳过判据是"任一为 null"而非"两者同时缺失"）：
            //   下标 9 ：温度 null + 现象码有值(5)
            //   下标 10：温度有值(26.0) + 现象码 null
            //   下标 11：两者皆 null
            hourlyTemps: [20.0, 20.5, 21.0, 21.5, 22.0, 22.5, 23.0, 23.5, 24.0, nil, 26.0, nil],
            hourlyCodes: [1, 1, 2, 2, 3, 3, 1, 1, 2, 5, nil, nil]
        )

        let snapshot = OpenMeteoMapper.map(dto,
                                          location: .beijing,
                                          now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))

        XCTAssertEqual(snapshot.hourly.count, 9, "12 行里 3 行含 null → 只出 9 个点，不补 0")
        let expectedTimes: [Date] = (0..<9).map {
            Date(timeIntervalSince1970: TimeInterval(baseEpoch + $0 * 3_600))
        }
        XCTAssertEqual(snapshot.hourly.map(\.time), expectedTimes,
                       "null 行必须整行消失，后续有效行不得前移错位")
        XCTAssertEqual(try XCTUnwrap(snapshot.hourly.first).temperature, 20.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(snapshot.hourly.last).temperature, 24.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(snapshot.hourly.last).weatherCode, 2)
    }

    // MARK: - b) daily 截断日整行 null

    /// daily 最后一行（截断日）max / min / weather_code 全 null：
    /// 解码成功，且该行被整行丢弃、前面的行完整保留。
    func dailyWithTruncatedLastRow() throws -> OpenMeteoResponse {
        try decodeResponse(
            hourlyTimes: [baseEpoch],
            hourlyTemps: [18.0],
            hourlyCodes: [1],
            dailyJSON: """
            {
              "time": [\(baseEpoch), \(baseEpoch + 86_400), \(baseEpoch + 2 * 86_400)],
              "temperature_2m_max": [27.0, 26.0, null],
              "temperature_2m_min": [17.0, 16.0, null],
              "weather_code": [2, 3, null]
            }
            """
        )
    }

    func testDailyTruncatedLastRowDecodesSuccessfully() throws {
        let dto = try dailyWithTruncatedLastRow()
        let daily = try XCTUnwrap(dto.daily)
        XCTAssertEqual(daily.time.count, 3)
        XCTAssertNil(daily.temperature_2m_max[2], "截断日最高温必须是 nil，不是 0")
        XCTAssertNil(daily.temperature_2m_min[2], "截断日最低温必须是 nil，不是 0")
        let codes = try XCTUnwrap(daily.weather_code)
        XCTAssertNil(codes[2], "截断日现象码必须是 nil，不得冒充 0（晴）")
    }

    func testDailyTruncatedLastRowIsDroppedByMapper() throws {
        let dto = try dailyWithTruncatedLastRow()
        let snapshot = OpenMeteoMapper.map(dto,
                                          location: .beijing,
                                          now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))

        let list = try XCTUnwrap(snapshot.daily)
        XCTAssertEqual(list.count, 2, "截断日整行丢弃，其前 2 行完整保留")
        XCTAssertEqual(list[0].tempMax, 27.0, accuracy: 1e-9)
        XCTAssertEqual(list[0].tempMin, 17.0, accuracy: 1e-9)
        XCTAssertEqual(list[0].weatherCode, 2)
        XCTAssertEqual(list[1].tempMax, 26.0, accuracy: 1e-9)
        XCTAssertEqual(list[1].weatherCode, 3)
        let droppedDate = Date(timeIntervalSince1970: TimeInterval(baseEpoch + 2 * 86_400))
        XCTAssertFalse(list.contains { $0.date == droppedDate }, "null 行不得出现在逐日结果中")
    }

    /// todayIndex 落在 null 行 → dailyHigh / dailyLow 走既有回退链
    /// （hourly 窗口 → current），不得写入 nil / 0。
    func testDailyHighLowFallBackWhenTodayRowIsNull() throws {
        let dto = try decodeResponse(
            hourlyTimes: [baseEpoch, baseEpoch + 3_600],
            hourlyTemps: [18.0, 22.0],
            hourlyCodes: [1, 1],
            dailyJSON: """
            {
              "time": [\(baseEpoch - 86_400), \(baseEpoch)],
              "temperature_2m_max": [31.0, null],
              "temperature_2m_min": [21.0, null],
              "weather_code": [1, null]
            }
            """
        )
        let snapshot = OpenMeteoMapper.map(dto,
                                          location: .beijing,
                                          now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))

        // todayIndex = 1（今日行）且该行为 null → 回退到 hourly 窗口的 max / min。
        XCTAssertEqual(snapshot.dailyHigh, 22.0, accuracy: 1e-9,
                       "今日行 null → 回退 hourly 窗口最高温（不得取昨天的 31°、也不得为 0）")
        XCTAssertEqual(snapshot.dailyLow, 18.0, accuracy: 1e-9,
                       "今日行 null → 回退 hourly 窗口最低温")
        XCTAssertEqual(snapshot.daily, [], "今日行 null → 逐日无有效行（空数组，非 nil）")
    }

    // MARK: - c) 昨日行含 null

    /// 昨日行最高温为 null → yesterday 整行隐藏（nil），今日数据不受影响。
    func testYesterdayIsNilWhenItsTempMaxIsNull() throws {
        let dto = try decodeResponse(
            hourlyTimes: [baseEpoch],
            hourlyTemps: [18.0],
            hourlyCodes: [1],
            dailyJSON: """
            {
              "time": [\(baseEpoch - 86_400), \(baseEpoch)],
              "temperature_2m_max": [null, 27.0],
              "temperature_2m_min": [21.0, 17.0],
              "weather_code": [1, 2]
            }
            """
        )
        let snapshot = OpenMeteoMapper.map(dto,
                                          location: .beijing,
                                          now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))

        XCTAssertNil(snapshot.yesterday, "昨日行含 null → 整行 nil（AC-A1-16，不冒充）")
        XCTAssertEqual(snapshot.dailyHigh, 27.0, accuracy: 1e-9, "今日行完好，不受昨日 null 连累")
    }

    /// 昨日行现象码为 null（温度齐全）→ 同样整行隐藏，证明判据是"任一为 null"。
    func testYesterdayIsNilWhenItsWeatherCodeIsNull() throws {
        let dto = try decodeResponse(
            hourlyTimes: [baseEpoch],
            hourlyTemps: [18.0],
            hourlyCodes: [1],
            dailyJSON: """
            {
              "time": [\(baseEpoch - 86_400), \(baseEpoch)],
              "temperature_2m_max": [31.0, 27.0],
              "temperature_2m_min": [21.0, 17.0],
              "weather_code": [null, 2]
            }
            """
        )
        let snapshot = OpenMeteoMapper.map(dto,
                                          location: .beijing,
                                          now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))

        XCTAssertNil(snapshot.yesterday, "昨日现象码 null → 整行 nil（与 dailyForecasts 同判据）")
        XCTAssertEqual(snapshot.dailyHigh, 27.0, accuracy: 1e-9)
    }

    // MARK: - Helpers

    /// 解码一份内联 JSON 响应；hourly 数组元素可为 null（真机形态）。
    private func decodeResponse(hourlyTimes: [Int],
                                hourlyTemps: [Double?],
                                hourlyCodes: [Int?],
                                dailyJSON: String? = nil) throws -> OpenMeteoResponse {
        let dailySegment: String = {
            guard let dailyJSON else { return "" }
            return ",\n  \"daily\": \(dailyJSON)"
        }()
        let json = """
        {
          "timezone": "Asia/Shanghai",
          "utc_offset_seconds": 28800,
          "current": { "time": \(baseEpoch), "temperature_2m": 19.0, "relative_humidity_2m": 50,
                       "apparent_temperature": 18.0, "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1 },
          "hourly": { "time": \(jsonArray(hourlyTimes)),
                      "temperature_2m": \(jsonArray(hourlyTemps)),
                      "weather_code": \(jsonArray(hourlyCodes)) }\(dailySegment)
        }
        """
        return try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
    }

    /// 渲染 JSON 数组字面量：非 nil 元素原样输出，nil 输出 `null`。
    private func jsonArray(_ values: [Double?]) -> String {
        let body: [String] = values.map { value -> String in
            guard let value else { return "null" }
            return String(value)
        }
        return "[" + body.joined(separator: ", ") + "]"
    }

    /// 渲染 JSON 数组字面量（整型版）。
    private func jsonArray(_ values: [Int?]) -> String {
        let body: [String] = values.map { value -> String in
            guard let value else { return "null" }
            return String(value)
        }
        return "[" + body.joined(separator: ", ") + "]"
    }

    private func jsonArray(_ values: [Int]) -> String {
        let body: [String] = values.map { value -> String in String(value) }
        return "[" + body.joined(separator: ", ") + "]"
    }
}

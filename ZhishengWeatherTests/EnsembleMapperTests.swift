//
//  EnsembleMapperTests.swift
//  ZhishengWeatherTests
//
//  Ensemble DTO → 领域模型映射（纯函数）：
//   - 成员键正则 `_member\d{2}$` 动态匹配、控制成员/其它变量排除；
//   - time 墙钟字符串按 utc_offset_seconds 解释为绝对时刻（UTC 分量断言，独立于实现）；
//   - 负值/非有限值净化 → nil。
//

import XCTest
@testable import ZhishengWeather

final class EnsembleMapperTests: XCTestCase {

    private func decode(_ json: String) throws -> EnsembleResponse {
        try JSONDecoder().decode(EnsembleResponse.self, from: Data(json.utf8))
    }

    func testMapsMemberSeriesExcludesControlAndOtherVariables() throws {
        let json = """
        {
          "utc_offset_seconds": 28800,
          "hourly": {
            "time": ["2026-09-16T00:00", "2026-09-16T01:00"],
            "precipitation": [0.0, 0.0],
            "temperature_2m": [5.0, 6.0],
            "precipitation_member01": [0.0, 0.2],
            "precipitation_member02": [0.5, 0.5]
          }
        }
        """
        let forecast = EnsembleMapper.map(try decode(json))
        XCTAssertEqual(forecast.memberCount, 2, "仅两个 _memberNN 计入")
        XCTAssertEqual(forecast.times.count, 2)
        XCTAssertEqual(try XCTUnwrap(forecast.memberSeries[0][1]), 0.2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(forecast.memberSeries[1][0]), 0.5, accuracy: 1e-9)
    }

    func testTimesDecodedViaUTCOffsetToAbsoluteInstant() throws {
        // "2026-09-16T00:00" 在 UTC+8 下 = UTC 2026-09-15 16:00。
        // 用独立路径（Calendar + UTC 时区）断言绝对时刻，不复用实现的字符串解析。
        let json = """
        {
          "utc_offset_seconds": 28800,
          "hourly": {
            "time": ["2026-09-16T00:00", "2026-09-16T01:00"],
            "precipitation_member01": [0.0, 0.0]
          }
        }
        """
        let forecast = EnsembleMapper.map(try decode(json))
        let first = try XCTUnwrap(forecast.times.first)

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = utcCalendar.dateComponents([.year, .month, .day, .hour], from: first)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 9)
        XCTAssertEqual(components.day, 15)
        XCTAssertEqual(components.hour, 16)

        // 相邻两点相差 3600 秒。
        XCTAssertEqual(forecast.times[1].timeIntervalSince(first), 3600, accuracy: 0.5)
    }

    func testNegativeAndNonFiniteValuesSanitizedToNil() throws {
        // 降水不可能为负：负值 → nil（不冒充合法读数）；0 为合法值保留。
        let json = """
        {
          "hourly": {
            "time": ["2026-09-16T00:00"],
            "precipitation_member01": [-5.0],
            "precipitation_member02": [0.0]
          }
        }
        """
        let forecast = EnsembleMapper.map(try decode(json))
        XCTAssertNil(forecast.memberSeries[0][0], "负值应净化为 nil")
        XCTAssertEqual(try XCTUnwrap(forecast.memberSeries[1][0]), 0.0, accuracy: 1e-9,
                       "0 是合法降水值，必须保留")
    }

    func testUnparseableTimeYieldsEmptyTimesButKeepsMembers() throws {
        // 时刻字符串损坏 → 该时刻丢弃（times 收缩），成员序列仍产出（引擎按越界守卫处理）。
        let json = """
        {
          "hourly": {
            "time": ["not-a-time"],
            "precipitation_member01": [0.3],
            "precipitation_member02": [0.6]
          }
        }
        """
        let forecast = EnsembleMapper.map(try decode(json))
        XCTAssertTrue(forecast.times.isEmpty)
        XCTAssertEqual(forecast.memberCount, 2)
    }
}

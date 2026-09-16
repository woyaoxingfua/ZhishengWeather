//
//  ArchiveServiceTests.swift
//  ZhishengWeatherTests
//
//  历史天气链路（A3-1）：DTO 解码边界 / Endpoint 请求面 / Mapper 映射。
//  纯构造不联网；期望值先手算（run12 教训）。
//

import XCTest
@testable import ZhishengWeather

final class ArchiveServiceTests: XCTestCase {

    // MARK: - DTO 解码

    func testDecodesFullArchiveResponse() throws {
        let json = """
        {
          "daily": {
            "time": ["2026-09-01", "2026-09-02"],
            "temperature_2m_max": [31.0, 28.5],
            "temperature_2m_min": [21.0, 19.0],
            "weather_code": [1, 3],
            "precipitation_sum": [0.0, 12.4]
          }
        }
        """.data(using: .utf8)!
        let dto = try JSONDecoder().decode(ArchiveResponse.self, from: json)
        let daily = try XCTUnwrap(dto.daily)
        XCTAssertEqual(daily.time, ["2026-09-01", "2026-09-02"])
        XCTAssertEqual(daily.temperature_2m_max?[0], 31.0)
        XCTAssertEqual(daily.temperature_2m_max?[1], 28.5)
        XCTAssertEqual(daily.weather_code?[1], 3)
        XCTAssertEqual(daily.precipitation_sum?[1], 12.4)
    }

    func testDecodeWithNullElementsAndMissingKeys() throws {
        // null 元素 + 整键缺失 → nil，不炸（AC-A2-5 同源纪律）。
        let json = """
        {
          "daily": {
            "time": ["2026-09-01"],
            "temperature_2m_max": [null],
            "weather_code": [null]
          }
        }
        """.data(using: .utf8)!
        let dto = try JSONDecoder().decode(ArchiveResponse.self, from: json)
        XCTAssertEqual(dto.daily?.time, ["2026-09-01"])
        XCTAssertNil(dto.daily?.temperature_2m_max?[0])
        XCTAssertNil(dto.daily?.precipitation_sum)
    }

    func testMissingDailyBlockDecodesNil() throws {
        let dto = try JSONDecoder().decode(ArchiveResponse.self, from: "{}".data(using: .utf8)!)
        XCTAssertNil(dto.daily)
    }

    // MARK: - Endpoint 请求面

    func testBuildsURLWithDatesAndFields() throws {
        let url = try XCTUnwrap(ArchiveEndpoint.url(latitude: 39.9042, longitude: 116.4074,
                                                    startDate: "2026-09-01", endDate: "2026-09-07"))
        let absolute = url.absoluteString
        XCTAssertTrue(absolute.hasPrefix("https://archive-api.open-meteo.com/v1/archive"))
        XCTAssertTrue(absolute.contains("start_date=2026-09-01"))
        XCTAssertTrue(absolute.contains("end_date=2026-09-07"))
        XCTAssertTrue(absolute.contains("timezone=auto"))
        for field in ["temperature_2m_max", "temperature_2m_min", "weather_code", "precipitation_sum"] {
            XCTAssertTrue(absolute.contains(field), "缺少字段 \(field)")
        }
    }

    // MARK: - Mapper

    func testMapperProducesDaysInOrder() throws {
        let json = """
        {
          "daily": {
            "time": ["2026-09-01", "2026-09-02"],
            "temperature_2m_max": [31.0, 28.5],
            "temperature_2m_min": [21.0, 19.0],
            "weather_code": [1, 3],
            "precipitation_sum": [0.0, 12.4]
          }
        }
        """.data(using: .utf8)!
        let dto = try JSONDecoder().decode(ArchiveResponse.self, from: json)
        let historical = ArchiveMapper.map(dto)
        XCTAssertEqual(historical.days.count, 2)
        XCTAssertEqual(historical.days[0].dateString, "2026-09-01")
        XCTAssertEqual(historical.days[0].tempMax, 31.0)
        XCTAssertEqual(historical.days[1].precipitationSum, 12.4)
        XCTAssertEqual(historical.days[0].id, "2026-09-01")
    }

    func testMapperEmptyOnMissingDaily() {
        let historical = ArchiveMapper.map(ArchiveResponse(daily: nil))
        XCTAssertTrue(historical.days.isEmpty, "daily 缺失 → 空序列（页面显示暂无数据）")
    }

    // MARK: - 数据源声明（AC-A3-3）

    func testDataSourceNoticePresent() {
        XCTAssertTrue(HistoricalWeather.dataSourceNotice.contains("ERA5"))
        XCTAssertTrue(HistoricalWeather.dataSourceNotice.contains("非实况观测"))
    }
}

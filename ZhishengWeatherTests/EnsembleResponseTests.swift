//
//  EnsembleResponseTests.swift
//  ZhishengWeatherTests
//
//  Ensemble DTO 解码边界（**手写 JSON fixture**，独立于实现编码器，避免「同源盲区」）：
//   - 真实响应形状：`hourly` 内 `time`(字符串) + 控制成员 + `_memberNN`（两位零填充）；
//   - **成员数可变**：1 成员与 50 成员两种 fixture 都必须正确解析（绝不硬编码 30）；
//   - 非成员键（控制成员 / 其它变量）**不得**被计入成员；
//   - null 元素 / 缺 hourly / 空对象 → 不崩。
//

import XCTest
@testable import ZhishengWeather

final class EnsembleResponseTests: XCTestCase {

    private let decoder: JSONDecoder = JSONDecoder()

    /// 拼接「N 个成员」的 hourly JSON（独立构造，不经实现编码器）。
    /// 形如：time + 控制成员 precipitation + precipitation_member01…NN（两位零填充）。
    private func membersJSON(count: Int) -> String {
        var entries: [String] = []
        entries.append("\"time\": [\"2026-09-16T00:00\", \"2026-09-16T01:00\"]")
        entries.append("\"precipitation\": [0.0, 0.0]")
        for index in 1...count {
            let key = String(format: "precipitation_member%02d", index)
            entries.append("\"\(key)\": [0.0, \(Double(index))]")
        }
        return """
        {
          "utc_offset_seconds": 28800,
          "timezone": "Asia/Shanghai",
          "hourly": { \(entries.joined(separator: ", ")) }
        }
        """
    }

    // MARK: - 成员数可变（PRD §11-8：绝不硬编码 30）

    func testDecodesSingleMemberModel() throws {
        let dto = try decoder.decode(EnsembleResponse.self,
                                     from: Data(membersJSON(count: 1).utf8))
        let hourly = try XCTUnwrap(dto.hourly)
        // series 不含 time（单独解出）：控制成员 + member01 = 2 键。
        XCTAssertEqual(hourly.series.count, 2)
        XCTAssertNotNil(hourly.series["precipitation_member01"])
        XCTAssertNil(hourly.series["time"], "time 不应出现在成员 series 中")
        XCTAssertEqual(EnsembleMapper.map(dto).memberCount, 1, "1 成员模式必须解析为 1")
    }

    func testDecodesFiftyMemberModel() throws {
        let dto = try decoder.decode(EnsembleResponse.self,
                                     from: Data(membersJSON(count: 50).utf8))
        let hourly = try XCTUnwrap(dto.hourly)
        XCTAssertEqual(hourly.series.count, 51, "控制成员 + 50 成员 = 51 键")
        XCTAssertNotNil(hourly.series["precipitation_member50"])
        // 关键：50 成员必须解析为 50（证明实现未硬编码 30）。
        XCTAssertEqual(EnsembleMapper.map(dto).memberCount, 50)
    }

    func testMemberCountFollowsDataNotConstant() throws {
        let three = try decoder.decode(EnsembleResponse.self,
                                       from: Data(membersJSON(count: 3).utf8))
        XCTAssertEqual(EnsembleMapper.map(three).memberCount, 3)
    }

    // MARK: - 非成员键不得计入

    func testNonMemberKeysExcludedFromMemberSeries() throws {
        let json = """
        {
          "hourly": {
            "time": ["2026-09-16T00:00"],
            "precipitation": [0.0],
            "temperature_2m": [5.0],
            "precipitation_member01": [0.2]
          }
        }
        """
        let dto = try decoder.decode(EnsembleResponse.self, from: Data(json.utf8))
        // 仅 member01 是成员；控制成员与 temperature_2m 均排除（正则 `_member\\d{2}$`）。
        XCTAssertEqual(EnsembleMapper.map(dto).memberCount, 1)
    }

    // MARK: - null 元素 / 结构缺失

    func testDecodesNullElements() throws {
        let json = """
        {
          "utc_offset_seconds": 0,
          "hourly": {
            "time": ["2026-09-16T00:00", "2026-09-16T01:00"],
            "precipitation": [0.0, 0.0],
            "precipitation_member01": [null, 0.4],
            "precipitation_member02": [0.1, null]
          }
        }
        """
        let dto = try decoder.decode(EnsembleResponse.self, from: Data(json.utf8))
        let forecast = EnsembleMapper.map(dto)
        XCTAssertEqual(forecast.memberCount, 2)
        XCTAssertNil(forecast.memberSeries[0][0], "null 元素应保留为 nil")
        XCTAssertEqual(try XCTUnwrap(forecast.memberSeries[0][1]), 0.4, accuracy: 1e-9)
    }

    func testMissingHourlyProducesNilHourly() throws {
        let dto = try decoder.decode(EnsembleResponse.self,
                                     from: Data("{ \"timezone\": \"Asia/Shanghai\" }".utf8))
        XCTAssertNil(dto.hourly, "缺 hourly 整键 → nil，不得抛错")
        XCTAssertEqual(EnsembleMapper.map(dto), EnsembleForecast.empty)
    }

    func testEmptyObjectDoesNotThrow() throws {
        let dto = try decoder.decode(EnsembleResponse.self, from: Data("{}".utf8))
        XCTAssertNil(dto.hourly)
        XCTAssertEqual(EnsembleMapper.map(dto).memberCount, 0)
    }
}

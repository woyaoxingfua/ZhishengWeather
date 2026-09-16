//
//  DecodeErrorContextTests.swift
//  ZhishengWeatherTests
//
//  run37 事故回归：解码失败必须**携带 codingPath**，并映射为点名到字段的文案。
//
//  纪律（docs/CI-pitfalls.md P-18 同源盲区）：
//  本用例**不**用「编码后再解码」的往返数据（那会与实现共享同一套假设），
//  而是**手写一段畸形 JSON**，让解码器在真实路径上失败，再断言：
//    1. 抛出的错误是 `WeatherError.decodingDetail` 且带路径；
//    2. `FaultDomain` 归类为 `decodeFailure`；
//    3. 文案里**出现该字段路径**（这正是事故里丢掉、导致只能截图问人的线索）。
//

import XCTest
@testable import ZhishengWeather

final class DecodeErrorContextTests: XCTestCase {

    /// 手写畸形 JSON：`current.temperature_2m` 故意写成字符串（真机 JSON 里是数字）。
    private static let malformedJSON = """
    {
      "timezone": "Asia/Shanghai",
      "utc_offset_seconds": 28800,
      "current": {
        "time": 1700000000,
        "temperature_2m": "很热",
        "relative_humidity_2m": 58,
        "apparent_temperature": 21.0,
        "weather_code": 2,
        "wind_speed_10m": 3.2,
        "wind_direction_10m": 135,
        "is_day": 1
      },
      "hourly": {
        "time": [1700000000],
        "temperature_2m": [23.4],
        "weather_code": [2]
      }
    }
    """

    // MARK: - 畸形载荷 → 带字段路径的错误 + 文案

    func testMalformedPayloadThrowsDecodingDetailWithCodingPath() throws {
        let data = Data(Self.malformedJSON.utf8)

        var caught: Error?
        do {
            _ = try ResponseDecoding.decode(OpenMeteoResponse.self, from: data)
        } catch {
            caught = error
        }

        let error = try XCTUnwrap(caught, "畸形 JSON 必须抛错")
        let weatherError = try XCTUnwrap(error as? WeatherError, "错误必须收敛为 WeatherError")
        guard case .decodingDetail(let path, let debugDescription) = weatherError else {
            return XCTFail("必须是携带上下文的 decodingDetail，实际 \(weatherError)")
        }
        XCTAssertFalse(path.isEmpty, "codingPath 不得丢失（run37 事故根因）")
        XCTAssertTrue(path.contains("temperature_2m"), "字段路径必须点名到出问题的字段，实际 \(path)")
        XCTAssertFalse(debugDescription.isEmpty, "debugDescription 不得丢失")
    }

    func testMalformedPayloadMessageReferencesFieldPath() throws {
        let data = Data(Self.malformedJSON.utf8)

        var caught: Error?
        do {
            _ = try ResponseDecoding.decode(OpenMeteoResponse.self, from: data)
        } catch {
            caught = error
        }

        let error = try XCTUnwrap(caught)
        let domain = FaultDomain.classify(error)
        guard case .decodeFailure(let path, _) = domain else {
            return XCTFail("必须归类为 decodeFailure，实际 \(domain)")
        }
        let message = FaultDomain.message(for: domain)
        XCTAssertTrue(message.contains(path), "文案必须引用字段路径，实际文案：\(message)")
        XCTAssertTrue(message.contains("temperature_2m"), "文案必须点名到字段，实际文案：\(message)")
        XCTAssertTrue(message.contains("接口变更"), "文案必须指向「上游接口可能变更」")
    }

    // MARK: - describe 的纯函数行为（不经 JSON）

    /// 手工构造 `DecodingError`：`describe` 必须把 codingPath 拼成点号串。
    func testDescribeJoinsCodingPathWithDots() {
        let key = FakeCodingKey(stringValue: "sunrise")
        let context = DecodingError.Context(codingPath: [FakeCodingKey(stringValue: "daily"), key],
                                           debugDescription: "期待数字，实为字符串")
        let error = DecodingError.typeMismatch(Double.self, context)

        let described = ResponseDecoding.describe(error)
        XCTAssertEqual(described.path, "daily.sunrise")
        XCTAssertEqual(described.debugDescription, "期待数字，实为字符串")
    }

    func testDescribeRootLevelHasEmptyPath() {
        let context = DecodingError.Context(codingPath: [], debugDescription: "根级损坏")
        let described = ResponseDecoding.describe(.dataCorrupted(context))
        XCTAssertEqual(described.path, "")
        XCTAssertEqual(described.debugDescription, "根级损坏")
    }

    func testDecodeMessageWithoutPathDoesNotPrintDanglingFieldLabel() {
        let message = FaultDomain.decodeMessage(path: "", debugDescription: "x")
        XCTAssertFalse(message.contains("字段"), "无路径时不得出现「字段 」这样的空点名")
        XCTAssertTrue(message.contains("接口变更"))
    }
}

/// 仅供 `DecodingError` 构造用的最小 `CodingKey`。
private struct FakeCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

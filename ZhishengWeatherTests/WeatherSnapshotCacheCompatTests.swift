//
//  WeatherSnapshotCacheCompatTests.swift
//  ZhishengWeatherTests
//
//  F-A-9 旧缓存兼容（静态侧核心用例，不联网）：
//   - 旧版 App 写入的共享容器 JSON（无 `daily` 键）→ 新版解码成功且 `daily == nil`，
//     其余字段值不变（R-1 的结构性保证）；
//   - 含 `daily` 的新 JSON 往返编解码等值；
//   - 解码 → 重编码 → 再解码链路稳定。
//
//  ⚠️ 兼容性依赖「合成 Codable 对缺失键返回 nil」——因此 `WeatherSnapshot`
//  **禁止**手写 `init(from:)`、禁止引入 payloadVersion
//  （ARCH-zhisheng-ios-FA-increment §2.3 / 回归风险 R-1）。
//  若未来有人改动模型解码路径，本文件的用例应当场报错。
//
//  注意：JSONEncoder/Decoder 的默认 Date 策略为 timeIntervalSinceReferenceDate
//  （Double，自 2001-01-01 起算），手写 JSON 中的时间字段按此构造期望值。
//

import XCTest
@testable import ZhishengWeather

final class WeatherSnapshotCacheCompatTests: XCTestCase {

    /// 旧版（F-A 之前）共享容器 JSON：与 `WeatherSnapshot` 全字段一致，唯独没有 `daily` 键。
    private static let legacyJSON = """
    {
      "location": { "name": "北京", "latitude": 39.9042, "longitude": 116.4074, "isFallback": true },
      "temperature": 23.4,
      "apparentTemperature": 21.0,
      "weatherCode": 2,
      "windSpeed": 3.2,
      "windDirection": 135.0,
      "humidity": 58,
      "isDay": true,
      "hourly": [
        { "time": 1700000000.0, "temperature": 23.4, "weatherCode": 2 },
        { "time": 1700003600.0, "temperature": 22.1, "weatherCode": 3 }
      ],
      "dailyHigh": 26.1,
      "dailyLow": 15.2,
      "fetchedAt": 1700000010.0
    }
    """

    // MARK: - 旧缓存解码（F-A-9 静态侧核心）

    func testLegacyJSONWithoutDailyKeyDecodesWithNilDaily() throws {
        let snapshot = try JSONDecoder().decode(WeatherSnapshot.self,
                                                from: Data(Self.legacyJSON.utf8))

        XCTAssertNil(snapshot.daily, "旧缓存无 daily 键必须解码为 nil（F-A-9 兼容核心）")
        // A1-9（R-A1 兼容核心）：旧缓存无 4 个 A1 新键 → 解码成功且全 nil。
        XCTAssertNil(snapshot.pressureMSL, "旧缓存无 pressureMSL 键必须解码为 nil（A1-9）")
        XCTAssertNil(snapshot.sunrise, "旧缓存无 sunrise 键必须解码为 nil（A1-9）")
        XCTAssertNil(snapshot.sunset, "旧缓存无 sunset 键必须解码为 nil（A1-9）")
        XCTAssertNil(snapshot.yesterday, "旧缓存无 yesterday 键必须解码为 nil（A1-9）")
        // B1 遥测补全（R3）：旧缓存无 4 个新键 → 解码成功且全 nil。
        XCTAssertNil(snapshot.visibility, "旧缓存无 visibility 键必须解码为 nil（B1）")
        XCTAssertNil(snapshot.dewPoint, "旧缓存无 dewPoint 键必须解码为 nil（B1）")
        XCTAssertNil(snapshot.cloudCover, "旧缓存无 cloudCover 键必须解码为 nil（B1）")
        XCTAssertNil(snapshot.windGusts, "旧缓存无 windGusts 键必须解码为 nil（B1）")
        // 其余字段值不变
        XCTAssertEqual(snapshot.location.name, "北京")
        XCTAssertEqual(snapshot.location.latitude, 39.9042, accuracy: 1e-9)
        XCTAssertTrue(snapshot.location.isFallback)
        XCTAssertEqual(snapshot.temperature, 23.4, accuracy: 0.001)
        XCTAssertEqual(snapshot.apparentTemperature, 21.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.weatherCode, 2)
        XCTAssertEqual(snapshot.windSpeed, 3.2, accuracy: 0.001)
        XCTAssertEqual(snapshot.windDirection, 135.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.humidity, 58)
        XCTAssertTrue(snapshot.isDay)
        XCTAssertEqual(snapshot.hourly.count, 2)
        // 带 accuracy: 的 XCTAssertEqual 只收非可选 Double（CI 实测），可选链结果需先解包。
        XCTAssertEqual(try XCTUnwrap(snapshot.hourly.first).temperature, 23.4, accuracy: 0.001)
        XCTAssertEqual(snapshot.dailyHigh, 26.1, accuracy: 0.001)
        XCTAssertEqual(snapshot.dailyLow, 15.2, accuracy: 0.001)
        XCTAssertEqual(snapshot.fetchedAt, Date(timeIntervalSinceReferenceDate: 1_700_000_010))
    }

    /// A1 新 JSON（含 4 个新键）往返编解码等值（R-A1 对称面）。
    func testSnapshotWithA1FieldsRoundTripsThroughJSON() throws {
        let date = Date(timeIntervalSinceReferenceDate: 1_700_000_000)
        let sunrise = date.addingTimeInterval(6 * 3_600)
        let sunset = date.addingTimeInterval(18 * 3_600)
        let yesterday = DailyForecast(date: date.addingTimeInterval(-86_400),
                                      weatherCode: 1,
                                      tempMax: 24.0,
                                      tempMin: 14.5,
                                      precipitationProbability: nil)
        let snapshot = WeatherSnapshot(
            location: .beijing,
            temperature: 23.4,
            apparentTemperature: 21.0,
            weatherCode: 2,
            windSpeed: 3.2,
            windDirection: 135,
            humidity: 58,
            isDay: true,
            hourly: [HourlyPoint(time: date, temperature: 23.4, weatherCode: 2)],
            dailyHigh: 26.1,
            dailyLow: 15.2,
            daily: [DailyForecast(date: date, weatherCode: 0, tempMax: 26.1, tempMin: 15.2,
                                  precipitationProbability: 10,
                                  sunrise: sunrise, sunset: sunset)],
            pressureMSL: 1013.2,
            sunrise: sunrise,
            sunset: sunset,
            yesterday: yesterday,
            fetchedAt: date
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WeatherSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot, "含 A1 新字段的快照必须往返编解码等值")
        XCTAssertEqual(decoded.pressureMSL ?? -1, 1013.2, accuracy: 0.001)
        XCTAssertEqual(decoded.sunrise, sunrise)
        XCTAssertEqual(decoded.sunset, sunset)
        XCTAssertEqual(decoded.yesterday, yesterday)
    }

    // MARK: - 新 JSON 往返

    func testSnapshotWithDailyRoundTripsThroughJSON() throws {
        let date = Date(timeIntervalSinceReferenceDate: 1_700_000_000)
        let snapshot = WeatherSnapshot(
            location: .beijing,
            temperature: 23.4,
            apparentTemperature: 21.0,
            weatherCode: 2,
            windSpeed: 3.2,
            windDirection: 135,
            humidity: 58,
            isDay: true,
            hourly: [HourlyPoint(time: date, temperature: 23.4, weatherCode: 2)],
            dailyHigh: 26.1,
            dailyLow: 15.2,
            daily: [
                DailyForecast(date: date,
                              weatherCode: 0,
                              tempMax: 26.1,
                              tempMin: 15.2,
                              precipitationProbability: 10),
                DailyForecast(date: date.addingTimeInterval(86_400),
                              weatherCode: 61,
                              tempMax: 24.0,
                              tempMin: 14.0,
                              precipitationProbability: nil)
            ],
            fetchedAt: date
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WeatherSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot, "含 daily 的快照必须往返编解码等值")
        XCTAssertEqual(decoded.daily?.count, 2)
        // 同上：accuracy 重载不接受 Double?，先 XCTUnwrap 解出首日。
        let firstDay = try XCTUnwrap(decoded.daily?.first)
        XCTAssertEqual(firstDay.tempMax, 26.1, accuracy: 0.001)
        XCTAssertEqual(firstDay.precipitationProbability, 10)
        XCTAssertNil(decoded.daily?.last?.precipitationProbability,
                     "precip 为 nil 的行往返后必须仍是 nil（不得变 0）")
    }

    func testLegacyDecodedSnapshotCanBeReencodedAndDecodedAgain() throws {
        let first = try JSONDecoder().decode(WeatherSnapshot.self,
                                             from: Data(Self.legacyJSON.utf8))

        let data = try JSONEncoder().encode(first)
        let second = try JSONDecoder().decode(WeatherSnapshot.self, from: data)

        XCTAssertNil(second.daily)
        XCTAssertEqual(second, first, "解码 → 重编码 → 再解码链路必须稳定")
    }

    func testLegacyAndNewPayloadsCoexistInSharedStore() throws {
        // 旧 JSON（无 daily）解码后重编码，再被读回 —— 模拟「新版 App 读旧缓存后写回」路径。
        let legacy = try JSONDecoder().decode(WeatherSnapshot.self,
                                              from: Data(Self.legacyJSON.utf8))
        let payload = SharedWeatherPayload(snapshot: legacy,
                                           updatedAt: Date(timeIntervalSinceReferenceDate: 1_700_000_500))
        let data = try JSONEncoder().encode(payload)
        let decodedPayload = try JSONDecoder().decode(SharedWeatherPayload.self, from: data)

        XCTAssertNil(decodedPayload.snapshot.daily)
        XCTAssertEqual(decodedPayload.snapshot, legacy)
    }

    // MARK: - B1 遥测字段往返

    /// B1 遥测四字段往返编解码等值（可选 + 合成 Codable）。
    func testSnapshotWithB1TelemetryFieldsRoundTripsThroughJSON() throws {
        let date = Date(timeIntervalSinceReferenceDate: 1_700_000_000)
        let snapshot = WeatherSnapshot(
            location: .beijing,
            temperature: 23.4,
            apparentTemperature: 21.0,
            weatherCode: 2,
            windSpeed: 3.2,
            windDirection: 135,
            humidity: 58,
            isDay: true,
            hourly: [HourlyPoint(time: date, temperature: 23.4, weatherCode: 2)],
            dailyHigh: 26.1,
            dailyLow: 15.2,
            visibility: 16000.0,
            dewPoint: 8.5,
            cloudCover: 42.0,
            windGusts: 7.5,
            fetchedAt: date
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WeatherSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot, "含 B1 遥测字段的快照必须往返编解码等值")
        XCTAssertEqual(decoded.visibility ?? -1, 16000.0, accuracy: 0.001)
        XCTAssertEqual(decoded.dewPoint ?? -1, 8.5, accuracy: 0.001)
        XCTAssertEqual(decoded.cloudCover ?? -1, 42.0, accuracy: 0.001)
        XCTAssertEqual(decoded.windGusts ?? -1, 7.5, accuracy: 0.001)
    }
}

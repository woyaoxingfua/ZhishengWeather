//
//  WeatherSummaryEngineTests.swift
//  ZhishengWeatherTests
//
//  摘要引擎逐规则命中/不命中 + 优先级短路（AC-A2-6/7/8）。
//  纯函数测试：构造 WeatherSnapshot 即可，无网络、无时钟依赖。
//

import XCTest
@testable import ZhishengWeather

final class WeatherSummaryEngineTests: XCTestCase {

    // MARK: - 构造辅助

    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    /// 快照构造器：默认全部不达阈（确定性"静默"基线）。
    private func makeSnapshot(hourly: [HourlyPoint] = [],
                              windSpeed: Double = 2.0,
                              dailyHigh: Double = 25.0,
                              yesterday: DailyForecast? = nil,
                              daily: [DailyForecast]? = nil) -> WeatherSnapshot {
        WeatherSnapshot(
            location: .beijing,
            temperature: 23.0,
            apparentTemperature: 22.0,
            weatherCode: 1,
            windSpeed: windSpeed,
            windDirection: 90.0,
            humidity: 50,
            isDay: true,
            hourly: hourly,
            dailyHigh: dailyHigh,
            dailyLow: 15.0,
            daily: daily,
            yesterday: yesterday,
            fetchedAt: anchor
        )
    }

    private func makeHourly(_ probabilities: [Double?]) -> [HourlyPoint] {
        // 时点从 anchor 起逐小时。
        probabilities.enumerated().map { index, probability in
            HourlyPoint(time: anchor.addingTimeInterval(Double(index) * 3_600),
                        temperature: 20.0,
                        weatherCode: 1,
                        precipitationProbability: probability)
        }
    }

    private func makeYesterday(high: Double) -> DailyForecast {
        DailyForecast(date: anchor.addingTimeInterval(-86_400),
                      weatherCode: 1, tempMax: high, tempMin: 10.0)
    }

    private func makeDaily(uv: Double?) -> [DailyForecast] {
        [DailyForecast(date: anchor, weatherCode: 1,
                       tempMax: 25.0, tempMin: 15.0, uvIndexMax: uv)]
    }

    // MARK: - ② 强降水

    func testRainSummaryWhenUpcomingHourExceedsThreshold() {
        // 当前小时 10%，1 小时后 80% → "约 60 分钟后可能下雨"。
        let snapshot = makeSnapshot(hourly: makeHourly([10, 80, 20]))
        XCTAssertEqual(WeatherSummaryEngine.rainSummary(for: snapshot),
                       "约 60 分钟后可能下雨")
    }

    func testRainSummaryWhenCurrentHourExceedsThreshold() {
        let snapshot = makeSnapshot(hourly: makeHourly([70, 10, 10]))
        XCTAssertEqual(WeatherSummaryEngine.rainSummary(for: snapshot),
                       "当前时段可能下雨，出门带伞")
    }

    func testRainSummaryAllBelowThresholdReportsNoRain() {
        let snapshot = makeSnapshot(hourly: makeHourly([10, 20, 30]))
        XCTAssertEqual(WeatherSummaryEngine.rainSummary(for: snapshot), "两小时内无雨")
        // "两小时内无雨"属有效摘要（AC-A2-6），summary() 层级应命中而非静默。
        XCTAssertEqual(WeatherSummaryEngine.summary(for: snapshot), "两小时内无雨")
    }

    func testRainSummaryNilWhenNoHourlyData() {
        XCTAssertNil(WeatherSummaryEngine.rainSummary(for: makeSnapshot(hourly: [])))
    }

    // MARK: - ③ 温差

    func testTemperatureDeltaPositiveAndNegative() {
        // +3℃（25 vs 22）→ "较昨天+3°"。
        let hot = makeSnapshot(dailyHigh: 25.0, yesterday: makeYesterday(high: 22.0))
        XCTAssertEqual(WeatherSummaryEngine.temperatureSummary(for: hot), "较昨天+3°")
        // -3℃（20 vs 23）→ "较昨天−3°"。
        let cold = makeSnapshot(dailyHigh: 20.0, yesterday: makeYesterday(high: 23.0))
        XCTAssertEqual(WeatherSummaryEngine.temperatureSummary(for: cold), "较昨天−3°")
    }

    func testTemperatureDeltaBelowThresholdNoHit() {
        let snapshot = makeSnapshot(dailyHigh: 25.0, yesterday: makeYesterday(high: 24.0))
        XCTAssertNil(WeatherSummaryEngine.temperatureSummary(for: snapshot))
    }

    func testTemperatureDeltaNilWithoutYesterday() {
        XCTAssertNil(WeatherSummaryEngine.temperatureSummary(for: makeSnapshot(yesterday: nil)))
    }

    // MARK: - ④ 大风

    func testWindHitAndMiss() {
        XCTAssertEqual(WeatherSummaryEngine.windSummary(for: makeSnapshot(windSpeed: 10.0)),
                       "大风注意")
        XCTAssertNil(WeatherSummaryEngine.windSummary(for: makeSnapshot(windSpeed: 9.9)))
    }

    // MARK: - ⑤ UV

    func testUVHitAndMiss() {
        XCTAssertEqual(WeatherSummaryEngine.uvSummary(for: makeSnapshot(daily: makeDaily(uv: 6.0))),
                       "紫外线较强，注意防晒")
        XCTAssertNil(WeatherSummaryEngine.uvSummary(for: makeSnapshot(daily: makeDaily(uv: 5.9))))
        XCTAssertNil(WeatherSummaryEngine.uvSummary(for: makeSnapshot(daily: nil)))
    }

    // MARK: - 优先级短路（AC-A2-7）

    func testPriorityShortCircuitsToRain() {
        // 降水 + 温差 + 风 + UV 同时命中 → 只返回降水句。
        let snapshot = makeSnapshot(hourly: makeHourly([10, 80, 10]),
                                    windSpeed: 12.0,
                                    dailyHigh: 25.0,
                                    yesterday: makeYesterday(high: 20.0),
                                    daily: makeDaily(uv: 8.0))
        XCTAssertEqual(WeatherSummaryEngine.summary(for: snapshot),
                       "约 60 分钟后可能下雨")
    }

    func testSummaryFallsThroughToWindWhenNoRainNoDelta() {
        // 无降水数据、无 yesterday → 命中风。
        let snapshot = makeSnapshot(hourly: [], windSpeed: 11.0, yesterday: nil, daily: nil)
        XCTAssertEqual(WeatherSummaryEngine.summary(for: snapshot), "大风注意")
    }

    // MARK: - 全不命中（AC-A2-8）

    func testSummaryNilWhenNoRuleHitsAtAll() {
        // 注意：hourly 有概率数据（无强降水）→ rainSummary 命中"两小时内无雨"（AC-A2-6
        // 明确含此表述，属有效摘要而非静默）。要测"全静默"需连概率数据也去掉，
        // 且温差/风/UV 均不达阈 → nil。
        let snapshot = makeSnapshot(hourly: [],
                                    windSpeed: 2.0,
                                    dailyHigh: 25.0,
                                    yesterday: makeYesterday(high: 24.0),
                                    daily: makeDaily(uv: 3.0))
        XCTAssertNil(WeatherSummaryEngine.summary(for: snapshot))
    }
}

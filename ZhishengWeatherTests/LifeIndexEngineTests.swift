//
//  LifeIndexEngineTests.swift
//  ZhishengWeatherTests
//
//  生活指数规则逐项命中/不命中 + 阈值边界（AC-A2-11）。
//  纯函数测试：构造 WeatherSnapshot 即可，无网络、无时钟。
//  期望值先手算再断言（CI run12 教训）。
//

import XCTest
@testable import ZhishengWeather

final class LifeIndexEngineTests: XCTestCase {

    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    /// 快照构造器：默认全中性（确定性"静默"基线）。
    private func makeSnapshot(uv: Double? = nil,
                              precip: Int? = nil,
                              tempMax: Double = 20.0,
                              tempMin: Double = 12.0,
                              weatherCode: Int = 1,
                              windSpeed: Double = 2.0) -> WeatherSnapshot {
        let daily = [DailyForecast(date: anchor,
                                   weatherCode: weatherCode,
                                   tempMax: tempMax,
                                   tempMin: tempMin,
                                   precipitationProbability: precip,
                                   uvIndexMax: uv)]
        return WeatherSnapshot(location: .beijing,
                               temperature: 18.0, apparentTemperature: 17.0,
                               weatherCode: weatherCode, windSpeed: windSpeed,
                               windDirection: 90.0, humidity: 50, isDay: true,
                               hourly: [], dailyHigh: tempMax, dailyLow: tempMin,
                               daily: daily, fetchedAt: anchor)
    }

    // MARK: - 输出结构（AC-A2-11：结构化非 String）

    func testOutputsFourItemsInFixedOrder() {
        let items = LifeIndexEngine.indices(for: makeSnapshot())
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.map(\.kind), [.sun, .clothing, .carWash, .exercise],
                       "输出顺序固定：防晒→穿衣→洗车→运动")
    }

    // MARK: - 防晒（UV 阈值边界：3/6/8）

    func testSunLevelsAtThresholds() {
        // ≥8 → avoid（必须防晒）。
        XCTAssertEqual(LifeIndexEngine.sunIndex(for: makeSnapshot(uv: 8)).level, .avoid)
        XCTAssertEqual(LifeIndexEngine.sunIndex(for: makeSnapshot(uv: 10)).level, .avoid)
        // ≥6 → caution。
        XCTAssertEqual(LifeIndexEngine.sunIndex(for: makeSnapshot(uv: 6)).level, .caution)
        // <3 → recommended。
        XCTAssertEqual(LifeIndexEngine.sunIndex(for: makeSnapshot(uv: 2.9)).level, .recommended)
        // 中间 → neutral。
        XCTAssertEqual(LifeIndexEngine.sunIndex(for: makeSnapshot(uv: 4)).level, .neutral)
        // nil → neutral（数据缺失降级）。
        XCTAssertEqual(LifeIndexEngine.sunIndex(for: makeSnapshot(uv: nil)).level, .neutral)
    }

    func testSunValueCarriesRoundedUV() throws {
        let item = LifeIndexEngine.sunIndex(for: makeSnapshot(uv: 7.4))
        XCTAssertEqual(try XCTUnwrap(item.value), "UV 7")
    }

    // MARK: - 穿衣（温段 5/15/26）

    func testClothingLevelsAtTemperatureBands() {
        XCTAssertEqual(LifeIndexEngine.clothingIndex(for: makeSnapshot(tempMax: 3.0)).level, .caution)
        XCTAssertEqual(LifeIndexEngine.clothingIndex(for: makeSnapshot(tempMax: 10.0)).level, .neutral)
        XCTAssertEqual(LifeIndexEngine.clothingIndex(for: makeSnapshot(tempMax: 20.0)).level, .recommended)
        XCTAssertEqual(LifeIndexEngine.clothingIndex(for: makeSnapshot(tempMax: 30.0)).level, .neutral)
    }

    func testClothingValueCarriesRangeAndHint() throws {
        let item = LifeIndexEngine.clothingIndex(for: makeSnapshot(tempMax: 20.0, tempMin: 12.0))
        let value = try XCTUnwrap(item.value)
        XCTAssertTrue(value.contains("12–20℃"), "应含温度区间，实际 \(value)")
        XCTAssertTrue(value.contains("轻薄"), "20℃ 段应为轻薄，实际 \(value)")
    }

    // MARK: - 洗车（降水阈值 20/60）

    func testCarWashLevelsAtProbabilityThresholds() {
        XCTAssertEqual(LifeIndexEngine.carWashIndex(for: makeSnapshot(precip: 10)).level, .recommended)
        XCTAssertEqual(LifeIndexEngine.carWashIndex(for: makeSnapshot(precip: 19)).level, .recommended)
        XCTAssertEqual(LifeIndexEngine.carWashIndex(for: makeSnapshot(precip: 20)).level, .neutral)
        XCTAssertEqual(LifeIndexEngine.carWashIndex(for: makeSnapshot(precip: 60)).level, .avoid)
        // nil = 未知 → 中性。
        XCTAssertEqual(LifeIndexEngine.carWashIndex(for: makeSnapshot(precip: nil)).level, .neutral)
    }

    // MARK: - 运动（联合判据）

    func testExerciseRecommendedWhenAllConditionsMet() {
        // 降水 10% < 30、温 20 ∈ [10,30]、码 1 非强天气 → 适宜。
        XCTAssertEqual(LifeIndexEngine.exerciseIndex(for: makeSnapshot(precip: 10, weatherCode: 1)).level,
                       .recommended)
    }

    func testExerciseAvoidOnStrongWeatherOrHeavyRain() {
        // 雷暴（码 95）→ avoid，即使其他条件满足。
        XCTAssertEqual(LifeIndexEngine.exerciseIndex(for: makeSnapshot(precip: 10, weatherCode: 95)).level,
                       .avoid)
        // 降水 60% ≥ 30 → avoid。
        XCTAssertEqual(LifeIndexEngine.exerciseIndex(for: makeSnapshot(precip: 60, weatherCode: 1)).level,
                       .avoid)
    }

    func testExerciseNeutralOnTemperatureOutOfRange() {
        // 35℃ 超上限、无强天气 → 中性。
        XCTAssertEqual(LifeIndexEngine.exerciseIndex(for: makeSnapshot(precip: 10, tempMax: 35.0)).level,
                       .neutral)
    }
}

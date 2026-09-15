//
//  AirQualityTests.swift
//  ZhishengWeatherTests
//
//  空气领域模型（A2-1）：六档边界 + 主导污染物（D-A2-1 简化权重）。
//  阈值边界先手算再断言（CI run12 教训：期望值必须独立复算）。
//
//  六档边界（EPA）：50/51、100/101、150/151、200/201、300/301。
//  主导污染物基准：PM2.5/35、PM10/150、O₃/137.5、NO₂/100、SO₂/365、CO/40000。
//

import XCTest
@testable import ZhishengWeather

final class AirQualityTests: XCTestCase {

    // MARK: - 六档边界（usAqi）

    func testLevelBoundaries() {
        XCTAssertEqual(AqiLevel(usAqi: 0), .good)
        XCTAssertEqual(AqiLevel(usAqi: 50), .good)
        XCTAssertEqual(AqiLevel(usAqi: 51), .moderate)
        XCTAssertEqual(AqiLevel(usAqi: 100), .moderate)
        XCTAssertEqual(AqiLevel(usAqi: 101), .light)
        XCTAssertEqual(AqiLevel(usAqi: 150), .light)
        XCTAssertEqual(AqiLevel(usAqi: 151), .medium)
        XCTAssertEqual(AqiLevel(usAqi: 200), .medium)
        XCTAssertEqual(AqiLevel(usAqi: 201), .heavy)
        XCTAssertEqual(AqiLevel(usAqi: 300), .heavy)
        XCTAssertEqual(AqiLevel(usAqi: 301), .severe)
        XCTAssertEqual(AqiLevel(usAqi: 500), .severe)
    }

    func testLevelUnknownWhenAqiMissing() {
        XCTAssertEqual(AqiLevel(usAqi: nil), .unknown)
    }

    // MARK: - 主导污染物（简化相对权重）

    private func makeAir(_ dict: [String: Double?]) -> AirQuality {
        AirQuality(usAqi: nil, europeanAqi: nil,
                   pm25: dict["pm25"] ?? nil,
                   pm10: dict["pm10"] ?? nil,
                   carbonMonoxide: dict["co"] ?? nil,
                   nitrogenDioxide: dict["no2"] ?? nil,
                   sulphurDioxide: dict["so2"] ?? nil,
                   ozone: dict["o3"] ?? nil)
    }

    func testDominantPollutantPicksHighestNormalizedRatio() {
        // PM2.5: 30.9/35 ≈ 0.883；PM10: 93.1/150 ≈ 0.621 → PM2.5 胜出（北京实测形态）。
        let air = makeAir(["pm25": 30.9, "pm10": 93.1])
        XCTAssertEqual(air.dominantPollutant, "PM2.5")

        // SO₂: 300/365 ≈ 0.822；PM2.5: 20/35 ≈ 0.571 → SO₂ 胜出。
        let air2 = makeAir(["pm25": 20.0, "so2": 300.0])
        XCTAssertEqual(air2.dominantPollutant, "二氧化硫")
    }

    func testDominantPollutantIgnoresNilAndNonPositive() {
        // 全 nil → nil。
        XCTAssertNil(makeAir([:]).dominantPollutant)
        // 非正数不参与（mapper 已净化，此处双保险）。
        XCTAssertNil(makeAir(["pm25": 0.0]).dominantPollutant)
    }

    // MARK: - level 降级

    func testLevelFallsBackToUnknownWithoutUsAqi() {
        let air = makeAir(["pm25": 30.0])
        XCTAssertEqual(air.level, .unknown)
        XCTAssertEqual(air.level.displayName, "未知")
    }
}

//
//  WeatherFieldFormattersTests.swift
//  ZhishengWeatherTests
//
//  P2 数据补全（渲染侧）的纯函数单测：
//   - WindDirectionFormatter：8 方位中文（角度 → 中文），含负角 / 超 360 / 边界。
//   - DurationFormatter：秒 → 「X 小时 Y 分」，含 0 / 59 / 3599 / 86400 / 负值。
//   - DailyForecast 展示文案属性：0 与 nil 的区分、整段隐藏、昼长/日照分标签。
//

import XCTest
@testable import ZhishengWeather

final class WeatherFieldFormattersTests: XCTestCase {

    // MARK: - WindDirectionFormatter

    func testWindDirectionEightPoints() {
        XCTAssertEqual(WindDirectionFormatter.text(from: 0), "北")
        XCTAssertEqual(WindDirectionFormatter.text(from: 45), "东北")
        XCTAssertEqual(WindDirectionFormatter.text(from: 90), "东")
        XCTAssertEqual(WindDirectionFormatter.text(from: 135), "东南")
        XCTAssertEqual(WindDirectionFormatter.text(from: 180), "南")
        XCTAssertEqual(WindDirectionFormatter.text(from: 225), "西南")
        XCTAssertEqual(WindDirectionFormatter.text(from: 270), "西")
        XCTAssertEqual(WindDirectionFormatter.text(from: 315), "西北")
        XCTAssertEqual(WindDirectionFormatter.text(from: 360), "北")
    }

    func testWindDirectionBoundary348_75RoundsToNorth() {
        // 348.75° 贴近正北，按既有算法 round(348.75/45)=round(7.75)=8 → 8%8=0 → 北。
        XCTAssertEqual(WindDirectionFormatter.text(from: 348.75), "北")
    }

    func testWindDirectionNegativeAndOverflowNormalize() {
        XCTAssertEqual(WindDirectionFormatter.text(from: -45), "西北", "负角归一化到 [0,360)")
        XCTAssertEqual(WindDirectionFormatter.text(from: 450), "东", "450° 等价于 90°")
    }

    // MARK: - DurationFormatter

    func testDurationZeroSeconds() {
        XCTAssertEqual(DurationFormatter.hoursMinutesText(fromSeconds: 0), "0 分")
    }

    func testDurationSubMinute() {
        XCTAssertEqual(DurationFormatter.hoursMinutesText(fromSeconds: 59), "0 分", "不足 1 分钟仍归到分钟档")
    }

    func testDurationUnderOneHour() {
        XCTAssertEqual(DurationFormatter.hoursMinutesText(fromSeconds: 3599), "59 分")
    }

    func testDurationFullDay() {
        XCTAssertEqual(DurationFormatter.hoursMinutesText(fromSeconds: 86_400), "24 小时 0 分")
    }

    func testDurationTypicalDaylight() {
        // 14 小时 30 分 = 52_200 秒。
        XCTAssertEqual(DurationFormatter.hoursMinutesText(fromSeconds: 52_200), "14 小时 30 分")
    }

    func testDurationNonFiniteOrNegative() {
        XCTAssertEqual(DurationFormatter.hoursMinutesText(fromSeconds: -1), "--", "负值防御")
        XCTAssertEqual(DurationFormatter.hoursMinutesText(fromSeconds: .infinity), "--")
        XCTAssertEqual(DurationFormatter.hoursMinutesText(fromSeconds: .nan), "--")
    }

    // MARK: - PrecipitationFormatter（换算责任层：单位恒为 mm）

    func testPrecipitationFormatterMillimetersLabel() {
        XCTAssertEqual(PrecipitationFormatter.text(fromMillimeters: 12.5), "12.5 mm", "单位锁定 mm")
    }

    func testPrecipitationFormatterZeroIsDisplayed() {
        XCTAssertEqual(PrecipitationFormatter.text(fromMillimeters: 0), "0.0 mm", "0 mm 合法值，原样显示非 --")
    }

    func testPrecipitationFormatterNonFiniteDefensive() {
        XCTAssertEqual(PrecipitationFormatter.text(fromMillimeters: .infinity), "--")
        XCTAssertEqual(PrecipitationFormatter.text(fromMillimeters: .nan), "--")
    }

    // MARK: - SnowfallFormatter（换算责任层：单位恒为 cm，禁止改 mm）

    func testSnowfallFormatterCentimetersLabel() {
        // 机械锁核心：雪量单位是 cm，绝不是 mm（Open-Meteo 原值即 cm）。
        XCTAssertEqual(SnowfallFormatter.text(fromCentimeters: 5.0), "5.0 cm", "单位锁定 cm")
    }

    func testSnowfallFormatterZeroIsDisplayed() {
        XCTAssertEqual(SnowfallFormatter.text(fromCentimeters: 0), "0.0 cm", "0 cm 合法值原样显示")
    }

    func testSnowfallFormatterPositiveDecimal() {
        XCTAssertEqual(SnowfallFormatter.text(fromCentimeters: 2.4), "2.4 cm")
    }

    func testSnowfallFormatterNonFiniteDefensive() {
        XCTAssertEqual(SnowfallFormatter.text(fromCentimeters: .infinity), "--")
        XCTAssertEqual(SnowfallFormatter.text(fromCentimeters: .nan), "--")
    }

    // MARK: - DailyForecast 展示文案（0 与 nil 区分 / 整段隐藏）

    private func day(precipitationSum: Double? = nil,
                     snowfallSum: Double? = nil,
                     windSpeedMax: Double? = nil,
                     windGustsMax: Double? = nil,
                     windDirectionDominant: Double? = nil,
                     daylightDuration: Double? = nil,
                     sunshineDuration: Double? = nil,
                     apparentMax: Double? = nil,
                     apparentMin: Double? = nil) -> DailyForecast {
        DailyForecast(date: Date(timeIntervalSince1970: 0),
                      weatherCode: 1,
                      tempMax: 30,
                      tempMin: 20,
                      precipitationProbability: nil,
                      sunrise: nil,
                      sunset: nil,
                      uvIndexMax: nil,
                      precipitationSum: precipitationSum,
                      rainSum: nil,
                      snowfallSum: snowfallSum,
                      windSpeedMax: windSpeedMax,
                      windGustsMax: windGustsMax,
                      windDirectionDominant: windDirectionDominant,
                      daylightDuration: daylightDuration,
                      sunshineDuration: sunshineDuration,
                      apparentTemperatureMax: apparentMax,
                      apparentTemperatureMin: apparentMin)
    }

    func testPrecipitationSumZeroIsDisplayedNotHidden() {
        let d = day(precipitationSum: 0.0)
        XCTAssertEqual(d.precipitationSumText, "降水 0.0 mm", "0 mm 是合法值，必须原样显示")
    }

    func testPrecipitationSumNilHidesSegment() {
        let d = day(precipitationSum: nil)
        XCTAssertNil(d.precipitationSumText, "nil → 段隐藏")
    }

    func testPrecipitationSumPositive() {
        let d = day(precipitationSum: 12.5)
        XCTAssertEqual(d.precipitationSumText, "降水 12.5 mm")
    }

    func testSnowfallSumZeroIsDisplayedNotHidden() {
        let d = day(snowfallSum: 0.0)
        XCTAssertEqual(d.snowfallSumText, "降雪 0.0 cm", "0 cm 合法值，原样显示（单位 cm）")
    }

    func testSnowfallSumNilHidesSegment() {
        let d = day(snowfallSum: nil)
        XCTAssertNil(d.snowfallSumText, "nil → 段隐藏")
    }

    func testSnowfallSumPositive() {
        let d = day(snowfallSum: 2.4)
        XCTAssertEqual(d.snowfallSumText, "降雪 2.4 cm", "单位 cm，由 SnowfallFormatter 锁定")
    }

    func testWindSummaryAllNilHides() {
        XCTAssertNil(day().windSummaryText, "三段全 nil → 整段隐藏")
    }

    func testWindSummaryPartialAndDirection() {
        // 最大风 / 主导风向有值，阵风 nil。主导风向 90° → 东。
        let d = day(windSpeedMax: 5.2, windDirectionDominant: 90)
        XCTAssertEqual(d.windSummaryText, "最大风 5.2 m/s · 主导风向 东")
    }

    func testWindSummaryFull() {
        // 315° → 西北。
        let d = day(windSpeedMax: 5.2, windGustsMax: 9.1, windDirectionDominant: 315)
        XCTAssertEqual(d.windSummaryText, "最大风 5.2 m/s · 阵风 9.1 m/s · 主导风向 西北")
    }

    func testDaylightAndSunshineDistinctLabels() {
        // 昼长与日照分别标注，不得共用标签；秒原值换算。
        let d = day(daylightDuration: 52_200, sunshineDuration: 29_700)
        XCTAssertEqual(d.daylightText, "昼长 14 小时 30 分")
        XCTAssertEqual(d.sunshineText, "日照 8 小时 15 分")
    }

    func testDaylightNilHidesOnlyItsSegment() {
        let d = day(sunshineDuration: 29_700)
        XCTAssertNil(d.daylightText, "昼长 nil → 仅昼长段隐藏")
        XCTAssertEqual(d.sunshineText, "日照 8 小时 15 分", "日照段不受影响")
    }

    func testApparentSummaryBothPresent() {
        let d = day(apparentMax: 32, apparentMin: 24)
        XCTAssertEqual(d.apparentSummaryText, "体感 32° / 24°")
    }

    func testApparentSummaryPartial() {
        let d = day(apparentMax: 32)
        XCTAssertEqual(d.apparentSummaryText, "体感 32°", "仅高温有值 → 只显示高温")
    }

    func testApparentSummaryNilHides() {
        XCTAssertNil(day().apparentSummaryText)
    }
}

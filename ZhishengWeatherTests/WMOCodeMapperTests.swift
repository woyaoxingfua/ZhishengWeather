//
//  WMOCodeMapperTests.swift
//  ZhishengWeatherTests
//
//  WMO 码映射：
//   - 全量常用码覆盖（0/1/2/3/45/48/51/53/55/56/57/61/63/65/66/67/71/73/75/77/80/81/82/85/86/95/96/99）
//   - 日/夜符号区分（仅对晴/云/阵雨等应区分者）
//   - 未知码、负数、越界码统一兜底，不崩溃
//   - 任意码的符号名与描述均非空
//

import XCTest
@testable import ZhishengWeather

final class WMOCodeMapperTests: XCTestCase {

    /// Open-Meteo 文档列出的全部 WMO 天气码。
    private let commonCodes = [0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57,
                               61, 63, 65, 66, 67, 71, 73, 75, 77,
                               80, 81, 82, 85, 86, 95, 96, 99]

    /// 昼夜符号应当相同的码（非晴/云/阵雨类）。
    private let sameSymbolCodes = [3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67,
                                   71, 73, 75, 77, 82, 85, 86, 95, 96, 99]

    /// 昼夜符号应当不同的码。
    private let differentSymbolCodes = [0, 1, 2, 80, 81]

    // MARK: - 描述文案

    func testKnownDescriptions() {
        XCTAssertEqual(WMOCodeMapper.description(for: 0), "晴")
        XCTAssertEqual(WMOCodeMapper.description(for: 3), "阴")
        XCTAssertEqual(WMOCodeMapper.description(for: 61), "小雨")
        XCTAssertEqual(WMOCodeMapper.description(for: 95), "雷阵雨")
        XCTAssertEqual(WMOCodeMapper.description(for: 99), "雷暴伴强冰雹")
    }

    func testFogCodesAreDistinguished() {
        XCTAssertEqual(WMOCodeMapper.description(for: 45), "有雾")
        XCTAssertEqual(WMOCodeMapper.description(for: 48), "雾凇")
    }

    // MARK: - 昼夜符号

    func testDayAndNightSymbolsDifferForClearSky() {
        XCTAssertEqual(WMOCodeMapper.symbolName(for: 0, isDay: true), "sun.max.fill")
        XCTAssertEqual(WMOCodeMapper.symbolName(for: 0, isDay: false), "moon.stars.fill")
    }

    func testPartlyCloudyUsesCloudMoonAtNight() {
        XCTAssertEqual(WMOCodeMapper.symbolName(for: 2, isDay: false), "cloud.moon.fill")
        XCTAssertEqual(WMOCodeMapper.symbolName(for: 2, isDay: true), "cloud.sun.fill")
    }

    func testShowersUseMoonVariantAtNight() {
        XCTAssertEqual(WMOCodeMapper.symbolName(for: 80, isDay: true), "cloud.sun.rain.fill")
        XCTAssertEqual(WMOCodeMapper.symbolName(for: 80, isDay: false), "cloud.moon.rain.fill")
        XCTAssertEqual(WMOCodeMapper.symbolName(for: 81, isDay: false), "cloud.moon.rain.fill")
    }

    func testDayNightSymbolsDifferOnlyWhereExpected() {
        for code in differentSymbolCodes {
            XCTAssertNotEqual(WMOCodeMapper.symbolName(for: code, isDay: true),
                              WMOCodeMapper.symbolName(for: code, isDay: false),
                              "code \(code) 的昼夜符号应不同")
        }
        for code in sameSymbolCodes {
            XCTAssertEqual(WMOCodeMapper.symbolName(for: code, isDay: true),
                           WMOCodeMapper.symbolName(for: code, isDay: false),
                           "code \(code) 的昼夜符号应相同")
        }
    }

    // MARK: - 未知码 / 越界兜底

    func testUnknownCodeFallsBackWithoutCrash() {
        let condition = WMOCodeMapper.condition(for: 12_345, isDay: true)
        XCTAssertEqual(condition.description, "未知")
        XCTAssertEqual(condition.symbolName, "questionmark.circle.fill")
        XCTAssertEqual(condition, WMOCodeMapper.unknown)
    }

    func testNegativeCodeFallsBack() {
        // 空态渲染会传入 -1
        XCTAssertEqual(WMOCodeMapper.condition(for: -1, isDay: true), WMOCodeMapper.unknown)
        XCTAssertEqual(WMOCodeMapper.symbolName(for: -1, isDay: false), "questionmark.circle.fill")
    }

    func testFullRangeSweepNeverReturnsEmptyOutput() {
        for code in -20...200 {
            XCTAssertFalse(WMOCodeMapper.symbolName(for: code, isDay: true).isEmpty,
                           "code \(code) 日间符号为空")
            XCTAssertFalse(WMOCodeMapper.symbolName(for: code, isDay: false).isEmpty,
                           "code \(code) 夜间符号为空")
            XCTAssertFalse(WMOCodeMapper.description(for: code).isEmpty,
                           "code \(code) 描述为空")
        }
    }

    // MARK: - 全量常用码覆盖

    func testAllCommonCodesAreCovered() {
        for code in commonCodes {
            let day = WMOCodeMapper.condition(for: code, isDay: true)
            let night = WMOCodeMapper.condition(for: code, isDay: false)
            XCTAssertNotEqual(day, WMOCodeMapper.unknown, "code \(code) 未覆盖（日）")
            XCTAssertNotEqual(night, WMOCodeMapper.unknown, "code \(code) 未覆盖（夜）")
            XCTAssertNotEqual(day.description, "未知", "code \(code) 描述未覆盖")
            XCTAssertFalse(day.symbolName.isEmpty, "code \(code) 日间符号为空")
            XCTAssertFalse(night.nightSymbolName.isEmpty, "code \(code) 夜间符号为空")
        }
    }

    /// 所有产出符号必须是非空且形如 `<name>[.<name>...]` 的合法 SF Symbol 标识。
    func testProducedSymbolsLookLikeSFIdentifiers() {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.")
        for code in commonCodes {
            for isDay in [true, false] {
                let symbol = WMOCodeMapper.symbolName(for: code, isDay: isDay)
                XCTAssertFalse(symbol.isEmpty)
                XCTAssertTrue(symbol.unicodeScalars.allSatisfy { allowed.contains($0) },
                              "code \(code) 符号含非法字符：\(symbol)")
                XCTAssertFalse(symbol.hasPrefix("."), "code \(code) 符号以点开头：\(symbol)")
                XCTAssertFalse(symbol.hasSuffix("."), "code \(code) 符号以点结尾：\(symbol)")
            }
        }
    }

    /// 逐码精确断言（防止后续回归改错符号）。
    func testExactSymbolTable() {
        let table: [(Int, String, String)] = [
            (0, "sun.max.fill", "moon.stars.fill"),
            (1, "sun.max.fill", "moon.fill"),
            (2, "cloud.sun.fill", "cloud.moon.fill"),
            (3, "cloud.fill", "cloud.fill"),
            (45, "cloud.fog.fill", "cloud.fog.fill"),
            (48, "cloud.fog.fill", "cloud.fog.fill"),
            (51, "cloud.drizzle.fill", "cloud.drizzle.fill"),
            (61, "cloud.rain.fill", "cloud.rain.fill"),
            (65, "cloud.heavyrain.fill", "cloud.heavyrain.fill"),
            (71, "cloud.snow.fill", "cloud.snow.fill"),
            (80, "cloud.sun.rain.fill", "cloud.moon.rain.fill"),
            (82, "cloud.heavyrain.fill", "cloud.heavyrain.fill"),
            (95, "cloud.bolt.rain.fill", "cloud.bolt.rain.fill"),
            (99, "cloud.bolt.rain.fill", "cloud.bolt.rain.fill")
        ]
        for (code, day, night) in table {
            XCTAssertEqual(WMOCodeMapper.symbolName(for: code, isDay: true), day, "code \(code) 日间")
            XCTAssertEqual(WMOCodeMapper.symbolName(for: code, isDay: false), night, "code \(code) 夜间")
        }
    }
}

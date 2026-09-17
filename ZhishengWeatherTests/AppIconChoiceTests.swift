//
//  AppIconChoiceTests.swift
//  ZhishengWeatherTests
//
//  图标档位纯映射单测（Core 纯函数，无 UIKit、无系统调用）：
//   - 档位 → 备用图标名：默认档 = nil，两个备用档 = 资源名；
//   - 反向归一化：nil / 已知名 / 未知串 → 档位；
//   - 持久化归一化：缺失 / 未知 rawValue → 默认档；
//   - 显示名与「默认」标注（设置页文案单一真源锁定）。
//

import XCTest
@testable import ZhishengWeather

final class AppIconChoiceTests: XCTestCase {

    // MARK: - 档位 → 备用图标名（正向映射）

    /// 默认档映射为 nil（绝不把 "AppIcon" 当备用名传系统）。
    func testPhosphorMapsToNilAlternateName() {
        XCTAssertNil(IconChoice.phosphor.alternateIconName)
    }

    /// 清冷翡翠 → AppIcon-Jade。
    func testJadeMapsToJadeAssetName() {
        XCTAssertEqual(IconChoice.jade.alternateIconName, "AppIcon-Jade")
    }

    /// 终端雨字 → AppIcon-Rain。
    func testRainMapsToRainAssetName() {
        XCTAssertEqual(IconChoice.rain.alternateIconName, "AppIcon-Rain")
    }

    // MARK: - 备用图标名 → 档位（反向归一化）

    /// nil（系统 alternateIconName 语义 = 当前默认）→ 默认档。
    func testResolveNilReturnsPhosphor() {
        XCTAssertEqual(IconChoice.resolve(alternateName: nil), .phosphor)
    }

    /// 两个已知备用名各自归位。
    func testResolveKnownNames() {
        XCTAssertEqual(IconChoice.resolve(alternateName: "AppIcon-Jade"), .jade)
        XCTAssertEqual(IconChoice.resolve(alternateName: "AppIcon-Rain"), .rain)
    }

    /// 未知串（资源改名残留 / 手改数据）→ 回退默认档。
    func testResolveUnknownStringFallsBackToPhosphor() {
        XCTAssertEqual(IconChoice.resolve(alternateName: "AppIcon"), .phosphor)
        XCTAssertEqual(IconChoice.resolve(alternateName: "legacy-icon"), .phosphor)
        XCTAssertEqual(IconChoice.resolve(alternateName: ""), .phosphor)
    }

    // MARK: - 持久化归一化

    /// 缺失（nil）→ 默认档。
    func testNormalizedNilRawValueReturnsPhosphor() {
        XCTAssertEqual(IconChoicePreference.normalized(nil), .phosphor)
    }

    /// 已知 rawValue 各自归位（roundtrip：档位 → rawValue → 档位）。
    func testNormalizedKnownRawValuesRoundtrip() {
        for choice in IconChoice.allCases {
            XCTAssertEqual(IconChoicePreference.normalized(choice.rawValue), choice)
        }
    }

    /// 未知 rawValue（手改 UserDefaults / 历史残留）→ 默认档。
    func testNormalizedUnknownRawValueReturnsPhosphor() {
        XCTAssertEqual(IconChoicePreference.normalized("neon"), .phosphor)
        XCTAssertEqual(IconChoicePreference.normalized(""), .phosphor)
        XCTAssertEqual(IconChoicePreference.normalized("PHOSPHOR"), .phosphor) // 大小写敏感，未知即回退
    }

    // MARK: - 文案单一真源（设置页显示名锁定）

    /// 显示名与资源名对照表锁定（改动即测试红，防止两处漂移）。
    func testDisplayNames() {
        XCTAssertEqual(IconChoice.phosphor.displayName, "磷光")
        XCTAssertEqual(IconChoice.jade.displayName, "清冷翡翠")
        XCTAssertEqual(IconChoice.rain.displayName, "终端雨字")
    }

    /// 只有默认档标注 isDefault。
    func testIsDefaultOnlyForPhosphor() {
        XCTAssertTrue(IconChoice.phosphor.isDefault)
        XCTAssertFalse(IconChoice.jade.isDefault)
        XCTAssertFalse(IconChoice.rain.isDefault)
    }

    /// 档位恰为三档（AllCases 数量锁定，防止误删）。
    func testAllCasesCountIsThree() {
        XCTAssertEqual(IconChoice.allCases.count, 3)
    }
}

//
//  ThemePaletteTests.swift
//  ZhishengWeatherTests
//
//  配色解析（纯函数）+ 外观偏好归一化 + 「深色抽层零视觉变化」回归守卫。
//
//  · resolve(appearance:systemScheme:)：穷举「外观档位 × 系统深浅」全组合。
//  · AppearancePreference：缺失键 / 未知值（"neon"）一律回退 "system"；
//    且只写 App 本地标准 UserDefaults，**不得**写入 App Group 共享容器。
//  · legacyDark 分量 == 重构前 Theme 的既有颜色（证明 Commit 1 零视觉变化）。
//

import XCTest
import Foundation
import SwiftUI
import UIKit
@testable import ZhishengWeather

final class ThemePaletteTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 每个用例从「缺失键」出发，避免跨用例污染。
        UserDefaults.standard.removeObject(forKey: AppearancePreference.key)
        Theme.activePalette = .dark
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppearancePreference.key)
        Theme.activePalette = .dark
        super.tearDown()
    }

    // MARK: - resolve 纯函数：全组合

    /// 显式「深色」档位：忽略系统深浅（系统浅色）。
    func testResolveDarkWithLightSystemYieldsDark() {
        XCTAssertEqual(ThemePalette.resolve(appearance: .dark, systemScheme: .light), .dark)
    }

    /// 显式「深色」档位：忽略系统深浅（系统深色）。
    func testResolveDarkWithDarkSystemYieldsDark() {
        XCTAssertEqual(ThemePalette.resolve(appearance: .dark, systemScheme: .dark), .dark)
    }

    /// 显式「浅色」档位：忽略系统深浅（系统深色）。
    func testResolveLightWithDarkSystemYieldsLight() {
        XCTAssertEqual(ThemePalette.resolve(appearance: .light, systemScheme: .dark), .light)
    }

    /// 显式「浅色」档位：忽略系统深浅（系统浅色）。
    func testResolveLightWithLightSystemYieldsLight() {
        XCTAssertEqual(ThemePalette.resolve(appearance: .light, systemScheme: .light), .light)
    }

    /// 「跟随系统」档位：系统浅色 → 浅色。
    func testResolveSystemWithLightSystemYieldsLight() {
        XCTAssertEqual(ThemePalette.resolve(appearance: .system, systemScheme: .light), .light)
    }

    /// 「跟随系统」档位：系统深色 → 深色。
    func testResolveSystemWithDarkSystemYieldsDark() {
        XCTAssertEqual(ThemePalette.resolve(appearance: .system, systemScheme: .dark), .dark)
    }

    // MARK: - 外观偏好：缺失键 / 未知值 → system

    /// 缺失键 → "system"（默认跟随系统）。
    func testAbsentAppearanceKeyYieldsSystem() {
        UserDefaults.standard.removeObject(forKey: AppearancePreference.key)
        XCTAssertEqual(AppearancePreference.appearance(), .system)
        XCTAssertEqual(AppearancePreference.appearance().rawValue, "system")
    }

    /// 未知存储值（如 "neon"）→ 回退 "system"。
    func testUnknownAppearanceValueFallsBackToSystem() {
        XCTAssertEqual(AppearancePreference.normalized("neon"), .system)
        UserDefaults.standard.set("neon", forKey: AppearancePreference.key)
        XCTAssertEqual(AppearancePreference.appearance(), .system)
    }

    /// 大小写不敏感归一化：存储 "LIGHT" 仍解析为 .light。
    func testAppearanceNormalizationIsCaseInsensitive() {
        XCTAssertEqual(AppearancePreference.normalized("LIGHT"), .light)
        XCTAssertEqual(AppearancePreference.normalized("Dark"), .dark)
    }

    /// 合法值往返（三档全覆盖）。
    func testAppearanceRoundTrip() {
        for setting in AppearanceSetting.allCases {
            AppearancePreference.setAppearance(setting)
            XCTAssertEqual(AppearancePreference.appearance(), setting)
        }
    }

    /// 持久化键名稳定，且**只**写 App 本地标准 UserDefaults（不入共享容器）。
    func testAppearanceKeyIsAppLocalNotSharedContainer() {
        XCTAssertEqual(AppearancePreference.key, "zs.weather.appearance")

        AppearancePreference.setAppearance(.light)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppearancePreference.key), "light")

        // 小组件只跟随系统，App 的「外观」设置不得写进 App Group 共享容器。
        let shared = UserDefaults(suiteName: AppGroup.identifier)
        XCTAssertNil(shared?.string(forKey: AppearancePreference.key))
    }

    // MARK: - Commit 1 回归守卫：深色抽层「零视觉变化」

    /// legacyDark 的 7 个分量必须与重构前 Theme 的既有颜色逐位一致。
    ///
    /// 期望值 = 重构前 `Theme` 的原始字面量（独立于实现重新写出，避免自证）。
    func testLegacyDarkPaletteMatchesPreRefactorTheme() {
        assertRGB(ThemePalette.legacyDark.background, 0.043, 0.059, 0.051)
        assertRGB(ThemePalette.legacyDark.surface, 0.086, 0.114, 0.098)
        assertRGB(ThemePalette.legacyDark.accent, 0.353, 0.976, 0.549)
        assertRGB(ThemePalette.legacyDark.accentSecondary, 0.251, 0.851, 0.925)
        assertRGB(ThemePalette.legacyDark.primaryText, 0.902, 0.980, 0.925)
        assertRGB(ThemePalette.legacyDark.secondaryText, 0.549, 0.678, 0.604)
        assertRGB(ThemePalette.legacyDark.divider, 0.180, 0.255, 0.208)
    }

    // MARK: - 三支配色与 Theme token 解析

    /// Theme token 经 activePalette 解析：切到浅色 → token 变为浅色值。
    func testThemeTokensFollowActivePalette() {
        Theme.activePalette = ThemePalette.palette(for: .light)
        assertRGB(Theme.background, hex(0xF2), hex(0xF5), hex(0xF3))
        assertRGB(Theme.accent, hex(0x0F), hex(0x6E), hex(0x56))
        assertRGB(Theme.primaryText, hex(0x16), hex(0x20), hex(0x1B))

        Theme.activePalette = ThemePalette.palette(for: .dark)
        assertRGB(Theme.background, hex(0x0A), hex(0x0B), hex(0x0C))
        assertRGB(Theme.accent, hex(0x45), hex(0xCE), hex(0x7C))
        assertRGB(Theme.primaryText, hex(0xED), hex(0xEF), hex(0xF2))
    }

    /// 浅色 · 清冷翡翠：7 个分量与给定 hex 精确一致。
    func testLightPaletteMatchesSpecifiedHex() {
        assertRGB(ThemePalette.light.background, hex(0xF2), hex(0xF5), hex(0xF3))
        assertRGB(ThemePalette.light.surface, hex(0xFF), hex(0xFF), hex(0xFF))
        assertRGB(ThemePalette.light.accent, hex(0x0F), hex(0x6E), hex(0x56))
        assertRGB(ThemePalette.light.accentSecondary, hex(0x1D), hex(0x9E), hex(0x75))
        assertRGB(ThemePalette.light.primaryText, hex(0x16), hex(0x20), hex(0x1B))
        assertRGB(ThemePalette.light.secondaryText, hex(0x5C), hex(0x6B), hex(0x63))
        assertRGB(ThemePalette.light.divider, hex(0xE2), hex(0xE8), hex(0xE4))
    }

    /// 深色 · 打磨磷光：7 个分量与给定 hex 精确一致。
    func testDarkPaletteMatchesSpecifiedHex() {
        assertRGB(ThemePalette.dark.background, hex(0x0A), hex(0x0B), hex(0x0C))
        assertRGB(ThemePalette.dark.surface, hex(0x17), hex(0x1A), hex(0x1D))
        assertRGB(ThemePalette.dark.accent, hex(0x45), hex(0xCE), hex(0x7C))
        assertRGB(ThemePalette.dark.accentSecondary, hex(0x5F), hex(0xB8), hex(0xD6))
        assertRGB(ThemePalette.dark.primaryText, hex(0xED), hex(0xEF), hex(0xF2))
        assertRGB(ThemePalette.dark.secondaryText, hex(0x8B), hex(0x93), hex(0x9B))
        assertRGB(ThemePalette.dark.divider, hex(0x23), hex(0x28), hex(0x2C))
    }

    // MARK: - 工具

    /// 8bit hex 分量 → 0…1。
    private func hex(_ value: Int) -> Double {
        Double(value) / 255.0
    }

    /// 断言 `Color` 的 sRGB 分量（经 UIColor 桥接提取）等于期望值。
    ///
    /// 容差 1e-3：覆盖 Color↔UIColor↔sRGB 的浮点/色彩空间往返误差，
    /// 同时仍把分量钉在规格的三位小数精度上（相邻 8bit 档相差 ≈0.0039，
    /// 远大于该容差，不会把相邻色误判为相等）。
    private func assertRGB(_ color: Color,
                           _ red: Double,
                           _ green: Double,
                           _ blue: Double,
                           accuracy: Double = 1e-3,
                           file: StaticString = #filePath,
                           line: UInt = #line) {
        let uiColor = UIColor(color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        let resolved = uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertTrue(resolved, "无法解析颜色分量：\(uiColor)", file: file, line: line)
        XCTAssertEqual(Double(r), red, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(Double(g), green, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(Double(b), blue, accuracy: accuracy, file: file, line: line)
    }
}

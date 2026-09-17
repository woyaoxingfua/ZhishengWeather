//
//  WidgetLocationBuildProductTests.swift
//  ZhishengWeatherTests
//
//  「小组件扩展到底有没有在**构建产物**里声明要用定位」——对已编译产物的断言。
//
//  ── 为什么必须有这条测试（与备用图标那个缺陷**同一类**）─────────────────────
//  `NSWidgetWantsLocation` 是「配置驱动」的能力开关：它写在
//  `Config/ZhishengWeatherWidget-Info.plist` 里，由 Xcode 原样带进 appex 的
//  Info.plist。它的可怕之处在于**错了也不报错**：
//    · 漏写 → 不报错、不告警、编译通过、单测全绿，而小组件**永远拿不到定位**
//      （表现为「当前位置」总是显示空态，且没有任何线索指向 Info.plist）；
//    · 写成 false / 写成字符串 / 写进**宿主 App** 而不是扩展 → 同样全绿、同样无效。
//  上一个同类缺陷（`ca7f224`：备用图标被 actool 静默忽略）的教训正是：
//  **只有断言构建产物才能抓住这类缺陷**，纯映射单测永远抓不到。
//
//  故本文件**不**断言 project.yml 的文本，也**不**断言仓库里的 plist 文件 ——
//  只读**构建产物**里 appex 的 Info.plist。
//
//  ── 为什么还要顺带断言宿主 App 的用途说明 ──────────────────────────────────
//  Apple 的分工是：扩展声明 `NSWidgetWantsLocation`，**用途字符串放在宿主 App**
//  （`NSLocationWhenInUseUsageDescription`）。两者是「一套」：缺了后者，系统会在
//  真机上**拒绝**授权（同样是静默的）。故这里一并断言，防止「只补了一半」。
//
//  ⚠️ 定位不到被测 bundle 时**必须 XCTFail**：静默 skip 会退化成「永远为真的假绿」，
//  那正是这类缺陷的成因。
//

import Foundation
import XCTest

final class WidgetLocationBuildProductTests: XCTestCase {

    // MARK: - 常量

    /// 小组件扩展的 bundle id（与 project.yml 的 PRODUCT_BUNDLE_IDENTIFIER 逐字一致）。
    private static let widgetBundleID = "com.zhisheng.weather.widget"

    /// 扩展里必须声明的键（Apple 文档名，一字不改）。
    private static let locationKey = "NSWidgetWantsLocation"

    /// 宿主 App 必须提供的用途说明键（Apple：用途字符串放宿主 App，不放扩展）。
    private static let usageDescriptionKey = "NSLocationWhenInUseUsageDescription"

    // MARK: - 1. 产物里的 appex 声明了 NSWidgetWantsLocation（缺陷的直接判据）

    /// 小组件扩展的 Info.plist 必须含 `NSWidgetWantsLocation = true`。
    func testBuiltWidgetExtensionDeclaresWidgetWantsLocation() {
        guard let appex = locatedWidgetExtensionBundle() else { return }

        let flag = appex.object(forInfoDictionaryKey: Self.locationKey)

        XCTAssertNotNil(
            flag,
            """
            小组件扩展（\(Self.widgetBundleID)）的构建产物 Info.plist 里**没有**
            \(Self.locationKey)。后果：iOS 不会把定位更新提供给小组件 →
            「当前位置」实例**永远**显示空态，且不报错、不告警、CI 全绿。
            最可能的原因：该键漏写在 Config/ZhishengWeatherWidget-Info.plist，
            或写进了宿主 App（Config/ZhishengWeather-Info.plist）——
            按 Apple 的分工它**必须**在扩展里。
            """
        )
        guard let flag else { return }
        XCTAssertTrue(
            (flag as? Bool) ?? false,
            "\(Self.locationKey) 必须是 Boolean true；实际值是 \(flag)（类型 \(type(of: flag))）。"
            + "写成 false 或字符串都会让小组件拿不到定位，且不报错。"
        )
    }

    // MARK: - 2. 宿主 App 那一半（用途说明）也在产物里

    /// 宿主 App 的 Info.plist 必须有非空的 `NSLocationWhenInUseUsageDescription`。
    ///
    /// Apple 的分工：扩展声明「我要定位」，宿主 App 提供「为什么要用」的文案。
    /// 缺文案 → 系统不给授权 → 同样是静默失败。
    func testBuiltHostAppDeclaresLocationUsageDescription() {
        let app = Bundle.main

        let usage = app.object(forInfoDictionaryKey: Self.usageDescriptionKey)
        XCTAssertNotNil(
            usage,
            """
            宿主 App 的构建产物 Info.plist 里没有 \(Self.usageDescriptionKey)。
            Apple 要求定位的**用途说明放在宿主 App**（扩展只声明 \(Self.locationKey)）；
            缺了它，iOS 不会给出授权弹窗 → 小组件「当前位置」永远拿不到定位。
            """
        )
        guard let usage else { return }
        let text = (usage as? String) ?? ""
        XCTAssertFalse(
            text.isEmpty,
            "\(Self.usageDescriptionKey) 不能是空串（空文案同样会被系统视为未声明用途）"
        )
    }

    // MARK: - 定位被测的小组件扩展 bundle

    /// 定位**被测小组件扩展（appex）**；定位不到返回 nil，并在此处 XCTFail。
    ///
    /// 为什么 appex 一定能在测试进程里被找到（依据来自 project.yml，不是猜的）：
    ///   · 主 App 声明 `- target: ZhishengWeatherWidget, embed: true`
    ///     → 扩展被**嵌入** `ZhishengWeather.app/PlugIns/`；
    ///   · 测试 target 设了 `TEST_HOST` + `BUNDLE_LOADER` = `ZhishengWeather.app/...`
    ///     → 测试 bundle 被注入主 App 进程，`Bundle.main` 即 `ZhishengWeather.app`。
    /// 候选顺序（多路径是**有意**的：只认一条路径时，Xcode 换一次布局就会静默落空，
    /// 那就退化成「永远为真的假绿」）：
    ///   1. `Bundle.main.builtInPlugInsURL` 下的 `*.appex`；
    ///   2. 测试 bundle 所在目录及其上溯各层的 `PlugIns/` 下的 `*.appex`。
    /// 命中判据：`bundleIdentifier` == 扩展 id；再兜底一层「任意 `*.appex`」。
    private func locatedWidgetExtensionBundle() -> Bundle? {
        var candidates: [Bundle] = []

        if let plugIns = Bundle.main.builtInPlugInsURL {
            candidates.append(contentsOf: appexBundles(in: plugIns))
        }

        var url = Bundle(for: Self.self).bundleURL
        for _ in 0..<6 {
            candidates.append(contentsOf: appexBundles(in: url))
            url = url.deletingLastPathComponent()
            candidates.append(contentsOf: appexBundles(in: url.appendingPathComponent("PlugIns")))
        }

        if let hit = candidates.first(where: { $0.bundleIdentifier == Self.widgetBundleID }) {
            return hit
        }
        if let hit = candidates.first(where: { $0.bundleURL.pathExtension == "appex" }) {
            return hit
        }

        XCTFail("""
            定位不到被测小组件扩展（期望 CFBundleIdentifier = \(Self.widgetBundleID)）。
            已尝试：\(candidates.map { "\($0.bundleURL.lastPathComponent)(id=\($0.bundleIdentifier ?? "nil"))" })
            请检查 project.yml 里主 App 是否仍 `embed: true` 地依赖 ZhishengWeatherWidget；
            若产物布局已变，本测试的定位策略需同步更新 —— 但**不许**改成 skip。
            """)
        return nil
    }

    /// 列出某目录下的 `*.appex` bundle（目录不存在 / 读不了 → 空数组）。
    private func appexBundles(in directory: URL) -> [Bundle] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [])) ?? []
        return contents
            .filter { $0.pathExtension == "appex" }
            .compactMap { Bundle(url: $0) }
    }
}

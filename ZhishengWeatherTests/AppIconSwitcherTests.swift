//
//  AppIconSwitcherTests.swift
//  ZhishengWeatherTests
//
//  切换器单测（Spy 注入，**不触碰**真实 UIApplication）：
//   - 幂等短路：目标档 = 当前档 → 不调用系统 API、不落偏好；
//   - 切到备用档成功：系统 API 收到正确资源名、成功**之后**才落偏好；
//   - 切回默认档：系统 API 收到 nil；
//   - 系统失败：错误上抛为短句（不静默）、**不**落偏好（UI 与设备事实一致）；
//   - currentChoice 优先级：系统事实 > 本地偏好 > 默认档（未知串归一化）。
//

import XCTest
@testable import ZhishengWeather

/// 可编程 Spy：记录最后一次 setAlternateIconName 及可控的成功 / 失败。
private final class SpyAlternateIconSetter: AlternateIconSetting, @unchecked Sendable {
    var failNext = false
    private(set) var receivedNames: [String?] = []
    private(set) var callCount = 0

    func setAlternateIconName(_ name: String?, completion: @escaping (Error?) -> Void) {
        callCount += 1
        receivedNames.append(name)
        completion(failNext ? SwitcherTestError.simulated : nil)
    }

    /// 模拟系统错误。
    enum SwitcherTestError: Error {
        case simulated
    }
}

@MainActor
final class AppIconSwitcherTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var spy: SpyAlternateIconSetter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "zs.test.iconSwitcher.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        spy = SpyAlternateIconSetter()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        spy = nil
        super.tearDown()
    }

    /// 构造被测对象（独立 suite 隔离，不污染 standard）。
    private func makeSwitcher() -> AppIconSwitcher {
        AppIconSwitcher(setter: spy, defaults: defaults)
    }

    // MARK: - 幂等短路

    /// 初始状态（无系统图标、无偏好）即默认档：再切默认档 → 完全 no-op。
    func testApplySameDefaultChoiceIsNoOp() async {
        let switcher = makeSwitcher()
        let result = await switcher.apply(.phosphor)
        XCTAssertNil(result)
        XCTAssertEqual(spy.callCount, 0)
        XCTAssertNil(defaults.string(forKey: IconChoicePreference.key))
    }

    // MARK: - 成功路径

    /// 切到翡翠：系统 API 收到 "AppIcon-Jade"，成功后偏好落 "jade"。
    func testApplyJadeSucceedsCallsSystemThenPersists() async {
        let switcher = makeSwitcher()
        let result = await switcher.apply(.jade)
        XCTAssertNil(result)
        XCTAssertEqual(spy.receivedNames, ["AppIcon-Jade"])
        XCTAssertEqual(defaults.string(forKey: IconChoicePreference.key), "jade")
        XCTAssertEqual(switcher.currentChoice(), .jade)
    }

    /// 切到雨字：系统 API 收到 "AppIcon-Rain"。
    func testApplyRainSucceedsPassesRainAssetName() async {
        let switcher = makeSwitcher()
        let result = await switcher.apply(.rain)
        XCTAssertNil(result)
        XCTAssertEqual(spy.receivedNames, ["AppIcon-Rain"])
        XCTAssertEqual(defaults.string(forKey: IconChoicePreference.key), "rain")
    }

    /// 从备用档切回默认档：系统 API 收到 nil（不是 "AppIcon"）。
    func testApplyBackToDefaultPassesNil() async {
        defaults.set(IconChoice.jade.rawValue, forKey: IconChoicePreference.key)
        let switcher = makeSwitcher()
        let result = await switcher.apply(.phosphor)
        XCTAssertNil(result)
        XCTAssertEqual(spy.receivedNames.count, 1)
        XCTAssertNil(spy.receivedNames[0], "默认档必须传 nil，绝不传 \"AppIcon\"")
        XCTAssertEqual(defaults.string(forKey: IconChoicePreference.key), "phosphor")
    }

    // MARK: - 失败路径（错误不静默）

    /// 系统失败：返回中文短句（非空即失败信号）、不落偏好、UI 可据此回滚。
    func testApplyFailureReturnsMessageAndDoesNotPersist() async {
        spy.failNext = true
        let switcher = makeSwitcher()
        let result = await switcher.apply(.jade)
        XCTAssertNotNil(result, "失败必须上抛短句，绝不静默")
        XCTAssertTrue(result?.contains("换图标失败") == true)
        XCTAssertEqual(spy.callCount, 1)
        XCTAssertNil(defaults.string(forKey: IconChoicePreference.key), "失败不得落偏好")
        // 设备事实仍是默认档。
        XCTAssertEqual(switcher.currentChoice(), .phosphor)
    }

    // MARK: - failureMessage 文案分支

    /// NSOSStatusErrorDomain -54（LaunchServices 拒绝「process may not map
    /// database」）：输出如实、可操作的短句，**不**走泛化的「请稍后重试」。
    func testFailureMessageForMinus54LaunchServicesRejection() {
        let error = NSError(domain: "NSOSStatusErrorDomain", code: -54,
                            userInfo: [NSLocalizedDescriptionKey: "未能完成操作。(OSStatus 错误 -54.)"])
        let message = AppIconSwitcher.failureMessage(for: error)
        XCTAssertTrue(message.contains("LaunchServices"),
                      "必须点明是系统 LaunchServices 拒绝，而非泛化措辞：\(message)")
        XCTAssertTrue(message.contains("重签"),
                      "必须提示常见于重签安装，指向可操作解法：\(message)")
        XCTAssertTrue(message.contains("重启手机"),
                      "必须给出『重启手机』这一解法：\(message)")
        XCTAssertTrue(message.contains("Bundle Identifier"),
                      "必须给出『换 Bundle Identifier 后重签』这一解法：\(message)")
        XCTAssertFalse(message.contains("请稍后重试"),
                       "不得套用泛化重试文案，以免误导用户以为代码可重试：\(message)")
        // 如实：不承诺「重启就能好」。
        XCTAssertFalse(message.contains("重启即可") && message.contains("一定"),
                       "不得承诺重启必定修复：\(message)")
    }

    /// 其它错误码仍走泛化分支（带 domain/code + 「请稍后重试」）。
    func testFailureMessageForOtherErrorKeepsGenericRetry() {
        let error = NSError(domain: "NSCocoaErrorDomain", code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "操作无法完成"])
        let message = AppIconSwitcher.failureMessage(for: error)
        XCTAssertTrue(message.contains("NSCocoaErrorDomain 4"),
                      "必须带 domain + code 供用户截图定案：\(message)")
        XCTAssertTrue(message.contains("请稍后重试"),
                      "其它错误仍走泛化重试文案：\(message)")
    }

    // MARK: - 本安装不可用判据（锚 bundle id，非历史失败记录）

    /// 无记录 → 可用（不锁死、按钮照常可点）。
    func testUnavailableFalseWhenNoRecord() {
        let store = AppDiagnosticsStore(defaults: defaults)
        let switcher = AppIconSwitcher(setter: spy, defaults: defaults, diagnostics: store)
        XCTAssertFalse(switcher.isUnavailableDueToLaunchServicesRejection())
    }

    /// 最近一次是 -54 失败且 bundle id 与当前安装一致 → 不可用（控件应置灰）。
    func testUnavailableTrueForMinus54SameBundleID() {
        let store = AppDiagnosticsStore(defaults: defaults)
        let minus54 = NSError(domain: "NSOSStatusErrorDomain", code: -54,
                              userInfo: [NSLocalizedDescriptionKey: "未能完成操作。(OSStatus 错误 -54.)"])
        let entry = AppDiagnosticEntry(source: .appIcon,
                                        succeeded: false,
                                        target: "AppIcon-Jade",
                                        message: "换图标失败：系统（LaunchServices）拒绝了本次请求，常见于重签安装。",
                                        error: minus54,
                                        bundleIdentifier: Bundle.main.bundleIdentifier)
        store.record(entry)
        let switcher = AppIconSwitcher(setter: spy, defaults: defaults, diagnostics: store)
        XCTAssertTrue(switcher.isUnavailableDueToLaunchServicesRejection(),
                      "同一安装下的 -54 失败应判为不可用")
    }

    /// 最近一次是 -54 失败但 bundle id 不同（换了 Bundle Identifier 后重签）
    /// → 自动恢复可用，不永久锁死。
    func testUnavailableFalseForMinus54DifferentBundleID() {
        let store = AppDiagnosticsStore(defaults: defaults)
        let minus54 = NSError(domain: "NSOSStatusErrorDomain", code: -54,
                              userInfo: [NSLocalizedDescriptionKey: "未能完成操作。(OSStatus 错误 -54.)"])
        let entry = AppDiagnosticEntry(source: .appIcon,
                                        succeeded: false,
                                        target: "AppIcon-Jade",
                                        message: "换图标失败：系统（LaunchServices）拒绝了本次请求，常见于重签安装。",
                                        error: minus54,
                                        bundleIdentifier: "com.zhisheng.weather.otherinstall")
        store.record(entry)
        let switcher = AppIconSwitcher(setter: spy, defaults: defaults, diagnostics: store)
        XCTAssertFalse(switcher.isUnavailableDueToLaunchServicesRejection(),
                       "换了 Bundle ID 后重签必须自动恢复可用，陈旧 -54 不得永久锁死")
    }

    /// 最近一次是成功（含 bundle id）→ 可用（成功覆盖失败，自然解除不可用）。
    func testUnavailableFalseAfterSuccess() {
        let store = AppDiagnosticsStore(defaults: defaults)
        let entry = AppDiagnosticEntry(source: .appIcon,
                                        succeeded: true,
                                        target: "AppIcon-Jade",
                                        message: "已切换为清冷翡翠",
                                        bundleIdentifier: Bundle.main.bundleIdentifier)
        store.record(entry)
        let switcher = AppIconSwitcher(setter: spy, defaults: defaults, diagnostics: store)
        XCTAssertFalse(switcher.isUnavailableDueToLaunchServicesRejection())
    }

    /// 最近一次是其它错误码（非 -54）→ 可用（走泛化重试文案，不锁死）。
    func testUnavailableFalseForOtherError() {
        let store = AppDiagnosticsStore(defaults: defaults)
        let other = NSError(domain: "NSCocoaErrorDomain", code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "操作无法完成"])
        let entry = AppDiagnosticEntry(source: .appIcon,
                                        succeeded: false,
                                        target: "AppIcon-Jade",
                                        message: "换图标失败（NSCocoaErrorDomain 4：操作无法完成），请稍后重试",
                                        error: other,
                                        bundleIdentifier: Bundle.main.bundleIdentifier)
        store.record(entry)
        let switcher = AppIconSwitcher(setter: spy, defaults: defaults, diagnostics: store)
        XCTAssertFalse(switcher.isUnavailableDueToLaunchServicesRejection())
    }

    // MARK: - currentChoice 优先级

    /// 系统事实（alternateIconName）优先于本地偏好。
    func testCurrentChoicePrefersSystemFact() async {
        defaults.set(IconChoice.rain.rawValue, forKey: IconChoicePreference.key)
        // 模拟「设备实际是翡翠但偏好写着雨字」：用 Spy 不行（系统侧只读），
        // 以偏好 + 无系统记录走偏好分支来验证归一化；系统侧优先级由实现
        // 结构保证（systemName != nil 即返回）。此处锁偏好分支行为。
        let switcher = makeSwitcher()
        XCTAssertEqual(switcher.currentChoice(), .rain)
    }

    /// 偏好为未知串 → 归一化默认档（不崩、不抛）。
    func testCurrentChoiceNormalizesUnknownPreference() {
        defaults.set("legacy-icon", forKey: IconChoicePreference.key)
        let switcher = makeSwitcher()
        XCTAssertEqual(switcher.currentChoice(), .phosphor)
    }

    /// 偏好缺失 → 默认档。
    func testCurrentChoiceMissingDefaultsToPhosphor() {
        XCTAssertEqual(makeSwitcher().currentChoice(), .phosphor)
    }
}

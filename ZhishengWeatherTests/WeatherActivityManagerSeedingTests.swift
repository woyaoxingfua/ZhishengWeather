//
//  WeatherActivityManagerSeedingTests.swift
//  ZhishengWeatherTests
//
//  针对「开了开关却一直空」的修复做单测（Task 4）：
//  - 开关开着但还没有任何取数结果时，`pushLatestIfRunning` 必须**如实留痕**
//    「尚无天气数据，无法推送（字段非空 0/4）」，而不是假装更新成功；
//  - 开关关着时 `pushLatestIfRunning` 是 no-op（不推送、不留痕）。
//
//  ⚠️ 刻意不触碰 `start` / `update` 的「有活动」分支：那些路径会调用
//  ActivityKit（`Activity.request` / `.activities`），在单元测试环境里不可靠；
//  本文件只覆盖「补推种子数据」的纯逻辑分支，确定性、可复现。
//

import XCTest
@testable import ZhishengWeather

@MainActor
final class WeatherActivityManagerSeedingTests: XCTestCase {

    /// 注入用的诊断记录套（独立 suite，避免污染 standard / 彼此串扰）。
    private var diagSuite: UserDefaults!
    private var diagSuiteName: String!
    /// 注入用的开关持久化套（与诊断记录同一注入原则：读写同一 store）。
    private var settingsSuite: UserDefaults!
    private var settingsSuiteName: String!

    override func setUp() {
        super.setUp()
        diagSuiteName = "zs.test.la.diag.\(UUID().uuidString)"
        settingsSuiteName = "zs.test.la.settings.\(UUID().uuidString)"
        diagSuite = UserDefaults(suiteName: diagSuiteName)
        settingsSuite = UserDefaults(suiteName: settingsSuiteName)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: diagSuiteName)
        UserDefaults.standard.removePersistentDomain(forName: settingsSuiteName)
        super.tearDown()
    }

    /// 开关开着、但尚未取到任何天气：补推必须如实报告「无数据」，并在诊断里标 0/4。
    func testPushLatestIfRunningWithoutDataRecordsZeroOfFour() async {
        let diagnostics = AppDiagnosticsStore(defaults: diagSuite)
        let settings = LiveActivitySettings(defaults: settingsSuite)
        let manager = WeatherActivityManager(settings: settings, diagnostics: diagnostics)
        settings.setEnabled(true) // 模拟用户在设置页打开了开关

        let message = await manager.pushLatestIfRunning()

        // 返回给用户看的提示：明确「无数据、没推送」，绝不伪装成功。
        XCTAssertEqual(message, WeatherActivityManager.noDataToPushMessage,
                       "开关开着但没取过数 → 必须如实说「尚无天气数据，无法推送」")
        // 诊断留痕：存在一条 liveActivity 记录，且 message 带「字段非空 0/4」。
        guard let entry = diagnostics.latest(for: .liveActivity) else {
            XCTFail("应当留下一条实时活动诊断记录")
            return
        }
        XCTAssertTrue(entry.message.contains("字段非空 0/4"),
                      "诊断文案必须带字段非空数，实际：\(entry.message)")
        XCTAssertFalse(entry.succeeded, "没有真正推送任何数据，不应记为成功")
    }

    /// 开关关着：补推是 no-op —— 不触碰 ActivityKit，也不留痕。
    func testPushLatestIfRunningWhenDisabledIsNoOp() async {
        let diagnostics = AppDiagnosticsStore(defaults: diagSuite)
        let settings = LiveActivitySettings(defaults: settingsSuite)
        let manager = WeatherActivityManager(settings: settings, diagnostics: diagnostics)
        // 不调用 setEnabled(true) → 开关默认关。

        let message = await manager.pushLatestIfRunning()

        XCTAssertNil(message, "开关没开就没有活动，补推应当静默返回 nil")
        XCTAssertNil(diagnostics.latest(for: .liveActivity),
                     "开关关着时不应写任何诊断记录")
    }
}

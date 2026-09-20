//
//  SourceHealthTrackerTests.swift
//  ZhishengWeatherTests
//
//  摘除判据 EV-1 / EV-3 + 账本坏 JSON 不覆盖写锚点（ARCH §7 T07 / §8 守卫⑥）：
//  - EV-1：连续 3 次缺字段 → 摘除；只连 2 次不摘；主源不参与自动摘除；
//  - EV-3：401/403 → .auth（本会话）；429 → 冷却 600s，冷却期内 isCoolingDown == true；
//  - 账本读坏 JSON → 空账本且**不覆盖写**。
//
//  所有时间经注入 now 判定（Core 禁 Date()）；隔离 UserDefaults suite。
//
//  ⚠️ 并发纪律（CI 修正，勿回退）：`XCTAssert*` 的实参是 **autoclosure，不支持并发** ——
//  任何 `await` 写在断言实参里都会编译失败（"'await' in an autoclosure that does not
//  support concurrency"），且 actor 隔离方法不能在同步非隔离上下文直接调用。
//  **正确写法**：先把 `await` 求值到局部常量，再对常量断言。
//  **禁止**用 `Task { }` / `XCTestExpectation` / 信号量绕过 —— 那会让断言在异步体执行前
//  就通过，测试变成永远绿的假测试（本仓库最忌讳的失败模式）。
//

import XCTest
@testable import ZhishengWeather

final class SourceHealthTrackerTests: XCTestCase {

    var suiteName: String = ""
    var defaults: UserDefaults?
    var tracker: SourceHealthTracker!

    override func setUpWithError() throws {
        let name = "zs.test.\(UUID().uuidString)"
        suiteName = name
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults = d
        tracker = SourceHealthTracker(ledger: SourceHealthLedger(defaults: d),
                                      preferences: SourcePreferences(defaults: d))
    }

    override func tearDown() {
        if let defaults, !suiteName.isEmpty {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        tracker = nil
        suiteName = ""
        super.tearDown()
    }

    // MARK: - EV-1

    func testEV1ThreeConsecutiveMissingExcludes() async {
        let now = Date()
        let first = await tracker.recordMissingFields(.sunriseSunset, missing: [.sunrise], at: now)
        XCTAssertNil(first)
        let second = await tracker.recordMissingFields(.sunriseSunset, missing: [.sunrise], at: now)
        XCTAssertNil(second)
        let third = await tracker.recordMissingFields(.sunriseSunset, missing: [.sunrise], at: now)
        XCTAssertEqual(third, .missingFields(consecutive: 3))
        let reason = await tracker.exclusionReason(for: .sunriseSunset, now: now)
        XCTAssertEqual(reason, .missingFields(consecutive: 3))
    }

    func testEV1OnlyTwoConsecutiveDoesNotExclude() async {
        let now = Date()
        let first = await tracker.recordMissingFields(.sunriseSunset, missing: [.sunrise], at: now)
        XCTAssertNil(first)
        let second = await tracker.recordMissingFields(.sunriseSunset, missing: [.sunrise], at: now)
        XCTAssertNil(second)
    }

    func testEV1PrimaryNotExcluded() async {
        // 自动摘除仅对辅助源生效（R-7）：主源连续缺字段也返回 nil。
        let now = Date()
        let first = await tracker.recordMissingFields(.openMeteoForecast, missing: [.sunrise], at: now)
        XCTAssertNil(first)
        let second = await tracker.recordMissingFields(.openMeteoForecast, missing: [.sunrise], at: now)
        XCTAssertNil(second)
        let third = await tracker.recordMissingFields(.openMeteoForecast, missing: [.sunrise], at: now)
        XCTAssertNil(third)
    }

    func testSuccessResetsMissingCount() async {
        let now = Date()
        _ = await tracker.recordMissingFields(.sunriseSunset, missing: [.sunrise], at: now)
        _ = await tracker.recordMissingFields(.sunriseSunset, missing: [.sunrise], at: now)
        await tracker.recordSuccess(.sunriseSunset, at: now) // 清零
        // 清零后再次缺失不触发摘除（需重新累计 3 次）。
        let afterReset = await tracker.recordMissingFields(.sunriseSunset, missing: [.sunrise], at: now)
        XCTAssertNil(afterReset)
    }

    // MARK: - EV-3

    func testEV3AuthImmediatelyExcludes() async {
        let now = Date()
        let reason = await tracker.recordHTTPStatus(.sunriseSunset, status: 401, at: now)
        XCTAssertEqual(reason, .auth)
        let exclusion = await tracker.exclusionReason(for: .sunriseSunset, now: now)
        XCTAssertEqual(exclusion, .auth)

        let reason2 = await tracker.recordHTTPStatus(.sunriseSunset, status: 403, at: now)
        XCTAssertEqual(reason2, .auth)
    }

    func testEV3RateLimitCooldown() async {
        let now = Date()
        let rate = await tracker.recordHTTPStatus(.sunriseSunset, status: 429, at: now)
        XCTAssertEqual(rate, .rateLimit(until: now.addingTimeInterval(600)))

        let coolingNow = await tracker.isCoolingDown(.sunriseSunset, now: now)
        XCTAssertTrue(coolingNow)
        let coolingMidway = await tracker.isCoolingDown(.sunriseSunset,
                                                        now: now.addingTimeInterval(300))
        XCTAssertTrue(coolingMidway)
        let coolingExpired = await tracker.isCoolingDown(.sunriseSunset,
                                                         now: now.addingTimeInterval(700))
        XCTAssertFalse(coolingExpired)
    }

    func testUserDisabledExclusion() async throws {
        let now = Date()
        SourcePreferences(defaults: try XCTUnwrap(defaults)).setDisabled(.sunriseSunset, disabled: true)
        let reason = await tracker.exclusionReason(for: .sunriseSunset, now: now)
        XCTAssertEqual(reason, .userDisabled)
    }

    // MARK: - 账本鲁棒性

    func testBadJSONLedgerReturnsEmptyAndDoesNotOverwrite() throws {
        let d = try XCTUnwrap(defaults)
        let corrupt = Data("garbage".utf8)
        d.set(corrupt, forKey: SourceHealthLedger.storeKey)

        let ledger = SourceHealthLedger(defaults: d)
        XCTAssertEqual(ledger.loadAll(), [:], "坏 JSON → 空账本")
        // 关键：读取路径绝不覆盖写，坏字节原样保留。
        XCTAssertEqual(d.data(forKey: SourceHealthLedger.storeKey), corrupt, "坏 JSON 读取不得覆盖写")
    }
}

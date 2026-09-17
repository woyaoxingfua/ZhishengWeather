//
//  UmbrellaReminderSchedulerTests.swift
//  ZhishengWeatherTests
//
//  调度器单测（Spy 注入，**不触碰**真实 UNUserNotificationCenter）：
//   - 开关关闭 → 不申请权限、不调度；
//   - 开关缺省 → 默认开；
//   - 权限拒绝 → 不调度 + 记忆拒绝（本会话不再重复申请）；
//   - 权限授予 → 以固定 id 调度一次（同 id 替换语义由系统保证，此处锁 id 不变）；
//   - shouldFire == false → 完全 no-op。
//

import XCTest
import UserNotifications
@testable import ZhishengWeather

/// 可编程 Spy：记录权限申请次数与最后一次 add 调用。
private final class SpyNotificationCenter: NotificationCentering, @unchecked Sendable {
    var authorizationRequestCount = 0
    var grantedResponse = true
    private(set) var addedCalls: [(identifier: String, title: String, body: String)] = []
    private(set) var addCallCount = 0

    func requestAuthorization() async -> Bool {
        authorizationRequestCount += 1
        return grantedResponse
    }

    func add(identifier: String, title: String, body: String,
             trigger: UNNotificationTrigger?) async throws {
        addCallCount += 1
        addedCalls.append((identifier, title, body))
    }
}

@MainActor
final class UmbrellaReminderSchedulerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "zs.test.umbrella.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// 一个 shouldFire == true 的决策。
    private func fireDecision() -> UmbrellaReminderEngine.Decision {
        UmbrellaReminderEngine.Decision(
            shouldFire: true,
            title: "带伞提醒",
            body: "约 14:30 开始下雨，出门带伞（未来 2 小时 · 由逐小时插值，非实况外推）",
            onset: Date(timeIntervalSince1970: 1_700_001_800)
        )
    }

    // MARK: - 开关

    func testEnabledByDefault() {
        let scheduler = UmbrellaReminderScheduler(
            center: SpyNotificationCenter(), defaults: defaults)
        XCTAssertTrue(scheduler.isEnabled, "开关缺省必须为开")
    }

    func testDisabledSchedulerSkipsEverything() async {
        let spy = SpyNotificationCenter()
        let scheduler = UmbrellaReminderScheduler(center: spy, defaults: defaults)
        scheduler.setEnabled(false)
        XCTAssertFalse(scheduler.isEnabled)

        await scheduler.scheduleIfDecided(fireDecision(), onsetDelay: 1800)

        XCTAssertEqual(spy.authorizationRequestCount, 0, "开关关 → 不申请权限")
        XCTAssertEqual(spy.addCallCount, 0, "开关关 → 不调度")
    }

    // MARK: - 权限懒请求与拒绝记忆

    func testPermissionDeniedSkipsAndIsRemembered() async throws {
        let spy = SpyNotificationCenter()
        spy.grantedResponse = false
        let scheduler = UmbrellaReminderScheduler(center: spy, defaults: defaults)

        await scheduler.scheduleIfDecided(fireDecision(), onsetDelay: 1800)

        XCTAssertEqual(spy.authorizationRequestCount, 1)
        XCTAssertEqual(spy.addCallCount, 0, "权限被拒 → 不调度")

        // 第二次调用：不再重复申请（拒绝已记忆）。
        await scheduler.scheduleIfDecided(fireDecision(), onsetDelay: 1800)
        XCTAssertEqual(spy.authorizationRequestCount, 1,
                       "曾被拒后本会话内不得重复弹权限申请")
    }

    func testPermissionGrantedSchedulesWithFixedIdentifier() async throws {
        let spy = SpyNotificationCenter()
        let scheduler = UmbrellaReminderScheduler(center: spy, defaults: defaults)

        await scheduler.scheduleIfDecided(fireDecision(), onsetDelay: 1800)

        XCTAssertEqual(spy.authorizationRequestCount, 1)
        XCTAssertEqual(spy.addCallCount, 1)
        let call = try XCTUnwrap(spy.addedCalls.first)
        XCTAssertEqual(call.identifier, UmbrellaReminderScheduler.notificationIdentifier,
                       "必须用固定 id（同 id 替换旧提醒）")
        XCTAssertEqual(call.title, "带伞提醒")
        XCTAssertTrue(call.body.contains("由逐小时插值"))
    }

    // MARK: - no-op

    func testNoDecisionIsNoOp() async {
        let spy = SpyNotificationCenter()
        let scheduler = UmbrellaReminderScheduler(center: spy, defaults: defaults)

        await scheduler.scheduleIfDecided(.none, onsetDelay: 1800)

        XCTAssertEqual(spy.authorizationRequestCount, 0)
        XCTAssertEqual(spy.addCallCount, 0)
    }
}

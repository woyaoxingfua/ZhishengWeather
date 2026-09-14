//
//  AppRouterTests.swift
//  ZhishengWeatherTests
//
//  AppRouter 单测：快捷方式映射、单调 UUID 令牌（P1-B）、consume 消费、
//  深链路由（A1-7 / A1-8）。
//
//  说明：AppRouter 为 @MainActor 单例，用例间用 searchCity consume 清空
//  pendingRoute，避免跨用例串状态；viewModel 注入 Stub 服务防真机网络。
//

import XCTest
@testable import ZhishengWeather

@MainActor
final class AppRouterTests: XCTestCase {

    private var store: AppGroupStore!
    private var viewModel: WeatherViewModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let name = "zs.test.router.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name), "无法创建临时 suite")
        store = AppGroupStore(defaults: defaults)
        // 注入 Stub 服务，避免 handle 调 refresh() 触发真实网络（即使 Task 未 await 也不污染）。
        viewModel = WeatherViewModel(service: StubWeatherService(), store: store, locationProvider: nil)

        // 清空单例状态，保证用例隔离（consume searchCity 不会触发网络）。
        AppRouter.shared.handleShortcut(type: AppRouter.shortcutTypeSearch)
        _ = AppRouter.shared.consume(AppRouter.shared.pendingRoute, viewModel: viewModel)
        XCTAssertNil(AppRouter.shared.pendingRoute)
    }

    override func tearDown() {
        AppRouter.shared.handleShortcut(type: AppRouter.shortcutTypeSearch)
        _ = AppRouter.shared.consume(AppRouter.shared.pendingRoute, viewModel: viewModel)
        store = nil
        viewModel = nil
        super.tearDown()
    }

    // MARK: - 快捷方式映射

    func testShortcutMapping() {
        let router = AppRouter.shared
        router.handleShortcut(type: AppRouter.shortcutTypeRefresh)
        XCTAssertEqual(router.pendingRoute?.route, .refresh)

        router.handleShortcut(type: AppRouter.shortcutTypeSearch)
        XCTAssertEqual(router.pendingRoute?.route, .searchCity)

        router.handleShortcut(type: AppRouter.shortcutTypeSettings)
        XCTAssertEqual(router.pendingRoute?.route, .settings)
    }

    func testUnknownShortcutDoesNotOverwriteExistingRoute() {
        let router = AppRouter.shared
        router.handleShortcut(type: AppRouter.shortcutTypeRefresh)
        XCTAssertEqual(router.pendingRoute?.route, .refresh)

        router.handleShortcut(type: "com.zhisheng.weather.shortcut.unknown")
        XCTAssertEqual(router.pendingRoute?.route, .refresh, "未知 type 不应改写既有 pendingRoute")
    }

    // MARK: - 单调 UUID 令牌（P1-B：解决同值 onChange 抑制丢事件）

    func testHandleShortcutGeneratesNewUUIDEachCall() {
        let router = AppRouter.shared
        router.handleShortcut(type: AppRouter.shortcutTypeRefresh)
        let firstID = router.pendingRoute?.id
        router.handleShortcut(type: AppRouter.shortcutTypeRefresh)
        let secondID = router.pendingRoute?.id

        XCTAssertNotNil(firstID)
        XCTAssertNotEqual(firstID, secondID,
                         "连续同目的地必须生成新 UUID，否则 @Observable 同值抑制会丢触发")
    }

    func testPendingRouteIsEquatableByValueForChangeDetection() {
        let a = AppRouter.PendingRoute(route: .refresh)
        let b = AppRouter.PendingRoute(route: .refresh)
        XCTAssertNotEqual(a, b, "同 route 不同 UUID 应判为不同（驱动 onChange 触发）")
        let c = AppRouter.PendingRoute(route: .searchCity)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - consume 消费

    func testConsumeNilReturnsNilAndKeepsState() {
        let router = AppRouter.shared
        let result = router.consume(nil, viewModel: viewModel)
        XCTAssertNil(result)
        XCTAssertNil(router.pendingRoute, "无待处理时 pendingRoute 应保持 nil")
    }

    func testConsumeReturnsNavigationRouteAndClearsPending() {
        let router = AppRouter.shared
        router.handleShortcut(type: AppRouter.shortcutTypeSearch)
        let pending = router.pendingRoute
        let result = router.consume(pending, viewModel: viewModel)

        XCTAssertEqual(result, .searchCity, "searchCity 应作为跳转路由返回给调用方做 push")
        XCTAssertNil(router.pendingRoute, "消费后 pendingRoute 必须置 nil 防重复触发")
    }

    func testConsumeSettingsReturnsRouteAndClearsPending() {
        let router = AppRouter.shared
        router.handleShortcut(type: AppRouter.shortcutTypeSettings)
        let pending = router.pendingRoute
        let result = router.consume(pending, viewModel: viewModel)

        XCTAssertEqual(result, .settings)
        XCTAssertNil(router.pendingRoute)
    }

    func testConsumeRefreshReturnsNilAndClearsPending() {
        let router = AppRouter.shared
        router.handleShortcut(type: AppRouter.shortcutTypeRefresh)
        let pending = router.pendingRoute
        let result = router.consume(pending, viewModel: viewModel)

        XCTAssertNil(result, "refresh 类由 consume 内部强刷，不向调用方返回路由")
        XCTAssertNil(router.pendingRoute, "refresh 消费后同样应置 nil")
    }

    // MARK: - 深链

    func testHandleDeepLinkRefreshDoesNotUsePendingRoute() {
        let router = AppRouter.shared
        // 深链经 .onOpenURL → handle，直接强刷，不经 pendingRoute 通道。
        router.handle(url: URL(string: AppRouter.refreshURLString)!, viewModel: viewModel)
        XCTAssertNil(router.pendingRoute, "深链刷新不应写入 pendingRoute（与快捷方式通道隔离）")
    }

    func testHandleDeepLinkIgnoresWrongSchemeAndHost() {
        let router = AppRouter.shared
        router.handle(url: URL(string: "https://example.com")!, viewModel: viewModel)
        XCTAssertNil(router.pendingRoute)

        router.handle(url: URL(string: "zhisheng://other")!, viewModel: viewModel)
        XCTAssertNil(router.pendingRoute, "scheme 对但 host 非 refresh 应被忽略")
    }
}

/// AppRouter 测试用取数桩：立即返回样本快照，杜绝真实网络。
private struct StubWeatherService: WeatherProviding {
    func fetch(latitude: Double, longitude: Double) async throws -> WeatherSnapshot {
        WeatherSnapshot(
            location: .beijing,
            temperature: 20,
            apparentTemperature: 19,
            weatherCode: 1,
            windSpeed: 2,
            windDirection: 90,
            humidity: 50,
            isDay: true,
            hourly: [HourlyPoint(time: Date(), temperature: 20, weatherCode: 1)],
            dailyHigh: 25,
            dailyLow: 15,
            fetchedAt: Date()
        )
    }
}

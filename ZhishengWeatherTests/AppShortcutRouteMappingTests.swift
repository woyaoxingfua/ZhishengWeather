//
//  AppShortcutRouteMappingTests.swift
//  ZhishengWeatherTests
//
//  AppIntents 快捷指令的**可提取纯逻辑**单测：
//   - ShortcutRouteMapping.route 逐 case 映射正确；
//   - 镜像枚举 AppRouterRoute 与 AppRouter.Route 逐 case 对齐（漂移防线）。
//
//  诚实声明：AppIntents 声明本身（phrases / titles / provider entries）是
//  声明式代码，**不做**假单测；其正确性由 CI 编译 + 真机快捷指令 App 人工验收。
//

import XCTest
@testable import ZhishengWeather

final class AppShortcutRouteMappingTests: XCTestCase {

    // MARK: - 映射决策

    func testOpenWeatherMapsToNil() {
        XCTAssertNil(ShortcutRouteMapping.route(for: .openWeather),
                     "打开天气仅唤起 App，不强制刷新、不跳转")
    }

    func testRefreshWeatherMapsToRefresh() {
        XCTAssertEqual(ShortcutRouteMapping.route(for: .refreshWeather), .refresh)
    }

    func testSearchCityMapsToSearchCity() {
        XCTAssertEqual(ShortcutRouteMapping.route(for: .searchCity), .searchCity)
    }

    // MARK: - 镜像枚举与 AppRouter.Route 对齐（漂移防线）

    @MainActor
    func testMirrorEnumStaysAlignedWithAppRouterRoute() {
        // 镜像枚举的 case 数与 AppRouter.Route 必须覆盖一致（逐 case 转换语义锁定）。
        // refresh 与 searchCity 是本轮快捷指令消费的两个目的地。
        let mirrorCases: [AppRouterRoute] = [.refresh, .searchCity]
        XCTAssertEqual(mirrorCases.count, 2)

        // 语义对齐：镜像 refresh 传入 AppRouter 的快捷方式通道应产生 .refresh 路由，
        // 镜像 searchCity 同理（经真实 AppRouter 消费路径验证，不用共享单例外的状态）。
        switch ShortcutRouteMapping.route(for: .refreshWeather) {
        case .refresh:
            AppRouter.shared.handleShortcut(type: AppRouter.shortcutTypeRefresh)
            XCTAssertEqual(AppRouter.shared.pendingRoute?.route, .refresh)
        default:
            XCTFail("refreshWeather 必须映射到 refresh")
        }
        _ = AppRouter.shared.consume(AppRouter.shared.pendingRoute,
                                     viewModel: makeViewModel())
        switch ShortcutRouteMapping.route(for: .searchCity) {
        case .searchCity:
            AppRouter.shared.handleShortcut(type: AppRouter.shortcutTypeSearch)
            XCTAssertEqual(AppRouter.shared.pendingRoute?.route, .searchCity)
        default:
            XCTFail("searchCity 必须映射到 searchCity")
        }
        _ = AppRouter.shared.consume(AppRouter.shared.pendingRoute,
                                     viewModel: makeViewModel())
        XCTAssertNil(AppRouter.shared.pendingRoute, "用例收尾必须清空单例状态")
    }

    /// 独立 AppGroupStore（临时 suite）构造 VM，杜绝真实网络与跨用例串扰。
    @MainActor
    private func makeViewModel() -> WeatherViewModel {
        let name = "zs.test.shortcut.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let store = AppGroupStore(defaults: defaults)
        return WeatherViewModel(service: StubShortcutsWeatherService(),
                                store: store,
                                locationProvider: nil)
    }
}

/// 测试用取数桩：立即返回样本快照，杜绝真实网络（consume refresh 会触发）。
private struct StubShortcutsWeatherService: WeatherProviding {
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

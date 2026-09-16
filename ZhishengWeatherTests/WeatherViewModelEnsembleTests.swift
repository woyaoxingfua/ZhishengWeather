//
//  WeatherViewModelEnsembleTests.swift
//  ZhishengWeatherTests
//
//  集合第三链路 VM 隔离与节奏（Stub 注入，**纯构造不联网**）：
//   - 失败隔离：集合失败绝不污染天气 state（主屏不受影响）；
//   - 成功经 selectedID 守门后落槽；
//   - 慢节奏：同城 3h 内不重复取数（配额守卫，绝不随 15min 主循环刷）；
//   - 跨城守卫：切城时旧城集合立即清空，不串号到新城。
//

import XCTest
@testable import ZhishengWeather

/// 可控的集合服务 Stub（可编程成功/失败 + 计数 + 可选延迟）。
private actor StubEnsemble: EnsembleProviding {
    enum Behavior {
        case success(EnsembleForecast)
        case failure(WeatherError)
    }
    private let behavior: Behavior
    private let delayNanoseconds: UInt64
    private var calls = 0

    init(_ behavior: Behavior, delayNanoseconds: UInt64 = 0) {
        self.behavior = behavior
        self.delayNanoseconds = delayNanoseconds
    }

    func fetch(latitude: Double, longitude: Double) async throws -> EnsembleForecast {
        calls += 1
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        switch behavior {
        case .success(let forecast): return forecast
        case .failure(let error): throw error
        }
    }

    /// 已发生的取数次数。
    func callCount() -> Int { calls }
}

/// 空气服务 Stub（恒失败）——只为阻断真实网络，测试不关心其值。
private actor StubAir: AirQualityProviding {
    func fetch(latitude: Double, longitude: Double) async throws -> AirQuality {
        throw WeatherError.badStatus(503)
    }
}

/// 可控的天气服务 Stub。
private actor StubWeather: WeatherProviding {
    private let snapshot: WeatherSnapshot
    init(snapshot: WeatherSnapshot) { self.snapshot = snapshot }
    func fetch(latitude: Double, longitude: Double) async throws -> WeatherSnapshot {
        snapshot
    }
}

@MainActor
final class WeatherViewModelEnsembleTests: XCTestCase {

    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSnapshot() -> WeatherSnapshot {
        WeatherSnapshot(location: .beijing,
                        temperature: 23.0, apparentTemperature: 22.0,
                        weatherCode: 1, windSpeed: 2.0, windDirection: 90.0,
                        humidity: 50, isDay: true, hourly: [],
                        dailyHigh: 25.0, dailyLow: 15.0, daily: nil,
                        fetchedAt: anchor)
    }

    private func makeStore() throws -> AppGroupStore {
        let name = "zs.test.ensemble.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return AppGroupStore(defaults: defaults)
    }

    /// 构造集合预报：`memberCount` 个成员、2 小时。
    private func makeForecast(memberCount: Int) -> EnsembleForecast {
        let times = [anchor, anchor.addingTimeInterval(3600)]
        let series: [[Double?]] = (0..<memberCount).map { index -> [Double?] in
            [Double(index) * 0.2, 0.5]
        }
        return EnsembleForecast(times: times, memberSeries: series, utcOffsetSeconds: 0)
    }

    private func makeViewModel(ensemble: StubEnsemble) throws -> WeatherViewModel {
        let store = try makeStore()
        return WeatherViewModel(service: StubWeather(snapshot: makeSnapshot()),
                                store: store,
                                locationProvider: LocationProvider(),
                                airService: StubAir(),
                                ensembleService: ensemble)
    }

    /// 轮询等待条件成立（默认 2s）。
    private func waitUntil(timeout: TimeInterval = 2,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func makeCity(_ name: String, latitude: Double, longitude: Double) -> City {
        City(name: name, latitude: latitude, longitude: longitude, isCurrentLocation: false)
    }

    // MARK: - 失败隔离（核心）

    func testEnsembleFailureDoesNotAffectWeatherState() async throws {
        let vm = try makeViewModel(ensemble: StubEnsemble(.failure(.badStatus(503))))

        // 用 addAndSelect（fetchAndApply 路径）避开单测环境定位授权 60s 超时。
        await vm.addAndSelect(makeCity("杭州", latitude: 30.25, longitude: 120.17))

        // 天气正常 .loaded；集合为 nil（失败隔离：绝不触碰 state）。
        guard case .loaded = vm.state else {
            XCTFail("天气 state 不应被集合失败污染，实际 \(vm.state)")
            return
        }
        XCTAssertNil(vm.displayedEnsemble, "集合失败后不应有集合数据")
    }

    // MARK: - 成功落槽

    func testEnsembleSuccessPopulatesWhenCityMatches() async throws {
        let vm = try makeViewModel(ensemble: StubEnsemble(.success(makeForecast(memberCount: 4))))

        await vm.addAndSelect(makeCity("杭州", latitude: 30.25, longitude: 120.17))
        await waitUntil { vm.displayedEnsemble != nil }

        XCTAssertEqual(vm.displayedEnsemble?.memberCount, 4)
        XCTAssertEqual(vm.displayedEnsemble?.times.count, 2)
    }

    // MARK: - 慢节奏（配额守卫）

    func testEnsembleCadenceSkipsRepeatFetchWithinWindow() async throws {
        let stub = StubEnsemble(.success(makeForecast(memberCount: 3)))
        let vm = try makeViewModel(ensemble: stub)

        let city = makeCity("杭州", latitude: 30.25, longitude: 120.17)
        await vm.addAndSelect(city)

        // 等待首次取数发生（轮询 actor 计数；不把 await 放进断言自动闭包）。
        let firstDeadline = Date().addingTimeInterval(2)
        while Date() < firstDeadline {
            if await stub.callCount() >= 1 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let afterFirst = await stub.callCount()
        XCTAssertEqual(afterFirst, 1, "首次刷新应发起一次集合请求")

        // 再次触发同一城市（模拟 15min 主循环刷新）：3h 慢节奏守卫应拦截。
        await vm.addAndSelect(city)
        try? await Task.sleep(nanoseconds: 150_000_000)

        let count = await stub.callCount()
        XCTAssertEqual(count, 1, "3h 慢节奏内同城不应重复发起 4.0 倍集合请求")
    }

    // MARK: - 跨城守卫（不串号）

    func testEnsembleClearedOnCitySwitchAndReplacedByNewCity() async throws {
        // 慢 Stub：切城后新城集合在途，先断言旧城已被清空（不串号），再等新城到达。
        let stub = StubEnsemble(.success(makeForecast(memberCount: 7)),
                                delayNanoseconds: 300_000_000)
        let vm = try makeViewModel(ensemble: stub)

        let cityA = makeCity("杭州", latitude: 30.25, longitude: 120.17)
        await vm.addAndSelect(cityA)
        await waitUntil { vm.displayedEnsemble != nil }
        XCTAssertEqual(vm.displayedEnsemble?.memberCount, 7)

        // 切到另一座城市：其集合在途（慢 Stub），期间旧城集合必须不可见（displayedEnsemble == nil）。
        let cityB = makeCity("北京", latitude: 39.90, longitude: 116.41)
        await vm.addAndSelect(cityB)
        try? await Task.sleep(nanoseconds: 60_000_000)   // 让新城集合 Task 起飞
        XCTAssertNil(vm.displayedEnsemble, "切城后旧城集合必须立即不可见（不串号）")

        // 新城集合到达后恢复可见。
        await waitUntil { vm.displayedEnsemble != nil }
        XCTAssertEqual(vm.displayedEnsemble?.memberCount, 7)
    }

    // MARK: - 归属守卫

    func testDisplayedEnsembleNilBeforeAnyLoad() throws {
        let vm = try makeViewModel(ensemble: StubEnsemble(.success(makeForecast(memberCount: 1))))
        XCTAssertNil(vm.displayedEnsemble, "未加载任何集合前不应可见")
    }
}

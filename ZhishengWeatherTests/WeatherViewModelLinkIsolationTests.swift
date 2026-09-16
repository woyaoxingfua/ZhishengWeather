//
//  WeatherViewModelLinkIsolationTests.swift
//  ZhishengWeatherTests
//
//  失败隔离的**跨链路**演练（本轮要求）：一条链路抛错时，其余链路的数据必须
//  留在屏上，且主链路 `state` 不被带崩。
//
//  与既有 WeatherViewModelAirTests / WeatherViewModelEnsembleTests 同源同款
//  （Stub 注入、纯构造不联网），此处补的是「**同时**投喂多链路、其中一个抛错」
//  的交叉断言——既有两份测试各自只覆盖「单条链路 vs 主链路」，没有覆盖
//  「副链路 A 失败时副链路 B 的数据是否存活」。
//
//  P-18 同源盲区纪律：断言的是**行为**（槽位是否存活 / state 是否保持），
//  不是实现内部的调用顺序。
//

import XCTest
@testable import ZhishengWeather

// MARK: - Stubs（可改写行为，便于「先成功后失败」）

/// 可控的天气服务 Stub（行为可中途改写）。
private actor StubWeather: WeatherProviding {
    enum Behavior {
        case success(WeatherSnapshot)
        case failure(WeatherError)
    }
    private var behavior: Behavior

    init(_ behavior: Behavior) { self.behavior = behavior }

    /// 改写后续行为（用于「先成功后失败」的降级演练）。
    func set(_ behavior: Behavior) { self.behavior = behavior }

    func fetch(latitude: Double, longitude: Double) async throws -> WeatherSnapshot {
        switch behavior {
        case .success(let snapshot): return snapshot
        case .failure(let error): throw error
        }
    }
}

/// 可控的空气服务 Stub。
private actor StubAir: AirQualityProviding {
    enum Behavior {
        case success(AirQuality)
        case failure(WeatherError)
    }
    private var behavior: Behavior

    init(_ behavior: Behavior) { self.behavior = behavior }

    func set(_ behavior: Behavior) { self.behavior = behavior }

    func fetch(latitude: Double, longitude: Double) async throws -> AirQuality {
        switch behavior {
        case .success(let air): return air
        case .failure(let error): throw error
        }
    }
}

/// 可控的集合服务 Stub。
private actor StubEnsemble: EnsembleProviding {
    enum Behavior {
        case success(EnsembleForecast)
        case failure(WeatherError)
    }
    private var behavior: Behavior

    init(_ behavior: Behavior) { self.behavior = behavior }

    func set(_ behavior: Behavior) { self.behavior = behavior }

    func fetch(latitude: Double, longitude: Double) async throws -> EnsembleForecast {
        switch behavior {
        case .success(let forecast): return forecast
        case .failure(let error): throw error
        }
    }
}

@MainActor
final class WeatherViewModelLinkIsolationTests: XCTestCase {

    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 构造

    private func makeSnapshot() -> WeatherSnapshot {
        WeatherSnapshot(location: .beijing,
                        temperature: 23.0, apparentTemperature: 22.0,
                        weatherCode: 1, windSpeed: 2.0, windDirection: 90.0,
                        humidity: 50, isDay: true, hourly: [],
                        dailyHigh: 25.0, dailyLow: 15.0, daily: nil,
                        fetchedAt: anchor)
    }

    private func makeAir(usAqi: Int) -> AirQuality {
        AirQuality(usAqi: usAqi, europeanAqi: 53, pm25: 30.9, pm10: 93.1,
                   carbonMonoxide: nil, nitrogenDioxide: nil,
                   sulphurDioxide: nil, ozone: nil)
    }

    private func makeForecast(memberCount: Int) -> EnsembleForecast {
        let times = [anchor, anchor.addingTimeInterval(3600)]
        let series: [[Double?]] = (0..<memberCount).map { index -> [Double?] in
            [Double(index) * 0.2, 0.5]
        }
        return EnsembleForecast(times: times, memberSeries: series, utcOffsetSeconds: 0)
    }

    private func makeCity(_ name: String, latitude: Double, longitude: Double) -> City {
        City(name: name, latitude: latitude, longitude: longitude, isCurrentLocation: false)
    }

    private func makeStore() throws -> AppGroupStore {
        let name = "zs.test.isolation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return AppGroupStore(defaults: defaults)
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

    // MARK: - 副链路 A 失败 → 副链路 B 的数据存活，主 state 保持 .loaded

    func testAirFailureKeepsEnsembleDataAndLoadedState() async throws {
        let vm = WeatherViewModel(service: StubWeather(.success(makeSnapshot())),
                                  store: try makeStore(),
                                  locationProvider: LocationProvider(),
                                  airService: StubAir(.failure(.badStatus(503))),
                                  ensembleService: StubEnsemble(.success(makeForecast(memberCount: 3))))

        // 用 addAndSelect（fetchAndApply 路径）避开单测环境定位授权 60s 超时。
        await vm.addAndSelect(makeCity("杭州", latitude: 30.25, longitude: 120.17))
        await waitUntil { vm.displayedEnsemble != nil }

        guard case .loaded = vm.state else {
            return XCTFail("空气失败不得污染主 state，实际 \(vm.state)")
        }
        XCTAssertNil(vm.airQuality, "空气链路失败 → 该链路槽位为空")
        XCTAssertEqual(vm.displayedEnsemble?.memberCount, 3,
                       "集合链路的数据必须存活（失败隔离的另一半）")
    }

    func testEnsembleFailureKeepsAirDataAndLoadedState() async throws {
        let vm = WeatherViewModel(service: StubWeather(.success(makeSnapshot())),
                                  store: try makeStore(),
                                  locationProvider: LocationProvider(),
                                  airService: StubAir(.success(makeAir(usAqi: 42))),
                                  ensembleService: StubEnsemble(.failure(.badStatus(503))))

        await vm.addAndSelect(makeCity("杭州", latitude: 30.25, longitude: 120.17))
        await waitUntil { vm.airQuality != nil }

        guard case .loaded = vm.state else {
            return XCTFail("集合失败不得污染主 state，实际 \(vm.state)")
        }
        XCTAssertEqual(vm.airQuality?.usAqi, 42, "空气链路的数据必须存活")
        XCTAssertNil(vm.displayedEnsemble, "集合链路失败 → 该链路槽位为空")
    }

    /// 两条副链路**同时**失败：主链路照常 .loaded，且主屏数据仍在。
    func testBothSecondaryLinksFailWhileMainStaysLoaded() async throws {
        let vm = WeatherViewModel(service: StubWeather(.success(makeSnapshot())),
                                  store: try makeStore(),
                                  locationProvider: LocationProvider(),
                                  airService: StubAir(.failure(.badStatus(503))),
                                  ensembleService: StubEnsemble(.failure(.timeout("超时"))))

        await vm.addAndSelect(makeCity("杭州", latitude: 30.25, longitude: 120.17))
        try? await Task.sleep(nanoseconds: 200_000_000)

        guard case .loaded = vm.state else {
            return XCTFail("两条副链路全失败也不得污染主 state，实际 \(vm.state)")
        }
        XCTAssertNil(vm.airQuality)
        XCTAssertNil(vm.displayedEnsemble)
    }

    // MARK: - 主链路失败 → 副链路已有数据仍在屏上（且保留可读缓存）

    func testMainLinkFailureKeepsSecondaryLinkData() async throws {
        let weather = StubWeather(.success(makeSnapshot()))
        let vm = WeatherViewModel(service: weather,
                                  store: try makeStore(),
                                  locationProvider: LocationProvider(),
                                  airService: StubAir(.success(makeAir(usAqi: 77))),
                                  ensembleService: StubEnsemble(.success(makeForecast(memberCount: 2))))

        let city = makeCity("杭州", latitude: 30.25, longitude: 120.17)
        await vm.addAndSelect(city)
        await waitUntil { vm.airQuality != nil && vm.displayedEnsemble != nil }
        guard case .loaded = vm.state else {
            return XCTFail("首轮三链路应全部可用，实际 \(vm.state)")
        }

        // 主链路转为失败，再次取数。
        await weather.set(.failure(.badStatus(500)))
        await vm.addAndSelect(city)

        guard case .failed(let cached, let message) = vm.state else {
            return XCTFail("主链路失败应置 .failed，实际 \(vm.state)")
        }
        XCTAssertNotNil(cached, "失败时必须保留可读缓存（绝不把可读数据换成错误屏）")
        XCTAssertFalse(message.isEmpty, "失败必须带按故障域给出的文案")

        // 副链路数据未被主链路失败清空（隔离纪律：副链路槽位不由主链路改写）。
        XCTAssertEqual(vm.airQuality?.usAqi, 77, "主链路失败不得清空空气数据")
        XCTAssertEqual(vm.displayedEnsemble?.memberCount, 2, "主链路失败不得清空集合数据")
    }
}

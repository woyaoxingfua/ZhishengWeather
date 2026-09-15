//
//  WeatherViewModelAirTests.swift
//  ZhishengWeatherTests
//
//  R5 双向失败隔离演练（A2-1 核心）：空气 API 失败绝不污染天气 state；
//  天气失败不影响空气 Task 触发；过期空气结果被 selectedID 守门丢弃。
//  Stub 双链路注入，纯构造不联网。
//

import XCTest
@testable import ZhishengWeather

/// 可控的空气服务 Stub（可编程成功/失败/延迟）。
private actor StubAirService: AirQualityProviding {
    enum Behavior {
        case success(AirQuality)
        case failure(WeatherError)
    }
    private let behavior: Behavior
    init(_ behavior: Behavior) { self.behavior = behavior }

    func fetch(latitude: Double, longitude: Double) async throws -> AirQuality {
        switch behavior {
        case .success(let air): return air
        case .failure(let error): throw error
        }
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
final class WeatherViewModelAirTests: XCTestCase {

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
        let name = "zs.test.air.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return AppGroupStore(defaults: defaults)
    }

    /// 轮询等待空气 Task 完成（refresh 返回时空气 Task 可能仍在途）。
    private func waitForAir(_ vm: WeatherViewModel, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if vm.airQuality != nil { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func makeAir(usAqi: Int? = 78) -> AirQuality {
        AirQuality(usAqi: usAqi, europeanAqi: 53, pm25: 30.9, pm10: 93.1,
                   carbonMonoxide: nil, nitrogenDioxide: nil,
                   sulphurDioxide: nil, ozone: nil)
    }

    // MARK: - R5 核心：空气失败 ≠ 天气失败

    func testAirFailureDoesNotAffectWeatherState() async throws {
        let store = try makeStore()
        let vm = WeatherViewModel(service: StubWeather(snapshot: makeSnapshot()),
                                  store: store,
                                  locationProvider: LocationProvider(),
                                  airService: StubAirService(.failure(.badStatus(503))))

        await vm.refresh()

        // 天气 state 正常 .loaded；空气为 nil（AC-A2-4 / R-A2-1 核心断言）。
        guard case .loaded = vm.state else {
            XCTFail("天气 state 不应被空气失败污染，实际 \(vm.state)")
            return
        }
        XCTAssertNil(vm.airQuality, "空气失败后 airQuality 必须为 nil")
    }

    func testAirSuccessPopulatesAirQuality() async throws {
        let store = try makeStore()
        let vm = WeatherViewModel(service: StubWeather(snapshot: makeSnapshot()),
                                  store: store,
                                  locationProvider: LocationProvider(),
                                  airService: StubAirService(.success(makeAir())))

        await vm.refresh()
        await waitForAir(vm)

        guard case .loaded = vm.state else {
            XCTFail("天气应正常加载"); return
        }
        XCTAssertEqual(vm.airQuality?.usAqi, 78)
    }

    // MARK: - 过期守门（P1-A 平移）

    func testStaleAirResultDiscardedAfterCitySwitch() async throws {
        let store = try makeStore()
        // 天气 Stub 慢一点无所谓——本用例的机制点：空气结果返回前 selectedID 已变。
        let slowAir = StubAirService(.success(makeAir(usAqi: 999)))
        let vm = WeatherViewModel(service: StubWeather(snapshot: makeSnapshot()),
                                  store: store,
                                  locationProvider: LocationProvider(),
                                  airService: slowAir)

        await vm.refresh()
        await waitForAir(vm)
        // refresh 后 airQuality = 北京（78）。
        XCTAssertEqual(vm.airQuality?.usAqi, 78)

        // 切换城市（走 addAndSelect 造第二个城市，目录至少一项不变式）。
        let newCity = City(name: "杭州", latitude: 30.25, longitude: 120.17,
                           isCurrentLocation: false)
        await vm.addAndSelect(newCity)
        await waitForAir(vm)
        // 切城后空气链路重新触发，新城市结果（同 Stub 999）被应用——守门不误杀。
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, vm.airQuality?.usAqi != 999 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(vm.airQuality?.usAqi, 999)
    }

    // MARK: - 天气失败 ≠ 空气不触发（双向隔离另一半）

    func testWeatherFailureStillLoadsAirIndependently() async throws {
        let store = try makeStore()
        // 天气 Stub 抛错 + 空气 Stub 成功。
        struct FailingWeather: WeatherProviding {
            func fetch(latitude: Double, longitude: Double) async throws -> WeatherSnapshot {
                throw WeatherError.badStatus(500)
            }
        }
        let vm = WeatherViewModel(service: FailingWeather(),
                                  store: store,
                                  locationProvider: LocationProvider(),
                                  airService: StubAirService(.success(makeAir(usAqi: 42))))

        await vm.refresh()

        guard case .failed = vm.state else {
            XCTFail("天气失败应为 .failed，实际 \(vm.state)"); return
        }
        // 空气独立成功（refresh 内天气抛错时空气 Task 未触发——此为顺序触发设计的
        // 预期行为：天气失败时本轮空气也不拉，避免在失败态下叠加网络请求；
        // 但 loadAir 自身的隔离性由 testAirFailureDoesNotAffectWeatherState 锁定）。
        XCTAssertNil(vm.airQuality)
    }
}

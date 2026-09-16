//
//  WeatherViewModelDiagnosticsTests.swift
//  ZhishengWeatherTests
//
//  本轮「可诊断性」修复的 **VM 侧接线**单测：证明核心纯逻辑（FaultDomain /
//  StalePolicy）确实被 VM 用在了正确的位置，且失败**在屏上可见**（不再静默）。
//
//  覆盖：
//    1. 副链路独立状态（airState / ensembleState）—— 失败置 `.failed(文案)`、
//       成功置 `.loaded`，且**绝不污染主 state**（失败隔离纪律的可视化面）。
//    2. 定位提示（locationNotice）—— 非「权限被拒」时保持 nil（不打扰用户）。
//    3. 共享容器写失败（storageIssue）—— 写后回读校验失败时不再静默。
//    4. 陈旧判定（isCachedPayloadStale）—— 复用主循环同一 freshnessWindow。
//
//  P-18 同源盲区纪律：此处**硬编码**期望文案字面量（与 FaultDomainTests 同源钉死），
//  而非「调用实现去算期望值再对比」——否则接线断了测试也照样绿。
//

import XCTest
@testable import ZhishengWeather

// MARK: - Stubs

/// 可控天气服务 Stub（恒定返回一个快照）。
private actor StubWeather: WeatherProviding {
    private let snapshot: WeatherSnapshot
    init(snapshot: WeatherSnapshot) { self.snapshot = snapshot }
    func fetch(latitude: Double, longitude: Double) async throws -> WeatherSnapshot { snapshot }
}

/// 可控空气服务 Stub。
private actor StubAir: AirQualityProviding {
    enum Behavior { case success(AirQuality); case failure(WeatherError) }
    private let behavior: Behavior
    init(_ behavior: Behavior) { self.behavior = behavior }
    func fetch(latitude: Double, longitude: Double) async throws -> AirQuality {
        switch behavior {
        case .success(let air): return air
        case .failure(let error): throw error
        }
    }
}

/// 可控集合服务 Stub。
private actor StubEnsemble: EnsembleProviding {
    enum Behavior { case success(EnsembleForecast); case failure(WeatherError) }
    private let behavior: Behavior
    init(_ behavior: Behavior) { self.behavior = behavior }
    func fetch(latitude: Double, longitude: Double) async throws -> EnsembleForecast {
        switch behavior {
        case .success(let forecast): return forecast
        case .failure(let error): throw error
        }
    }
}

/// 写后**回读恒为 nil** 的 UserDefaults：令 `AppGroupStore.save` 的写后回读校验
/// 必然失败，从而驱动 VM 的 `storageIssue`（模拟「共享容器写不进去」）。
///
/// 采用子类拦截而非伪造 Store，是因为 `AppGroupStore` 已把 `UserDefaults` 注入化
/// （见其文件头设计要点），这是既有测试一贯的注入缝。
private final class ReadBackFailingDefaults: UserDefaults {
    override func data(forKey defaultName: String) -> Data? { return nil }
}

@MainActor
final class WeatherViewModelDiagnosticsTests: XCTestCase {

    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 构造工具

    private func makeSnapshot() -> WeatherSnapshot {
        WeatherSnapshot(location: .beijing,
                        temperature: 23.0, apparentTemperature: 22.0,
                        weatherCode: 1, windSpeed: 2.0, windDirection: 90.0,
                        humidity: 50, isDay: true, hourly: [],
                        dailyHigh: 25.0, dailyLow: 15.0, daily: nil,
                        fetchedAt: anchor)
    }

    private func makeAir(usAqi: Int = 42) -> AirQuality {
        AirQuality(usAqi: usAqi, europeanAqi: 53, pm25: 30.9, pm10: 93.1,
                   carbonMonoxide: nil, nitrogenDioxide: nil,
                   sulphurDioxide: nil, ozone: nil)
    }

    private func makeForecast(memberCount: Int = 3) -> EnsembleForecast {
        let times = [anchor, anchor.addingTimeInterval(3600)]
        let series: [[Double?]] = (0..<memberCount).map { index -> [Double?] in
            [Double(index) * 0.2, 0.5]
        }
        return EnsembleForecast(times: times, memberSeries: series, utcOffsetSeconds: 0)
    }

    private func makeCity() -> City {
        City(name: "杭州", latitude: 30.25, longitude: 120.17, isCurrentLocation: false)
    }

    private func makeStore() throws -> AppGroupStore {
        let name = "zs.test.diag.\(UUID().uuidString)"
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

    // MARK: - 1. 副链路独立状态（失败可见 + 不污染主 state）

    func testAirStateLoadedOnSuccess() async throws {
        let vm = WeatherViewModel(service: StubWeather(snapshot: makeSnapshot()),
                                  store: try makeStore(),
                                  locationProvider: LocationProvider(),
                                  airService: StubAir(.success(makeAir(usAqi: 42))),
                                  ensembleService: StubEnsemble(.success(makeForecast())))

        await vm.addAndSelect(makeCity())
        await waitUntil { vm.airState == .loaded }

        XCTAssertEqual(vm.airState, .loaded, "空气成功 → 该链路状态置 .loaded")
        XCTAssertEqual(vm.airQuality?.usAqi, 42)
    }

    func testAirFailureSetsAirStateFailedWithExactMessage() async throws {
        let vm = WeatherViewModel(service: StubWeather(snapshot: makeSnapshot()),
                                  store: try makeStore(),
                                  locationProvider: LocationProvider(),
                                  airService: StubAir(.failure(.badStatus(503))),
                                  ensembleService: StubEnsemble(.success(makeForecast())))

        await vm.addAndSelect(makeCity())
        await waitUntil { vm.airState != .idle }

        // 硬编码期望文案（= FaultDomain 对 5xx 的既定短句），端到端钉死接线。
        XCTAssertEqual(vm.airState, .failed("天气服务暂时不可用（503），请稍后再试"),
                       "空气失败 → 该链路状态必须带按故障域给出的可操作文案")
        XCTAssertNil(vm.airQuality, "失败 → 该链路槽位为空（不渲染旧值冒充）")

        guard case .loaded = vm.state else {
            return XCTFail("空气失败不得污染主 state，实际 \(vm.state)")
        }
    }

    func testEnsembleStateLoadedOnSuccess() async throws {
        let vm = WeatherViewModel(service: StubWeather(snapshot: makeSnapshot()),
                                  store: try makeStore(),
                                  locationProvider: LocationProvider(),
                                  airService: StubAir(.success(makeAir())),
                                  ensembleService: StubEnsemble(.success(makeForecast(memberCount: 3))))

        await vm.addAndSelect(makeCity())
        await waitUntil { vm.ensembleState == .loaded }

        XCTAssertEqual(vm.ensembleState, .loaded, "集合成功 → 该链路状态置 .loaded")
        XCTAssertEqual(vm.displayedEnsemble?.memberCount, 3)
    }

    func testEnsembleFailureSetsEnsembleStateFailedWithExactMessage() async throws {
        let vm = WeatherViewModel(service: StubWeather(snapshot: makeSnapshot()),
                                  store: try makeStore(),
                                  locationProvider: LocationProvider(),
                                  airService: StubAir(.success(makeAir())),
                                  ensembleService: StubEnsemble(.failure(.timeout("超时"))))

        await vm.addAndSelect(makeCity())
        await waitUntil { vm.ensembleState != .idle }

        XCTAssertEqual(vm.ensembleState, .failed("网络超时，请稍后重试"),
                       "集合失败 → 该链路状态必须带按故障域给出的文案")
        XCTAssertNil(vm.displayedEnsemble)

        guard case .loaded = vm.state else {
            return XCTFail("集合失败不得污染主 state，实际 \(vm.state)")
        }
    }

    // MARK: - 2. 定位提示（非「权限被拒」保持静默）

    func testLocationNoticeNilWhenNotDenied() async throws {
        // 单测环境无真实定位权限流转 → LocationProvider 默认 outcome = .authorized，
        // 反映到 VM 即「无提示」。权限被拒的**裁定**由 FaultDomainTests 纯函数锁定。
        let vm = WeatherViewModel(service: StubWeather(snapshot: makeSnapshot()),
                                  store: try makeStore(),
                                  locationProvider: LocationProvider(),
                                  airService: StubAir(.success(makeAir())),
                                  ensembleService: StubEnsemble(.success(makeForecast())))

        await vm.addAndSelect(makeCity())

        XCTAssertNil(vm.locationNotice, "未触发定位被拒 → 不应打扰用户（保持静默回落）")
    }

    // MARK: - 3. 共享容器写失败（不再静默）

    func testStorageIssueNilOnHealthyWrite() async throws {
        let vm = WeatherViewModel(service: StubWeather(snapshot: makeSnapshot()),
                                  store: try makeStore(),
                                  locationProvider: LocationProvider(),
                                  airService: StubAir(.success(makeAir())),
                                  ensembleService: StubEnsemble(.success(makeForecast())))

        await vm.addAndSelect(makeCity())

        XCTAssertNil(vm.storageIssue, "正常写入 → 无共享容器故障提示")
    }

    func testStorageIssueSurfacedOnWriteFailure() async throws {
        let name = "zs.test.diag.failread.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(ReadBackFailingDefaults(suiteName: name))
        let store = AppGroupStore(defaults: defaults)

        let vm = WeatherViewModel(service: StubWeather(snapshot: makeSnapshot()),
                                  store: store,
                                  locationProvider: LocationProvider(),
                                  airService: StubAir(.success(makeAir())),
                                  ensembleService: StubEnsemble(.success(makeForecast())))

        await vm.addAndSelect(makeCity())
        await waitUntil { vm.storageIssue != nil }

        XCTAssertEqual(vm.storageIssue, "小组件共享数据异常，请检查 App Group 权限",
                       "写后回读校验失败 → 必须把共享容器问题投影为可见提示（不再只 print）")
    }

    // MARK: - 4. 陈旧判定（复用主循环 freshnessWindow = 15 分钟）

    func testCachedPayloadStaleFalseWhenNoPayload() async throws {
        let vm = WeatherViewModel(service: StubWeather(snapshot: makeSnapshot()),
                                  store: try makeStore(),
                                  locationProvider: LocationProvider(),
                                  airService: StubAir(.success(makeAir())),
                                  ensembleService: StubEnsemble(.success(makeForecast())))

        XCTAssertFalse(vm.isCachedPayloadStale, "从未落盘 → 不叠加陈旧提示（由 loading/failed 表达）")
    }

    func testCachedPayloadStaleTrueForOldPayload() throws {
        let store = try makeStore()
        // 写入「超过 15 分钟窗口」的载荷 → 陈旧。
        let old = Date().addingTimeInterval(-(15 * 60) - 60)
        try store.save(snapshot: makeSnapshot(), at: old)

        let vm = WeatherViewModel(service: StubWeather(snapshot: makeSnapshot()),
                                  store: store,
                                  locationProvider: LocationProvider(),
                                  airService: StubAir(.success(makeAir())),
                                  ensembleService: StubEnsemble(.success(makeForecast())))

        XCTAssertTrue(vm.isCachedPayloadStale, "载荷超过 freshnessWindow → 必须标记陈旧")
    }

    func testCachedPayloadStaleFalseForFreshPayload() throws {
        let store = try makeStore()
        // 刚刚写入 → 不陈旧。
        try store.save(snapshot: makeSnapshot(), at: Date())

        let vm = WeatherViewModel(service: StubWeather(snapshot: makeSnapshot()),
                                  store: store,
                                  locationProvider: LocationProvider(),
                                  airService: StubAir(.success(makeAir())),
                                  ensembleService: StubEnsemble(.success(makeForecast())))

        XCTAssertFalse(vm.isCachedPayloadStale, "刚写入的载荷不应被误判为陈旧")
    }
}

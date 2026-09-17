//
//  WidgetDataResolverTests.swift
//  ZhishengWeatherTests
//
//  数据阶梯（ARCH §12.4）——本轮设计的**核心**判定，逐条注入断言：
//
//    L0 共享容器：新鲜命中 / 过旧命中（仍发数据 + 标注）/ 命中优先于取数（配额）
//    L1 自力取数：缺 / 损坏 / 容器不可用 / 归属不符 → **自愈**（P-19 直接对治）
//    L2 如实空态：无城市不取数 / 传输失败 / 该城市无数据 / 快照路径不联网
//    硬上限：慢取数被 10s 级硬上限切断 → .fetchFailed（不拖垮时间线）
//    不变式：payload != nil ⟺ emptyReason == nil
//
//  纪律（P-18）：**注入**而非模拟 —— 容器状态用字面量、取数用 Fake（可断言调用次数）、
//  时刻用固定 Date。绝不复制实现里的假设到测试里。
//

import XCTest
@testable import ZhishengWeather

final class WidgetDataResolverTests: XCTestCase {

    // MARK: - 固定时刻（Core 禁内部 Date()，测试全部注入）

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let threshold: TimeInterval = 30 * 60

    // MARK: - Fake 取数器（可断言"是否被调用"→ 配额纪律）

    /// 假取数器：行为注入 + 调用计数（actor 保证跨并发安全）。
    private actor FakeWeatherProvider: WeatherProviding {

        enum Behavior: Sendable {
            /// 成功返回给定快照。
            case success(WeatherSnapshot)
            /// 抛给定错误。
            case failure(WeatherError)
            /// 先睡一会儿再成功（用于验证硬上限竞速）。
            case slowSuccess(WeatherSnapshot, nanoseconds: UInt64)
        }

        private let behavior: Behavior
        private var callCount = 0

        init(behavior: Behavior) {
            self.behavior = behavior
        }

        func fetch(latitude: Double, longitude: Double) async throws -> WeatherSnapshot {
            callCount += 1
            switch behavior {
            case .success(let snapshot):
                return snapshot
            case .failure(let error):
                throw error
            case .slowSuccess(let snapshot, let nanoseconds):
                try await Task.sleep(nanoseconds: nanoseconds)
                return snapshot
            }
        }

        /// 取数被调用的次数（0 = 本路径零配额）。
        func calls() -> Int { callCount }
    }

    // MARK: - 夹具

    private func snapshot(location: LocationInfo) -> WeatherSnapshot {
        WeatherSnapshot(location: location,
                        temperature: 23, apparentTemperature: 22,
                        weatherCode: 2, windSpeed: 3, windDirection: 90,
                        humidity: 50, isDay: true, hourly: [],
                        dailyHigh: 25, dailyLow: 15,
                        fetchedAt: now)
    }

    private func payload(for city: City, updatedAt: Date) -> SharedWeatherPayload {
        SharedWeatherPayload(snapshot: snapshot(location: city.locationInfo),
                             updatedAt: updatedAt,
                             timeZoneIdentifier: city.timeZoneIdentifier)
    }

    private static let beijing = City.beijingDefault
    private static let hangzhou = City(name: "杭州", latitude: 30.25, longitude: 120.17,
                                       isCurrentLocation: false)

    /// 一次完整的 resolve 调用（默认 allowNetwork = true、容器可用）。
    private func resolve(cityOutcome: WidgetCityOutcome,
                         containerAvailable: Bool = true,
                         loadResult: AppGroupStore.PayloadLoadResult,
                         allowNetwork: Bool = true,
                         weather: WeatherProviding,
                         fetchBudget: TimeInterval = WidgetDataResolver.fetchBudget) async -> WidgetEntryResolution {
        await WidgetDataResolver.resolve(cityOutcome: cityOutcome,
                                        containerAvailable: containerAvailable,
                                        loadResult: loadResult,
                                        now: now,
                                        allowNetwork: allowNetwork,
                                        weather: weather,
                                        staleThreshold: threshold,
                                        fetchBudget: fetchBudget)
    }

    // MARK: - 1. L0 新鲜命中 → 零网络

    func testL0FreshHitUsesContainerPayloadWithoutNetwork() async {
        let payload = payload(for: Self.beijing, updatedAt: now.addingTimeInterval(-60))
        let fake = FakeWeatherProvider(behavior: .success(snapshot(location: LocationInfo.beijing)))

        let resolution = await resolve(cityOutcome: .resolved(Self.beijing),
                                       loadResult: .loaded(payload),
                                       weather: fake)

        XCTAssertEqual(resolution.payload, payload, "L0 命中必须直接用容器载荷")
        XCTAssertEqual(resolution.status, .available, "60 秒前的数据 = 新鲜")
        XCTAssertEqual(resolution.dataSource, .sharedContainer, "来源必须是共享容器（L0）")
        XCTAssertNil(resolution.emptyReason, "有载荷 → 无空因")
        let calls = await fake.calls()
        XCTAssertEqual(calls, 0, "L0 命中必须**零网络**（配额纪律）")
    }

    // MARK: - 2. L0 过旧命中 → 仍发数据 + 标注（且不取数）

    func testL0StaleHitKeepsContainerPayloadAndSkipsNetwork() async {
        let stalePayload = payload(for: Self.beijing,
                                   updatedAt: now.addingTimeInterval(-(threshold + 1)))
        // 取数本可成功 → 也必须**不**被调用（容器有数据就优先，配额纪律）。
        let fake = FakeWeatherProvider(behavior: .success(snapshot(location: LocationInfo.beijing)))

        let resolution = await resolve(cityOutcome: .resolved(Self.beijing),
                                       loadResult: .loaded(stalePayload),
                                       weather: fake)

        XCTAssertEqual(resolution.payload, stalePayload, "过旧也必须继续展示缓存数据，只加标注")
        XCTAssertEqual(resolution.status, .stale)
        XCTAssertEqual(resolution.dataSource, .sharedContainer)
        let calls = await fake.calls()
        XCTAssertEqual(calls, 0, "L0 命中优先于 L1：即便数据过旧也不取数")
    }

    // MARK: - 3. L0 缺 + 取数成功 → 自力取数（含城市名覆盖与时区）

    func testL1SelfFetchOnContainerMissOverridesCityNameAndCarriesTimeZone() async {
        // 服务层返回的 location.name 恒为「当前位置」（对齐 WeatherService 实现）。
        let serviceSnapshot = snapshot(location: LocationInfo(name: "当前位置",
                                                              latitude: 39.90, longitude: 116.41,
                                                              isFallback: false))
        let fake = FakeWeatherProvider(behavior: .success(serviceSnapshot))

        let resolution = await resolve(cityOutcome: .resolved(Self.beijing),
                                       loadResult: .missing,
                                       weather: fake)

        XCTAssertEqual(resolution.status, .available, "刚取回 → 必新鲜")
        XCTAssertEqual(resolution.dataSource, .selfFetched, "来源必须是自力取数（L1）")
        XCTAssertNil(resolution.emptyReason)
        XCTAssertEqual(resolution.payload?.snapshot.location.name, "北京",
                       "城市名必须被覆盖为实例目标城市（否则小组件顶着「当前位置」）")
        XCTAssertEqual(resolution.payload?.updatedAt, now,
                       "自力取数的 updatedAt = entry 生成时刻（「更新于」如实反映取数时刻）")
        let calls = await fake.calls()
        XCTAssertEqual(calls, 1, "L1 恰好一次请求（全路径唯一一次）")
    }

    // MARK: - 4. 容器不可用 + 取数成功 → 自愈（P-19 直接对治）

    func testL1HealsWhenSharedContainerIsUnavailable() async {
        // 容器不可用（未签名侧载产物的真实状态），且私有容器里恰有**别城**脏数据。
        let fake = FakeWeatherProvider(behavior: .success(snapshot(location: LocationInfo.beijing)))

        let resolution = await resolve(cityOutcome: .resolved(Self.beijing),
                                       containerAvailable: false,
                                       loadResult: .loaded(payload(for: Self.hangzhou, updatedAt: now)),
                                       weather: fake)

        XCTAssertEqual(resolution.status, .available,
                       "容器不可用**不得**成为终态 —— 必须自力取数自愈（P-19）")
        XCTAssertEqual(resolution.dataSource, .selfFetched)
        XCTAssertEqual(resolution.payload?.snapshot.location.name, "北京")
    }

    // MARK: - 5. 载荷损坏 + 取数成功 → 自愈

    func testL1HealsOnCorruptContainerPayload() async {
        let fake = FakeWeatherProvider(behavior: .success(snapshot(location: LocationInfo.beijing)))

        let resolution = await resolve(cityOutcome: .resolved(Self.beijing),
                                       loadResult: .corrupt,
                                       weather: fake)

        XCTAssertEqual(resolution.status, .available, "损坏不再是终态：自愈取数")
        XCTAssertEqual(resolution.dataSource, .selfFetched)
    }

    // MARK: - 6. 归属不符 + 取数成功 → 自愈（不冒充、也不空）

    func testL1HealsOnOwnershipMismatch() async {
        let fake = FakeWeatherProvider(behavior: .success(snapshot(location: LocationInfo.beijing)))

        let resolution = await resolve(cityOutcome: .resolved(Self.beijing),
                                       loadResult: .loaded(payload(for: Self.hangzhou, updatedAt: now)),
                                       weather: fake)

        XCTAssertEqual(resolution.status, .available, "容器里是杭州数据但实例要北京 → 自己取北京")
        XCTAssertEqual(resolution.dataSource, .selfFetched)
        XCTAssertEqual(resolution.payload?.snapshot.location.name, "北京", "绝不拿杭州数据冒充北京")
    }

    // MARK: - 7. 取数失败（传输层）→ 如实空态

    func testL1TransportFailureYieldsFetchFailed() async {
        let fake = FakeWeatherProvider(behavior: .failure(.timeout("超时")))

        let resolution = await resolve(cityOutcome: .resolved(Self.beijing),
                                       loadResult: .missing,
                                       weather: fake)

        XCTAssertNil(resolution.payload)
        XCTAssertEqual(resolution.status, .unavailable)
        XCTAssertEqual(resolution.dataSource, .none)
        XCTAssertEqual(resolution.emptyReason, .fetchFailed, "文案 → 「未能获取天气 · 请检查网络后重试」")
        XCTAssertEqual(resolution.city?.id, Self.beijing.id, "仍保留城市（标题不丢）")
    }

    // MARK: - 8. 取数成功但该城市结构性无数据 → 与「取不到」区分

    func testL1DataMissingYieldsCityHasNoData() async {
        let fake = FakeWeatherProvider(behavior: .failure(.dataMissing("坐标 39.90,116.41")))

        let resolution = await resolve(cityOutcome: .resolved(Self.beijing),
                                       loadResult: .missing,
                                       weather: fake)

        XCTAssertNil(resolution.payload)
        XCTAssertEqual(resolution.status, .missing, "「该城市无数据」属 missing 轴，非 unavailable")
        XCTAssertEqual(resolution.emptyReason, .cityHasNoData)
        XCTAssertEqual(resolution.dataSource, .none)
    }

    // MARK: - 9. 无城市 → 不取数（即便 allowNetwork == true）

    func testNoCityNeverFetches() async {
        let fake = FakeWeatherProvider(behavior: .success(snapshot(location: LocationInfo.beijing)))

        let resolution = await resolve(cityOutcome: .needsConfiguration,
                                       loadResult: .missing,
                                       allowNetwork: true,
                                       weather: fake)

        XCTAssertNil(resolution.payload)
        XCTAssertNil(resolution.city, "无城市：绝不注入北京冒充用户归属")
        XCTAssertEqual(resolution.status, .missing)
        XCTAssertEqual(resolution.dataSource, .none)
        XCTAssertEqual(resolution.emptyReason, .noCity)
        let calls = await fake.calls()
        XCTAssertEqual(calls, 0, "无城市时绝不取数（没有坐标可请求）")
    }

    // MARK: - 9.x P1-C7「当前位置」的两个空态 → 如实空态 + **零取数**

    /// 未获定位资格：用户**已经**选过「当前位置」，空因必须能区分于 `.noCity`
    /// （提示动作完全不同：一个是去授权，一个是去选城市）。
    func testLocationNotAuthorizedNeverFetches() async {
        let fake = FakeWeatherProvider(behavior: .success(snapshot(location: LocationInfo.beijing)))

        let resolution = await resolve(cityOutcome: .locationNotAuthorized,
                                       loadResult: .missing,
                                       allowNetwork: true,
                                       weather: fake)

        XCTAssertNil(resolution.payload)
        XCTAssertNil(resolution.city, "未授权 → 无城市（不伪造坐标、绝不回落北京）")
        XCTAssertEqual(resolution.status, .missing)
        XCTAssertEqual(resolution.dataSource, .none)
        XCTAssertEqual(resolution.emptyReason, .locationNotAuthorized,
                       "空因必须**逐层透传**：与 `.noCity` 分开（Apple 明文要求区分）")
        let calls = await fake.calls()
        XCTAssertEqual(calls, 0, "没有坐标 → 绝不取数（取谁的天气？）")
    }

    /// 已获资格但本轮没拿到坐标（Apple：系统只在组件可见后的一小段时间内提供定位）
    /// → 如实说明，同样**零取数**。
    func testLocationUnavailableNeverFetches() async {
        let fake = FakeWeatherProvider(behavior: .success(snapshot(location: LocationInfo.beijing)))

        let resolution = await resolve(cityOutcome: .locationUnavailable,
                                       loadResult: .missing,
                                       allowNetwork: true,
                                       weather: fake)

        XCTAssertNil(resolution.payload)
        XCTAssertNil(resolution.city)
        XCTAssertEqual(resolution.status, .missing)
        XCTAssertEqual(resolution.dataSource, .none)
        XCTAssertEqual(resolution.emptyReason, .locationUnavailable)
        let calls = await fake.calls()
        XCTAssertEqual(calls, 0, "没拿到坐标 → 绝不取数（不会拿别处的天气冒充）")
    }

    /// 「当前位置」拿到坐标后，取数必须**按该坐标**发起（而不是容器里的北京）。
    func testLocatedCurrentLocationFetchesByTheLocatedCoordinate() async {
        let located = City(name: WidgetLocationResolver.currentLocationName,
                           latitude: 30.25, longitude: 120.17, isCurrentLocation: true)
        let fake = FakeWeatherProvider(behavior: .success(snapshot(location: located.locationInfo)))

        let resolution = await resolve(cityOutcome: .resolved(located),
                                       loadResult: .missing,
                                       allowNetwork: true,
                                       weather: fake)

        XCTAssertEqual(resolution.dataSource, .selfFetched)
        XCTAssertEqual(resolution.payload?.snapshot.location.name,
                       WidgetLocationResolver.currentLocationName,
                       "城市名必须被覆盖为实例目标城市（不顶着服务层返回的「当前位置」以外的值）")
        let calls = await fake.calls()
        XCTAssertEqual(calls, 1, "定位实例同样遵守「全路径至多一次」的配额纪律")
    }

    // MARK: - 10. 快照路径（allowNetwork = false）→ 零请求

    func testSnapshotPathNeverFetches() async {
        let fake = FakeWeatherProvider(behavior: .success(snapshot(location: LocationInfo.beijing)))

        let cachedMiss = await resolve(cityOutcome: .resolved(Self.beijing),
                                       containerAvailable: true,
                                       loadResult: .missing,
                                       allowNetwork: false,
                                       weather: fake)
        XCTAssertEqual(cachedMiss.status, .missing)
        XCTAssertEqual(cachedMiss.emptyReason, .noCachedData, "容器可用但无该城缓存")
        XCTAssertEqual(cachedMiss.dataSource, .none)

        let containerDown = await resolve(cityOutcome: .resolved(Self.beijing),
                                          containerAvailable: false,
                                          loadResult: .missing,
                                          allowNetwork: false,
                                          weather: fake)
        XCTAssertEqual(containerDown.status, .unavailable)
        XCTAssertEqual(containerDown.emptyReason, .sharedContainerDown, "容器不可用如实说明")

        let calls = await fake.calls()
        XCTAssertEqual(calls, 0, "snapshot（画廊 / 瞬时预览）绝不联网")
    }

    // MARK: - 11. 硬上限 → 超时收敛为 .fetchFailed（不拖垮时间线）

    func testHardBudgetCutsOffSlowFetchAndConvergesToFetchFailed() async {
        // 慢取数（0.2s）vs 硬上限（0.05s）→ 必须走超时分支。
        let fake = FakeWeatherProvider(
            behavior: .slowSuccess(snapshot(location: LocationInfo.beijing),
                                   nanoseconds: 200_000_000))

        let started = Date()
        let resolution = await resolve(cityOutcome: .resolved(Self.beijing),
                                       loadResult: .missing,
                                       weather: fake,
                                       fetchBudget: 0.05)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNil(resolution.payload)
        XCTAssertEqual(resolution.status, .unavailable)
        XCTAssertEqual(resolution.emptyReason, .fetchFailed, "超时收敛为 L2 空态，**不抛错**")
        XCTAssertLessThan(elapsed, 1.0, "硬上限必须真正生效（不可等慢取数自然结束）")
    }

    // MARK: - 12. 不变式：payload != nil ⟺ emptyReason == nil

    func testPayloadAndEmptyReasonAreMutuallyExclusive() async {
        let fresh = payload(for: Self.beijing, updatedAt: now)
        let success = FakeWeatherProvider(behavior: .success(snapshot(location: LocationInfo.beijing)))
        let failure = FakeWeatherProvider(behavior: .failure(.network("断网")))

        let cases: [(WidgetCityOutcome, Bool, AppGroupStore.PayloadLoadResult, Bool, WeatherProviding)] = [
            (.resolved(Self.beijing), true, .loaded(fresh), true, success),
            (.resolved(Self.beijing), true, .missing, true, success),
            (.resolved(Self.beijing), false, .missing, true, success),
            (.resolved(Self.beijing), true, .missing, true, failure),
            (.resolved(Self.beijing), true, .missing, false, failure),
            (.needsConfiguration, true, .missing, true, failure),
            (.locationNotAuthorized, true, .missing, true, failure),
            (.locationUnavailable, true, .missing, true, failure),
        ]

        for (index, item) in cases.enumerated() {
            let resolution = await resolve(cityOutcome: item.0,
                                           containerAvailable: item.1,
                                           loadResult: item.2,
                                           allowNetwork: item.3,
                                           weather: item.4)
            XCTAssertEqual(resolution.payload != nil, resolution.emptyReason == nil,
                           "用例 #\(index + 1)：有载荷 ⟺ 无空因（不变式被击穿）")
        }
    }
}

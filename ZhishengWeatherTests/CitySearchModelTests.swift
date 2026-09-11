//
//  CitySearchModelTests.swift
//  ZhishengWeatherTests
//
//  F-B：搜索状态机用例（AC-B17~B21 静态侧，不联网）。
//  Fake provider 注入（协议 GeocodingProviding 抽象的价值所在）：
//   - 防抖生效（debounce 注入 0）
//   - 代际号丢弃过期响应（第一次人为延迟、第二次立即，确定性构造）
//   - 无命中 → .empty；网络失败 → .failure；retry 用最近一次 query
//
//  结构隔离备案：CitySearchModel 不持有城市目录引用，搜索失败不可能影响列表
//  （编译期结构保证，无需用例）。
//

import XCTest
@testable import ZhishengWeather

/// 全部用例 @MainActor：被测对象 CitySearchModel 为 @MainActor @Observable，
/// 同步调用其方法需在 MainActor 上（否则需逐点 await，反而降低可读性）。
@MainActor
final class CitySearchModelTests: XCTestCase {

    // MARK: - Fake Provider

    /// 按调用序号分发的 Fake 搜索提供者（actor 保证 Sendable）。
    private actor FakeGeocodingProvider: GeocodingProviding {

        private let handler: @Sendable (String, Int) async throws -> [City]
        private var callIndex = 0
        private(set) var queries: [String] = []

        init(handler: @escaping @Sendable (String, Int) async throws -> [City]) {
            self.handler = handler
        }

        func search(name: String) async throws -> [City] {
            queries.append(name)
            let index = callIndex
            callIndex += 1
            return try await handler(name, index)
        }
    }

    /// 不受协作式取消影响的延迟（模拟已飞行中的请求：Task 取消拦不住它）。
    private static func nonCancellableSleep(seconds: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                continuation.resume()
            }
        }
    }

    private func makeCity(_ name: String, lat: Double, lon: Double) -> City {
        City(name: name, latitude: lat, longitude: lon, isCurrentLocation: false)
    }

    /// 轮询等待 phase 离开给定集合（最多 timeout 秒），返回最终 phase。
    @MainActor
    private func waitForPhase(
        of model: CitySearchModel,
        timeout: TimeInterval = 3,
        until predicate: @MainActor (CitySearchModel.Phase) -> Bool
    ) async -> CitySearchModel.Phase {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(model.phase) { return model.phase }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return model.phase
    }

    // MARK: - ① 防抖生效 → results

    func testDebounceLeadsToResultsPhase() async {
        let hangzhou = makeCity("杭州", lat: 30.25, lon: 120.17)
        let provider = FakeGeocodingProvider { _, _ in [hangzhou] }
        let model = CitySearchModel(provider: provider, debounceSeconds: 0)

        model.queryChanged("杭州")

        let phase = await waitForPhase(of: model) { phase in
            if case .idle = phase { return false }
            if case .loading = phase { return false }
            return true
        }

        guard case .results(let cities) = phase else {
            XCTFail("期望 .results，实际 \(phase)")
            return
        }
        XCTAssertEqual(cities.map(\.name), ["杭州"])
    }

    // MARK: - ② 竞态：代际号丢弃过期响应（AC-B18）

    func testLateResponseIsDiscardedByGenerationToken() async {
        let cityA = makeCity("城市甲", lat: 1.0, lon: 1.0)
        let cityB = makeCity("城市乙", lat: 2.0, lon: 2.0)

        let provider = FakeGeocodingProvider { _, index in
            if index == 0 {
                // 第一次请求人为延迟（已飞行中，Task 取消拦不住）。
                await CitySearchModelTests.nonCancellableSleep(seconds: 0.4)
                return [cityA]
            }
            return [cityB]
        }
        let model = CitySearchModel(provider: provider, debounceSeconds: 0)

        model.queryChanged("第一输入")
        // CI 实测：两次 queryChanged 在主 actor 上同步连发时，第一次的防抖 Task
        // 会在起跑前就被第二次的 cancel() 掐死——竞态根本没构造出来（唯一发出的
        // 请求反而是 index 0 的延迟请求）。这里让出主线程 0.1s，确保第一次请求
        // 真正进入飞行中（generation=1 已记录、provider 已挂起在不可取消的
        // sleep 上），后续第二次输入才能测到"晚到响应被代际号丢弃"（AC-B18）。
        try? await Task.sleep(nanoseconds: 100_000_000)
        model.queryChanged("第二输入")

        // 等到两个响应都返回（延迟 0.4s + 余量）。
        try? await Task.sleep(nanoseconds: 900_000_000)

        guard case .results(let cities) = model.phase else {
            XCTFail("期望 .results，实际 \(model.phase)")
            return
        }
        XCTAssertEqual(cities.map(\.name), ["城市乙"],
                       "晚到的第一个响应必须被代际号丢弃，phase 保持第二次结果（AC-B18）")
    }

    // MARK: - ③ 无命中 → .empty

    func testEmptyResultMapsToEmptyPhase() async {
        let provider = FakeGeocodingProvider { _, _ in [] }
        let model = CitySearchModel(provider: provider, debounceSeconds: 0)

        model.queryChanged("不存在的地名")

        let phase = await waitForPhase(of: model) { phase in
            if case .empty = phase { return true }
            if case .loading = phase { return false }
            if case .idle = phase { return false }
            return true
        }

        XCTAssertEqual(phase, .empty, "空结果 ≠ 失败，必须映射为 .empty（AC-B19）")
    }

    // MARK: - ④ 网络失败 → .failure

    func testNetworkFailureMapsToFailurePhase() async {
        let provider = FakeGeocodingProvider { _, _ in
            throw WeatherError.network("offline")
        }
        let model = CitySearchModel(provider: provider, debounceSeconds: 0)

        model.queryChanged("杭州")

        let phase = await waitForPhase(of: model) { phase in
            if case .failure = phase { return true }
            if case .loading = phase { return false }
            if case .idle = phase { return false }
            return true
        }

        XCTAssertEqual(phase, .failure, "网络失败必须映射为 .failure（AC-B17）")
    }

    // MARK: - ⑤ retry 用最近一次 query

    func testRetryUsesLastNonEmptyQuery() async {
        let hangzhou = makeCity("杭州", lat: 30.25, lon: 120.17)
        // 第一次调用抛网络错误，第二次成功。
        let provider = FakeGeocodingProvider { _, index in
            if index == 0 { throw WeatherError.network("offline") }
            return [hangzhou]
        }
        let model = CitySearchModel(provider: provider, debounceSeconds: 0)

        model.queryChanged("杭州")
        // 等第一次失败落定。
        _ = await waitForPhase(of: model) { phase in
            if case .failure = phase { return true }
            if case .loading = phase { return false }
            if case .idle = phase { return false }
            return true
        }

        model.retry()

        let phase = await waitForPhase(of: model) { phase in
            if case .results = phase { return true }
            return false
        }

        guard case .results(let cities) = phase else {
            XCTFail("retry 后期望 .results，实际 \(phase)")
            return
        }
        XCTAssertEqual(cities.map(\.name), ["杭州"])
        let queries = await provider.queries
        XCTAssertEqual(queries, ["杭州", "杭州"], "retry 必须复用最近一次非空 query")
    }

    /// 空白输入回 idle，且不触发搜索。
    func testBlankInputResetsToIdleWithoutSearching() async {
        let provider = FakeGeocodingProvider { _, _ in [] }
        let model = CitySearchModel(provider: provider, debounceSeconds: 0)

        model.queryChanged("   ")

        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(model.phase, .idle)
        let queries = await provider.queries
        XCTAssertTrue(queries.isEmpty, "空白输入不得发起搜索")
    }
}

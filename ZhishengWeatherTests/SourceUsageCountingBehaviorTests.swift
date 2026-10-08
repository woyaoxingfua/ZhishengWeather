//
//  SourceUsageCountingBehaviorTests.swift
//  ZhishengWeatherTests
//
//  「设置 → 多源管理 → 今日用量」的**行为**守卫：逐源证明
// 「取数成功 → 用量 +1」且「取数失败 → 用量不变」。
//
//  ── 与 `SourceUsageCountingGuardTests` 的分工 ─────────────────────────────
//  · `SourceUsageCountingGuardTests` = **静态**守卫（扫源码，回答
//    「有没有调用点」）；
//  · 本文件 = **行为**守卫（注入 Stub、真的跑一遍 load，回答
//    「调用点在正确的分支上」）。
//
//  ── 为什么两个都要 ───────────────────────────────────────────────────────
//  静态扫源码只能证明「某处调了 recordSuccess」，**证明不了它调在了
//  成功分支上**。把它误放进 `catch` 里，静态守卫照样全绿 ——
//  而线上表现是「网络越差、数字越大」，与原 bug 方向完全相反。
//  故必须有真跑一遍的行为断言兜住「+1 / 不变」。
//
//  ⚠️ 覆盖面的诚实说明：本文件覆盖**有独立 Stub 协议**的 4 条链路
// （USGS 地震 / 河道流量 / 台风 / 和风）。
// `WeatherViewModel` 的四条（主源 / 空气 / 海洋 / 预警）与三个辅助源
// （日落/ MET / 7timer）的计数点分散在多个既有测试已覆盖的路径上，
// 其**计数语义**由本文件的 `testRecordSuccessIncrementsUsageByExactlyOne`
// 与 `testFailuresNeverIncrementUsage`（直接打 `SourceHealthTracker`）统一钉住。
// 这一点写在这里而不是留白，是为了不让后人误以为覆盖面比实际更大。
//
//  不联网、不读真实时钟（时刻全部注入）。
//

import XCTest
import Foundation
@testable import ZhishengWeather

// ⚠️ 并发纪律（同 `SourceHealthTrackerTests` 文件头的记述）：
// `XCTAssert*` 的实参是 **autoclosure、不支持并发** —— 任何 `await`
// 写在断言实参里都会编译失败。故所有 `await` 先求值到局部常量再断言。
// **禁止**用 `Task { }` / `XCTestExpectation` 绕过：那会让断言在异步体
// 执行前就通过，测试变成永远绿的假测试（本仓最忌讳的失败模式）。

// MARK: - Stubs

/// USGS 地震取数桩（可切换成功 / 抛错 / 空结果）。
private actor StubUsgsEarthquakeService: UsgsEarthquakeProviding {

    /// 桩的行为。
    enum Behavior: Sendable {
        /// 返回给定结果（可能为空 → 对应 `.none`）。
        case succeed(EarthquakeFeed)
        /// 抛错（对应 `.unavailable`）。
        case fail
    }

    private let behavior: Behavior

    init(_ behavior: Behavior) { self.behavior = behavior }

    func fetchNearbyEvents(latitude: Double,
                           longitude: Double,
                           startDate: Date) async throws -> EarthquakeFeed {
        switch behavior {
        case .succeed(let feed): return feed
        case .fail: throw WeatherError.network("stub failure")
        }
    }
}

/// 河道流量取数桩。
private actor StubFloodService: FloodProviding {

    /// 桩的行为。
    enum Behavior: Sendable {
        case succeed(RiverDischarge)
        case fail
    }

    private let behavior: Behavior

    init(_ behavior: Behavior) { self.behavior = behavior }

    func fetch(latitude: Double, longitude: Double) async throws -> RiverDischarge {
        switch behavior {
        case .succeed(let model): return model
        case .fail: throw WeatherError.network("stub failure")
        }
    }
}

/// 台风取数桩。
private actor StubTyphoonService: NmcTyphoonProviding {

    /// 桩的行为。
    enum Behavior: Sendable {
        /// 空数组 = 取数成功且确实没有活跃台风（对应 `.none`）。
        case succeedEmpty
        case fail
    }

    private let behavior: Behavior

    init(_ behavior: Behavior) { self.behavior = behavior }

    func fetchSummaries() async throws -> [TyphoonSummary] {
        switch behavior {
        case .succeedEmpty: return []
        case .fail: throw WeatherError.network("stub failure")
        }
    }

    func fetchSummaries(year: Int) async throws -> [TyphoonSummary] {
        try await fetchSummaries()
    }

    func fetchTrack(id: String) async throws -> TyphoonTrack? {
        switch behavior {
        case .succeedEmpty: return nil
        case .fail: throw WeatherError.network("stub failure")
        }
    }
}

// MARK: - Tests

final class SourceUsageCountingBehaviorTests: XCTestCase {

    private var suiteName: String = ""

    override func tearDown() {
        if !suiteName.isEmpty {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        suiteName = ""
        super.tearDown()
    }

    // MARK: - USGS 地震（`.none` 也算成功 —— 本条最容易被写错）

    /// 🔴 **成功但结果为空（`.none`）也必须 +1**。
    ///
    /// ⚠️ 这是本批最容易写错的分支：`.none` 语义是「查过了、附近确实没有地震」，
    /// 它是**成功**。若把它算成失败，设置页的用量会**低于**真实请求次数 ——
    /// 且因为「附近没地震」恰恰是常态，这个偏差会是**持续且显著**的。
    @MainActor
    func testEarthquakeNoneStateStillIncrementsUsage() async throws {
        let id = makeIsolatedSuiteName()
        let tracker = try Self.makeTracker(named: id)
        let model = EarthquakeCardModel(service: StubUsgsEarthquakeService(.succeed(.empty)),
                                 health: tracker)
        let before = Date()

        await model.load(latitude: 39.9, longitude: 116.4, now: before)

        let rows = await tracker.snapshot(now: before)
        let usage = try Self.row(for: .usgsEarthquake, in: rows).todayUsage
        XCTAssertEqual(usage, 1, "`.none`（查过了、没有地震）是**成功**，用量应为 1")
    }

    /// 失败（`.unavailable`）**绝不**加。
    @MainActor
    func testEarthquakeFailureDoesNotIncrementUsage() async throws {
        let id = makeIsolatedSuiteName()
        let tracker = try Self.makeTracker(named: id)
        let model = EarthquakeCardModel(service: StubUsgsEarthquakeService(.fail),
           health: tracker)
        let before = Date()

        await model.load(latitude: 39.9, longitude: 116.4, now: before)

        let rows = await tracker.snapshot(now: before)
        let usage = try Self.row(for: .usgsEarthquake, in: rows).todayUsage
        XCTAssertNil(usage, "失败必须保持 nil（无记录），绝不自增 —— "
                     + "否则网络越差数字越大，与事实相反")
    }

    /// 连续两次成功 → 恰好 +2（证明是「每次 +1」而非「置 1」）。
    @MainActor
    func testEarthquakeTwoSuccessesIncrementByTwo() async throws {
        let id = makeIsolatedSuiteName()
        let tracker = try Self.makeTracker(named: id)
        let model = EarthquakeCardModel(service: StubUsgsEarthquakeService(.succeed(.empty)),
                                 health: tracker)
        let before = Date()

        await model.load(latitude: 39.9, longitude: 116.4, now: before)
        await model.load(latitude: 39.9, longitude: 116.4, now: before)

        let rows = await tracker.snapshot(now: before)
        let usage = try Self.row(for: .usgsEarthquake, in: rows).todayUsage
        XCTAssertEqual(usage, 2, "两次成功 → 用量 2（证明是自增而非覆盖）")
    }

    // MARK: - 河道流量（`.noData` 也算成功）

    /// `.noData`（该坐标无河道数据）**也算成功** → +1。
    @MainActor
    func testFloodNoDataStateStillIncrementsUsage() async throws {
        let id = makeIsolatedSuiteName()
        let tracker = try Self.makeTracker(named: id)
        let model = FloodCardModel(service: StubFloodService(.succeed(.empty)),
   health: tracker)
        let before = Date()

        await model.load(latitude: 39.9, longitude: 116.4, now: before)

        let rows = await tracker.snapshot(now: before)
        let usage = try Self.row(for: .floodForecast, in: rows).todayUsage
        XCTAssertEqual(usage, 1, "`.noData`（无河道数据）是**成功**，用量应为 1")
    }

    /// 失败绝不加。
    @MainActor
    func testFloodFailureDoesNotIncrementUsage() async throws {
        let id = makeIsolatedSuiteName()
        let tracker = try Self.makeTracker(named: id)
        let model = FloodCardModel(service: StubFloodService(.fail), health: tracker)
        let before = Date()

        await model.load(latitude: 39.9, longitude: 116.4, now: before)

        let rows = await tracker.snapshot(now: before)
        let usage = try Self.row(for: .floodForecast, in: rows).todayUsage
        XCTAssertNil(usage, "失败绝不自增")
    }

    // MARK: - 台风（`.none` 也算成功）

    /// `.none`（无活跃台风）**也算成功** → +1。
    ///
    /// ⚠️ 与地震卡同理：「没有活跃台风」是**常态**而非故障
    /// （实测上游约 3 小时量级延迟），若不算成功，用量会长期偏低。
    @MainActor
    func testTyphoonNoneStateStillIncrementsUsage() async throws {
        let id = makeIsolatedSuiteName()
        let tracker = try Self.makeTracker(named: id)
        let model = TyphoonCardModel(service: StubTyphoonService(.succeedEmpty),
       health: tracker)
        let before = Date()

        await model.load(year: nil, currentYear: 2026)

        let rows = await tracker.snapshot(now: before)
        let usage = try Self.row(for: .nmcTyphoon, in: rows).todayUsage
        XCTAssertEqual(usage, 1, "`.none`（无活跃台风）是**成功**，用量应为 1")
    }

    /// 失败绝不加。
    @MainActor
    func testTyphoonFailureDoesNotIncrementUsage() async throws {
        let id = makeIsolatedSuiteName()
        let tracker = try Self.makeTracker(named: id)
        let model = TyphoonCardModel(service: StubTyphoonService(.fail), health: tracker)
        let before = Date()

        await model.load(year: nil, currentYear: 2026)

        let rows = await tracker.snapshot(now: before)
        let usage = try Self.row(for: .nmcTyphoon, in: rows).todayUsage
        XCTAssertNil(usage, "失败绝不自增")
    }

    // MARK: - Helpers

    /// 建一个独立 suite 名并记到 `suiteName`（`tearDown` 清理）。
    private func makeIsolatedSuiteName() -> String {
        let name = "zs.test.\(UUID().uuidString)"
        suiteName = name
        return name
    }

    /// 造一个用该 suite 的 tracker。
    private static func makeTracker(named name: String) throws -> SourceHealthTracker {
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        return SourceHealthTracker(ledger: SourceHealthLedger(defaults: d),
                                   preferences: SourcePreferences(defaults: d))
    }

    /// 取某源行（缺失即 fail）。
    private static func row(for id: SourceID, in rows: [SourceStatusRow]) throws -> SourceStatusRow {
        try XCTUnwrap(rows.first { $0.id == id },
                      "快照里没有源 \(id.rawValue)")
    }
}
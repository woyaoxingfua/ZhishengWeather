//
//  NavigationPathStoreTests.swift
//  ZhishengWeatherTests
//
//  NavigationPathStore 单测：往返一致性、容错降级、空路径合法性。
//
//  ── 为什么这些用例必须存在 ──────────────────────────────────────────
//  本层站在**冷启动路径**上：它一旦抛错或崩，App 直接起不来。因此
//  「解码失败必须降级为空路径且不抛错」不是锦上添花，而是它**唯一可接受**
//  的失败语义。本文件把这个语义钉死，防止后续改动把它改回抛错。
//
//  ⚠️ 测试不构造 ContentView（SwiftUI 视图无法在 XCTest 里可靠断言），
//  只测纯存储层 —— 这是本仓既有的分层纪律（视图不做单测，逻辑层才做）。
//

import SwiftUI
import XCTest
@testable import ZhishengWeather

@MainActor
final class NavigationPathStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: NavigationPathStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 独立 suite：绝不污染 UserDefaults.standard（同 AppDiagnosticsStoreTests 纪律）。
        suiteName = "zs.test.navpath.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName), "无法创建临时 suite")
        store = NavigationPathStore(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: NavigationPathStore.key)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - 往返

    /// 编码 → 解码 → 再编码：三次结果必须一致（栈内容与顺序都没丢）。
    ///
    /// 🔴🔴 **断言方式已更正**（CI run#37801357216 实测失败）：
    /// 原实现写的是 `XCTAssertEqual(restored.path, path)`，
    /// 理由是「`NavigationPath` Conforms To `Equatable`，比的是栈内容」。
    /// ⚠️ **这个推理是错的** —— `Conforms To` 那一栏**确实**有 `Equatable`，
    ///   但**类型擦除容器无法逐元素比对**，其 `==` 对**含元素的两个栈恒为 false**
    ///   （CI 实测：两栈明明都是 `[cities, settings]`，断言仍失败）。
    ///   ⇒ 「文档里写了 Conforms To: Equatable」**不能推出**「可用于内容断言」。
    ///
    /// ✅ **正确判据：比对 `path.codable` 编码出的字节** ——
    ///   `CodableRepresentation` 是 `Encodable`，字节相同即内容与顺序完全相同，
    ///   这才是「内容一致」的强断言（且不依赖任何未文档化的 `==` 语义）。
    func testRoundTripPreservesStackContent() throws {
        var path = NavigationPath()
        path.append(CityRoute.cities)
        path.append(CityRoute.settings)
        let expected = try Self.encodedBytes(of: path)

        store.save(path)
        let restored = store.restore()

        XCTAssertEqual(restored.outcome, .restored(depth: 2))
        XCTAssertEqual(restored.path.count, 2)
        XCTAssertEqual(try Self.encodedBytes(of: restored.path), expected,
                       "恢复后的栈内容与顺序必须与保存前逐字节一致")

        // 再存一次：二次编码必须产出**同样的字节**（序列化稳定，不引入随机性）。
        store.save(restored.path)
        let second = store.restore()
        XCTAssertEqual(try Self.encodedBytes(of: second.path), expected,
                       "二次往返后栈内容与顺序仍须一致")
        XCTAssertEqual(second.outcome, .restored(depth: 2))
    }

    /// 🔴 路径 → `CodableRepresentation` 的**字节**（比对内容与顺序的唯一可靠方式）。
    ///
    /// ⚠️ `path.codable` 在**任一元素不满足 `Codable`** 时为 `nil`（Apple 文档原文），
    ///   故此处必须 `XCTUnwrap`，nil 意味着测试环境已破坏。
    private static func encodedBytes(of path: NavigationPath) throws -> Data {
        let representation = try XCTUnwrap(path.codable,
                                           "路径应可编码；若为 nil 说明元素不满足 Codable")
        return try JSONEncoder().encode(representation)
    }

    /// 单元素栈（最常见：只进了设置页）。
    func testRoundTripSingleElement() throws {
        var path = NavigationPath()
        path.append(CityRoute.settings)

        store.save(path)
        let restored = store.restore()

        XCTAssertEqual(restored.outcome, .restored(depth: 1))
        XCTAssertEqual(restored.path.count, 1)
        // 🔴 逐字节比对，**不用** `XCTAssertEqual(restored.path, path)`
        //   —— 类型擦除容器的 `==` 对含元素的两栈恒为 false（CI run#37801357216 实测）。
        XCTAssertEqual(try Self.encodedBytes(of: restored.path),
                       try Self.encodedBytes(of: path),
                       "单元素栈的内容与顺序也须逐字节一致")
    }

    // MARK: - 空路径是合法初始态（不是失败）

    /// 空栈落盘 → 恢复后仍是首页，且**键被清掉**。
    ///
    /// ⚠️ 这是**合法初始态**，绝不能被当成失败：首次启动走的就是这条路径。
    func testEmptyPathRestoresToHomeAndClearsKey() {
        store.save(NavigationPath())
        XCTAssertNil(defaults.data(forKey: NavigationPathStore.key),
                     "空栈不应留字节（否则会把「就在首页」说成「存过一个空栈」）")

        let restored = store.restore()
        XCTAssertEqual(restored.outcome, .empty, "空栈必须报 .empty 而不是 .unavailable")
        XCTAssertTrue(restored.path.isEmpty)
        XCTAssertEqual(restored.path.count, 0)
    }

    /// 从未存过（首次启动）→ `.empty`，不是故障。
    func testNeverSavedReportsEmpty() {
        let restored = store.restore()
        XCTAssertEqual(restored.outcome, .empty)
        XCTAssertTrue(restored.path.isEmpty)
    }

    // MARK: - 容错降级（本层最重要的用例）

    /// 垃圾字节 → 降级空路径 + `.unavailable`，**不抛错**。
    func testGarbageBytesDegradeToEmptyPath() {
        defaults.set(Data("not-a-navigation-path".utf8), forKey: NavigationPathStore.key)

        let restored = store.restore()
        XCTAssertEqual(restored.path, NavigationPath(), "垃圾数据必须降级为空路径")
        XCTAssertTrue(restored.path.isEmpty)
        guard case .unavailable = restored.outcome else {
            return XCTFail("垃圾数据必须报 .unavailable，实际是 \(restored.outcome)")
        }
    }

    /// 旧格式 / 结构变了（形状对但内容类型不对）→ 同样降级，绝不崩。
    ///
    /// 这条模拟「App 升级后导航元素类型改了」—— 用户的旧字节读不出来是
    /// **必然**的，层必须扛住，而不是让 App 起不来。
    func testLegacyOrAlteredShapeDegradesToEmptyPath() {
        // 一个合法 JSON，但形状不是 CodableRepresentation。
        defaults.set(Data("{\"unexpected\":\"shape\"}".utf8), forKey: NavigationPathStore.key)

        let restored = store.restore()
        XCTAssertTrue(restored.path.isEmpty)
        guard case .unavailable = restored.outcome else {
            return XCTFail("结构不符必须报 .unavailable，实际是 \(restored.outcome)")
        }
    }

    /// 空字节（存过但被截断）→ 降级空路径，不抛错。
    func testEmptyDataDegradesToEmptyPath() {
        defaults.set(Data(), forKey: NavigationPathStore.key)

        let restored = store.restore()
        XCTAssertTrue(restored.path.isEmpty)
        guard case .unavailable = restored.outcome else {
            return XCTFail("空字节必须报 .unavailable，实际是 \(restored.outcome)")
        }
    }

    /// 降级时**保留原字节**：一次读失败不该抹掉用户上次的返回路径。
    ///
    /// 依据：同 `AppDiagnosticsStore.loadLog()` 的纪律 —— 坏数据留给下一次
    /// 成功写入自然修正，绝不因读失败清数据。
    func testDegradeKeepsOriginalBytes() {
        let garbage = Data("corrupt-but-maybe-recoverable".utf8)
        defaults.set(garbage, forKey: NavigationPathStore.key)

        _ = store.restore()
        XCTAssertEqual(defaults.data(forKey: NavigationPathStore.key), garbage,
                       "读失败不得删除既有字节")
    }

    /// 降级后再存一次正常栈 → 能恢复（坏数据被自然修正，不永久卡死）。
    func testGoodWriteAfterDegradeRecovers() throws {
        defaults.set(Data("corrupt".utf8), forKey: NavigationPathStore.key)
        _ = store.restore()

        var path = NavigationPath()
        path.append(CityRoute.settings)
        store.save(path)

        let restored = store.restore()
        XCTAssertEqual(restored.outcome, .restored(depth: 1))
        XCTAssertEqual(restored.path.count, 1)
        // 🔴 逐字节比对，**不用** `XCTAssertEqual(restored.path, path)`
        //   —— 类型擦除容器的 `==` 对含元素的两栈恒为 false（CI run#37801357216 实测）。
        XCTAssertEqual(try Self.encodedBytes(of: restored.path),
                       try Self.encodedBytes(of: path),
                       "单元素栈的内容与顺序也须逐字节一致")
    }

    // MARK: - CityRoute 可编码性（NavigationPath 落盘的前置条件）

    /// `CityRoute` 必须 `Codable` —— 否则 `path.codable` 恒为 nil，栈存不下来。
    ///
    /// 本仓 P-24（编造 API 是最常见的严重错误）要求「写符号前先确认真实存在」；
    /// 这个用例把该前提钉成可执行断言，而不是靠注释里的口头保证。
    func testCityRouteIsCodableAndEncodesToBytes() throws {
        let data = try JSONEncoder().encode(CityRoute.settings)
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(CityRoute.self, from: data),
                       CityRoute.settings)
    }

    /// 两个 case 都能往返（枚举新增 case 时，本用例会提醒补齐解码测试）。
    func testBothCityRouteCasesRoundTrip() throws {
        for route in [CityRoute.cities, CityRoute.settings] {
            let data = try JSONEncoder().encode(route)
            XCTAssertEqual(try JSONDecoder().decode(CityRoute.self, from: data), route)
        }
    }
}
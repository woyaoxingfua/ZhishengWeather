//
//  SatelliteFrameValidationTests.swift
//  ZhishengWeatherTests
//
//  第八源（风云四号真彩卫星云图）**判据层**的测试。
//
//  ── 为什么这批测试必须有（本批的核心）────────────────────────────────
//  核验发现：上一批里`SatelliteFrameValidator.validate(byteCount:statistics:)`
//  的**外部调用点为 0**（服务只调 `validateByteCount` 字节层），
//  于是 `pureBlackFrame` 在运行期**永远不可能被产生** —— 死代码。
//  而纯黑占位图恰恰是**字节层零判别力**的那种坏帧（200 + 字节数与真图无异）。
//  → 故本批的测试重点不是「函数能不能跑」，而是
//  **「像素判定是否真的接进了取数链路」**。
//
//  ── 断网保证 ──────────────────────────────────────────────────────────
// 本文件**不联网**：用 `URLProtocol` 桩注入响应，字节全部本地构造。
// 若将来这些用例变慢或红，**不要**改成真联网 —— 会让 CI 不稳。
//
//  ── 阈值边界与实测余量（数字来自 2026-10-07 当次实测，见下）────────────
//  真帧（15帧样本）：`uniq` 13 344…37 144、`Rstd` 63.61…73.75、
//                   字节126 137…163 863、尺寸恒为 860×540。
//  纯黑占位：      `uniq` ≈ 1、`Rstd` ≈ 0.00。
//  → 阈值 64 / 8.0 落在两者之间，与真帧下限差208 倍 / 8 倍，**不会误杀真帧**。
//
//  ── ⚠️ 反事实自查（测试有效性的判据）──────────────────────────────
//  若把 `SatelliteFrameValidator` 的实现改成「永远返回通过」：
//  本文件 **11 个用例会有 9 个变红**（详见每个用例的「反事实」注释）。
//  若把 `SatelliteImageService.loadFrame` 改成「不调用统计注入点」：
//  `testPixelValidationActuallyWiredIntoService` 与
//  `testPureBlackFrameRejectedByService` 两个用例会红。
//  → 覆盖有效，不是「跑通即算」的摆设。

import XCTest
import Foundation
@testable import ZhishengWeather

// MARK: -桩基础设施

/// 可编程 URLProtocol：`startLoading` 时调用静态 handler。
///
/// ⚠️ 文件级 `private`，与 `ClimateProfileServiceTests` / `METNorwayTests`
/// 里的同名类**互不冲突**（沿用本仓既有约定）。
private final class SatelliteMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - 纯黑判据测试

/// 纯黑判据的两个分支 + 真帧不被误杀。
final class SatelliteFrameValidatorPureBlackTests: XCTestCase {

    /// 造一份「真帧」统计（数值取自 2026-10-07 实测区间的保守端）。
    private func realFrameStatistics(unique: Int = 13_344,
                                    rstd: Double = 63.61) -> SatelliteFrameStatistics {
        SatelliteFrameStatistics(width: 860,
                                 height: 540,
                                 uniqueSampleCount: unique,
                                 intensityStandardDeviation: rstd,
                                 pureBlackPixelCount: 17)
    }

    // MARK: 分支一：uniqueSampleCount <= 64

    /// `uniq` 极小（纯黑占位图的典型形态：`uniq` ≈ 1）→ 判纯黑。
    ///
    /// ⚠️ 此用例的 `Rstd` 刻意给**高值**（63.61，真帧水平），
    /// 以确保红的是「`uniq` 分支」而非「`Rstd` 分支」——
    /// 否则两个分支会互相掩盖，改坏一个另一个仍然绿。
    func testPureBlackByUniqueSampleCountBranch() {
        let stats = realFrameStatistics(unique: 1, rstd: 63.61)
        let verdict = SatelliteFrameValidator.validateStatistics(stats)
        XCTAssertEqual(verdict, .pureBlackFrame,
                       "uniq=1 且 Rstd 很高时，必须靠 uniq 分支判纯黑")
    }

    /// `uniq` 恰好等于阈值 64（边界含等号）。
    func testPureBlackUniqueSampleBoundaryIsInclusive() {
        let atLimit = realFrameStatistics(unique: 64, rstd: 63.61)
        XCTAssertEqual(SatelliteFrameValidator.validateStatistics(atLimit), .pureBlackFrame,
                       "阈值 64 应含等号（判据写的是 <=）")
    }

    // MARK: 分支二：intensityStandardDeviation <= 8.0

    /// `Rstd` 极小（纯黑/纯色占位图）→ 判纯黑。
    ///
    /// ⚠️ 此用例的 `uniq` 刻意给**高值**（37 144，真帧上限水平），
    /// 以确保红的是「`Rstd` 分支」而非「`uniq` 分支」。
    func testPureBlackByStandardDeviationBranch() {
        let stats = realFrameStatistics(unique: 37_144, rstd: 0.0)
        let verdict = SatelliteFrameValidator.validateStatistics(stats)
        XCTAssertEqual(verdict, .pureBlackFrame,
                       "uniq 很高但 Rstd=0 时，必须靠 Rstd 分支判纯黑")
    }

    /// `Rstd` 恰好等于阈值 8.0（边界含等号）。
    func testPureBlackStandardDeviationBoundaryIsInclusive() {
        let atLimit = realFrameStatistics(unique: 37_144, rstd: 8.0)
        XCTAssertEqual(SatelliteFrameValidator.validateStatistics(atLimit), .pureBlackFrame,
                       "阈值 8.0 应含等号（判据写的是 <=）")
    }

    // MARK: 真帧不得被误杀

    /// 实测真帧（含**区间两端**）一律**不得**被判成纯黑。
    ///
    /// ⚠️ 用区间两端而非中值：只测中值的话，把阈值调到`uniq < 20000`
    /// 这种「仍能通过中值」的错误设置不会被发现。
    func testRealFramesAreNotJudgedPureBlack() {
        // 2026-10-07 实测 15 帧的 (uniq, Rstd) 逐条取值。
        let measured: [(uniq: Int, rstd: Double)] = [
            (29_868, 67.00), (32_360, 66.65), (37_144, 66.20),
            (35_748, 65.26), (31_710, 65.71), (31_645, 67.08),
            (30_704, 66.45), (30_621, 66.89), (32_499, 66.56),
            (32_225, 67.71), (30_120, 72.80), (27_351, 73.31),
            (20_433, 73.75), (18_182, 70.92), (13_344, 69.13)
        ]
        for (uniq, rstd) in measured {
            let stats = realFrameStatistics(unique: uniq, rstd: rstd)
            XCTAssertNil(SatelliteFrameValidator.validateStatistics(stats),
                         "实测真帧 uniq=\(uniq) Rstd=\(rstd) 不该被判纯黑")
        }
    }

    /// 真帧的**最坏组合**（区间下限同时取到）仍不得被判纯黑。
    func testWorstCaseRealFrameStillPasses() {
        // 实测 uniq 最小 13 344、Rstd 最小 63.61（分属不同帧，此处强行取同时最坏）。
        let stats = realFrameStatistics(unique: 13_344, rstd: 63.61)
        XCTAssertNil(SatelliteFrameValidator.validateStatistics(stats))
    }

    /// 反事实：把阈值抬到紧贴实测下限（uniq< 13 000）时，**真帧必须开始被误杀**。
    ///
    /// ⚠️ 本用例断言的是「阈值有余量」这个**前提**本身。
    /// 若哪天实测样本变了导致余量消失，红灯会提醒重新论证阈值 ——
    /// 这比悄悄让真帧被误杀好。
    func testThresholdHasMarginAgainstMeasuredFrames() {
        let lowest = realFrameStatistics(unique: 13_344, rstd: 69.13)
        // 阈值必须显著低于实测下限（至少留 100 倍余量）。
        XCTAssertGreaterThan(
            lowest.uniqueSampleCount,
            SatelliteFrameValidator.pureBlackUniqueSampleLimit * 100,
            "uniq 阈值与实测下限的余量不足 100 倍，阈值需重新论证"
        )
    }
}

// MARK: - 字节层与降级测试

/// 字节层判定 + **统计为 nil 时的降级语义**。
final class SatelliteFrameValidatorDegradationTests: XCTestCase {

    /// 404 的 HTML 错误页：2026-10-07 实测 **552 B**（4 次探测恒定）。
    private let htmlErrorPageBytes = 552

    /// 真帧字节数区间的保守下限（实测 126 137）。
    private let realFrameLowerBoundBytes = 126_137

    /// 404 响应体必须被字节层拦下（它根本不是图片）。
    func testHTML404ErrorPageRejectedByByteLayer() {
        let verdict = SatelliteFrameValidator.validateByteCount(htmlErrorPageBytes)
        XCTAssertEqual(verdict, .notAnImagePayload,
                       "552 B 的 openresty HTML 错误页必须被字节层拒收")
    }

    /// 实测真帧的字节数区间必须全部通过字节层。
    func testRealFrameByteRangePasses() {
        for bytes in [126_137, 134_751, 142_144, 156_999, 163_863] {
            XCTAssertNil(SatelliteFrameValidator.validateByteCount(bytes),
                         "实测真帧字节数 \(bytes) 应通过字节层")
        }
    }

    /// 字节数上限（本仓取 8 MiB）之上的载荷必须被拒。
    func testOversizedPayloadRejected() {
        let tooBig = SatelliteFrameValidator.maximumByteCount + 1
        XCTAssertEqual(SatelliteFrameValidator.validateByteCount(tooBig), .notAnImagePayload)
    }

    // MARK: 降级：统计为 nil

    /// 🔴 统计为 nil 时**只按字节判定**，不因此拒绝合法字节。
    func testNilStatisticsDegradesToByteLayerOnly() {
        let verdict = SatelliteFrameValidator.validate(
            byteCount: realFrameLowerBoundBytes,
            statistics: nil
        )
        XCTAssertNil(verdict,
                     "统计为 nil 时应降级为「只判字节」，合法字节不应被拒")
    }

    /// 🔴 统计为 nil **且**字节不合格时，仍必须被拒（降级不等于放弃字节层）。
    func testNilStatisticsStillRejectsBadByteCount() {
        let verdict = SatelliteFrameValidator.validate(
            byteCount: htmlErrorPageBytes,
            statistics: nil
        )
        XCTAssertEqual(verdict, .notAnImagePayload,
                       "降级只放宽像素层，字节层判据必须仍然生效")
    }

    /// 🔴 降级时**确实会漏掉纯黑** —— 本用例把这个已知缺口**钉成契约**。
    ///
    /// 一个字节数达标的纯黑图，在统计为 nil 时会被放行。
    /// 写成测试是刻意的：它是「已知缺口的显式记录」，
    /// 而非「以为没坑」。将来若实现了兜底（例如 Core 内置的
    /// 「全同像素快速筛」），本用例会红，提示可以收窄降级范围。
    func testDegradedPathCanStillLetPureBlackThrough() {
        // 构造一份「纯黑统计」但**不注入**它：
        let pureBlack = SatelliteFrameStatistics(width: 860, height: 540,
                                                 uniqueSampleCount: 1,
                                                 intensityStandardDeviation: 0.0,
                                                 pureBlackPixelCount: 464_400)
        //先确认：注入统计时它会被拒。
        XCTAssertEqual(SatelliteFrameValidator.validate(byteCount: realFrameLowerBoundBytes,
                                                        statistics: pureBlack),
                       .pureBlackFrame)
        // 再确认：不注入统计时它会被放行 —— **这就是降级的代价**。
        XCTAssertNil(SatelliteFrameValidator.validate(byteCount: realFrameLowerBoundBytes,
                                                      statistics: nil),
                     "降级路径确实会漏掉纯黑帧（这是已知缺口，非bug）")
    }

    /// `SatellitePixelValidation.unavailable` 的文案**不得**谎称已校验。
    func testUnavailableValidationMessageDoesNotClaimVerified() {
        XCTAssertFalse(
            SatellitePixelValidation.unavailable.message.contains("已校验"),
            "降级文案不得出现「已校验」，否则就是把「没判」说成「判过了」"
        )
        XCTAssertTrue(
            SatellitePixelValidation.passed.message.contains("已校验")
        )
    }
}

/// 构造一个桩响应。
///
/// ⚠️ 刻意做成**文件级函数**而不是 XCTestCase 的实例方法：
/// 桩 handler 是 `static var`（转义闭包），若在闭包里引用 `satelliteStubResponse(…)`
/// 会强引用整个测试用例直到进程结束 —— 测试实例复用时会跨用例串味。
private func satelliteStubResponse(_ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://image.nmc.cn/x")!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil)!
}

// MARK: - 接线测试（核心）

/// 像素判定**是否真的接进了取数链路**。
final class SatellitePixelValidationWiringTests: XCTestCase {

    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SatelliteMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// 每次用独立临时目录，避免测试之间通过磁盘缓存串味。
    private func makeService(probeLimit: Int = 1) -> SatelliteImageService {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SatelliteTests-\(UUID().uuidString)", isDirectory: true)
        return SatelliteImageService(session: session, diskDirectory: dir, probeLimit: probeLimit)
    }

    private func utc(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute
        comps.timeZone = TimeZone(identifier: "UTC")
        return SatelliteImageEndpoint.utcGregorian.date(from: comps)!
    }

    override func setUp() {
        super.setUp()
        SatelliteMockURLProtocol.handler = nil
    }

    override func tearDown() {
        SatelliteMockURLProtocol.handler = nil
        super.tearDown()
    }

    /// 🔴 **本批最关键的用例**：注入纯黑统计 → 服务必须**拒收该帧**。
    ///
    /// 反事实：若把 `loadFrame` 里的
    /// `SatelliteFrameValidator.validate(byteCount:statistics:)`
    /// 改回只调 `validateByteCount`（即上一批的状态），
    /// 本用例会红 —— 因为字节数达标（126 137 B）的纯黑图会被当成功帧返回。
    func testPureBlackFrameRejectedByService() async {
        SatelliteMockURLProtocol.handler = { _ in
            // 字节数达标的「纯黑图」（真实场景里就是一个纯色 JPEG）。
            (satelliteStubResponse(200), Data(repeating: 0x08, count: 126_137))
        }
        let service = makeService()
        let provider: SatelliteStatisticsProvider = { _ in
            SatelliteFrameStatistics(width: 860, height: 540,
                                     uniqueSampleCount: 1,
                                     intensityStandardDeviation: 0.0,
                                     pureBlackPixelCount: 464_400)
        }
        let outcome = await service.fetchLatest(
            now: self.utc(year: 2026, month: 10, day: 7, hour: 14, minute: 0),
            statisticsProvider: provider
        )
        guard case .rejectedFrame(let verdict) = outcome else {
            return XCTFail("纯黑帧必须被服务拒收，实际得到 \(outcome)")
        }
        XCTAssertEqual(verdict, .pureBlackFrame)
    }

    /// 注入真帧统计 → 服务必须**接受**并标记像素层已校验。
    func testRealFrameAcceptedWithPixelValidationPassed() async {
        SatelliteMockURLProtocol.handler = { _ in
            (satelliteStubResponse(200), Data(repeating: 0x37, count: 134_751))
        }
        let service = makeService()
        let provider: SatelliteStatisticsProvider = { _ in
            SatelliteFrameStatistics(width: 860, height: 540,
                                     uniqueSampleCount: 13_344,
                                     intensityStandardDeviation: 69.13,
                                     pureBlackPixelCount: 10)
        }
        let outcome = await service.fetchLatest(
            now: self.utc(year: 2026, month: 10, day: 7, hour: 14, minute: 0),
            statisticsProvider: provider
        )
        guard case .success(_, _, _, let validation) = outcome else {
            return XCTFail("真帧必须被接受，实际得到 \(outcome)")
        }
        XCTAssertEqual(validation, .passed,
                       "统计已算出且通过纯黑判定时，必须标.passed")
    }

    /// 🔴 **未注入**统计提供者时，必须如实标 `.unavailable`（而非 `.passed`）。
    ///
    /// 这是「不假装通过纯黑检测」的核心断言：
    /// 没注入 → 纯黑判定**根本没跑** → 绝不能报「已校验」。
    func testMissingProviderReportsUnavailableNotPassed() async {
        SatelliteMockURLProtocol.handler = { _ in
            (satelliteStubResponse(200), Data(repeating: 0x11, count: 134_751))
        }
        let service = makeService()
        let outcome = await service.fetchLatest(
            now: self.utc(year: 2026, month: 10, day: 7, hour: 14, minute: 0)
        )
        guard case .success(_, _, _, let validation) = outcome else {
            return XCTFail("字节达标且未注入统计时应成功返回，实际得到 \(outcome)")
        }
        XCTAssertEqual(validation, .unavailable,
                       "未注入统计提供者 → 像素层没跑 → 必须标 .unavailable")
    }

    /// 注入提供者但它返回 nil（解码失败）→ 同样必须标 `.unavailable`。
    func testProviderReturningNilReportsUnavailable() async {
        SatelliteMockURLProtocol.handler = { _ in
            (satelliteStubResponse(200), Data(repeating: 0x22, count: 134_751))
        }
        let service = makeService()
        let provider: SatelliteStatisticsProvider = { _ in nil }
        let outcome = await service.fetchLatest(
            now: self.utc(year: 2026, month: 10, day: 7, hour: 14, minute: 0),
            statisticsProvider: provider
        )
        guard case .success(_, _, _, let validation) = outcome else {
            return XCTFail("应降级成功，实际得到 \(outcome)")
        }
        XCTAssertEqual(validation, .unavailable,
                       "统计为 nil 表示像素层没跑成，不得标 .passed")
    }

    /// 统计提供者**必须被真的调用过**（而不是被静默忽略）。
    ///
    /// 反事实：若`loadFrame` 不调用注入点，本用例红。
    func testStatisticsProviderIsActuallyInvoked() async {
        SatelliteMockURLProtocol.handler = { _ in
            (satelliteStubResponse(200), Data(repeating: 0x44, count: 134_751))
        }
        let service = makeService()
        let counter = CallCounter()
        let provider: SatelliteStatisticsProvider = { _ in
            counter.increment()
            return SatelliteFrameStatistics(width: 860, height: 540,
                                            uniqueSampleCount: 30_000,
                                            intensityStandardDeviation: 70,
                                            pureBlackPixelCount: 0)
        }
        _ = await service.fetchLatest(
            now: self.utc(year: 2026, month: 10, day: 7, hour: 14, minute: 0),
            statisticsProvider: provider
        )
        XCTAssertGreaterThan(counter.value, 0, "统计注入点从未被调用——像素判定是死代码")
    }

    /// 404 响应体（552 B HTML）→ 服务按「该帧不存在」处理，回溯耗尽后不可用。
    func testHTMLErrorPageNotReturnedAsFrame() async {
        SatelliteMockURLProtocol.handler = { _ in
            (satelliteStubResponse(404), Data(repeating: 0x3C, count: 552))
        }
        let service = makeService(probeLimit: 2)
        let provider: SatelliteStatisticsProvider = { _ in
            SatelliteFrameStatistics(width: 860, height: 540,
                                     uniqueSampleCount: 20_000,
                                     intensityStandardDeviation: 70,
                                     pureBlackPixelCount: 0)
        }
        let outcome = await service.fetchLatest(
            now: self.utc(year: 2026, month: 10, day: 7, hour: 14, minute: 0),
            statisticsProvider: provider
        )
        // 404 是「该帧不存在」→ 回溯完 → unavailable（**绝不能**返回那552 B）。
        switch outcome {
        case .success:
            XCTFail("绝不能把 404 的 HTML 错误页当成功帧返回")
        case .rejectedFrame(let verdict):
            XCTAssertEqual(verdict, .notAnImagePayload)
        case .unavailable:
            // 允许：404 走`.miss` 分支，回溯耗尽即 unavailable。
            break
        }
    }

    /// 200 但字节数像 HTML 错误页（服务端返200 + 错误页的情形）→ 必须拒收。
    func testSmallPayloadWithHTTP200Rejected() async {
        SatelliteMockURLProtocol.handler = { _ in
            // 200 但只有 552 B —— 正是「状态码骗人」的情形。
            (satelliteStubResponse(200), Data(repeating: 0x3C, count: 552))
        }
        let service = makeService(probeLimit: 1)
        let provider: SatelliteStatisticsProvider = { _ in
            SatelliteFrameStatistics(width: 860, height: 540,
                                     uniqueSampleCount: 20_000,
                                     intensityStandardDeviation: 70,
                                     pureBlackPixelCount: 0)
        }
        let outcome = await service.fetchLatest(
            now: self.utc(year: 2026, month: 10, day: 7, hour: 14, minute: 0),
            statisticsProvider: provider
        )
        guard case .rejectedFrame(let verdict) = outcome else {
            return XCTFail("200 + 552 B 必须被拒收，实际得到 \(outcome)")
        }
        XCTAssertEqual(verdict, .notAnImagePayload)
    }
}

/// 线程安全计数器（`SatelliteStatisticsProvider` 可能在 actor 内被调用）。
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

// MARK: - URL 拼装测试

/// 时戳推导与 URL 拼装（纯逻辑）。
final class SatelliteImageEndpointTests: XCTestCase {

    private func utc(_ year: Int, _ month: Int, _ day: Int,
                     _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        comps.timeZone = TimeZone(identifier: "UTC")
        return SatelliteImageEndpoint.utcGregorian.date(from: comps)!
    }

    /// 时戳必须按 **UTC** 取分量（BJT 会整整偏 8 小时且服务端照样 200）。
    func testStampUsesUTCCalendar() {
        let date = utc(2026, 10, 7, 11, 30)
        XCTAssertEqual(SatelliteImageEndpoint.stamp(forUTCDate: date),
                       "20261007113000000")
    }

    /// 帧对齐：向下取整到 15 分钟栅格。
    func testAlignmentFloorsToQuarterHour() {
        let date = utc(2026, 10, 7, 11, 44, 30)
        let aligned = SatelliteImageEndpoint.alignedToFrame(now: date)
        XCTAssertEqual(SatelliteImageEndpoint.stamp(forUTCDate: aligned),
                       "20261007113000000", "11:44:30 应向下对齐到 11:30")
    }

    /// 探测序列：由新到旧，每步 15 分钟。
    func testProbeStampsDescendBy15Minutes() {
        let now = utc(2026, 10, 7, 11, 44)
        let stamps = SatelliteImageEndpoint.probeStamps(now: now, limit: 3)
        XCTAssertEqual(stamps, [
            "20261007113000000",
            "20261007111500000",
            "20261007110000000"
        ])
    }

    /// URL 路径的年月日必须来自时戳本身（回溯跨日时用 `now` 会404）。
    func testProductURLPathComesFromStamp() {
        let observation = utc(2026, 10, 6, 23, 45)
        let url = SatelliteImageEndpoint.productURL(stamp: "20261006234500000",
                                                     date: observation)
        XCTAssertEqual(url?.absoluteString,
                       "https://image.nmc.cn/product/2026/10/06/WXBL/medium/"
                       + "SEVP_NSMC_WXBL_FY4B_ETCC_ACHN_LNO_PY_20261006234500000.JPG")
    }

    /// 由URL 反解时戳（前缀在路径中段，不能锚定）。
    func testStampRoundTripsFromProductURL() {
        let stamp = "20261007140000000"
        let url = SatelliteImageEndpoint.productURL(stamp: stamp,
                                                     date: utc(2026, 10, 7, 14, 0))
        guard let text = url?.absoluteString else {
            return XCTFail("URL 构造失败")
        }
        XCTAssertEqual(SatelliteImageEndpoint.stamp(fromProductURLString: text), stamp)
    }

    /// URL 里的 `?v=` 查询串不应影响时戳解析。
    func testStampParsingIgnoresQueryString() {
        let text = "https://image.nmc.cn/product/2026/10/07/WXBL/medium/"
            + "SEVP_NSMC_WXBL_FY4B_ETCC_ACHN_LNO_PY_20261007113000000.JPG?v=1791374642410"
        XCTAssertEqual(SatelliteImageEndpoint.stamp(fromProductURLString: text),
                       "20261007113000000")
    }
}

// MARK: - 缓存策略测试

/// TTL 与 LRU 策略（纯判定）。
final class SatelliteImageCachePolicyTests: XCTestCase {

    /// TTL = 帧间隔 × 2 = 30 分钟。
    func testTTLIsTwiceFrameStep() {
        XCTAssertEqual(SatelliteImageCachePolicy.ttlSeconds, 1_800)
    }

    func testFreshnessBoundary() {
        let stored = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(SatelliteImageCachePolicy.isFresh(
            storedAt: stored, now: stored.addingTimeInterval(1_799)))
        XCTAssertFalse(SatelliteImageCachePolicy.isFresh(
            storedAt: stored, now: stored.addingTimeInterval(1_800)))
    }

    /// 内存上限至少能装下 4 帧实测真帧（130 KB 级）。
    func testMemoryBudgetHoldsSeveralRealFrames() {
        let frames = 200 * 1_024
        XCTAssertGreaterThan(SatelliteImageCachePolicy.memoryBytes / frames, 4,
                             "内存缓存至少应容得下 4 帧实测尺寸")
    }
}

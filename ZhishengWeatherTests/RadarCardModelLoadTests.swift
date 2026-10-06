//
//  RadarCardModelLoadTests.swift
//  ZhishengWeatherTests
//
//  `RadarCardModel.load` 的**并发守卫 + 超时兜底**测试。
//
//  ── 为什么补这一条（2026-10-06）──────────────────────────────────────
//  `load` 此前**没有任何测试**（`load(cityID:` 在测试里零命中），而它有两个
//  承载真机风险的分支，都没人验证过：
//  ① **超时兜底**：取数卡住时若一直转圈，用户看到的就是"功能正常只是慢"；
//     这是本卡唯一的不卡死保险。
//  ② **防串号守卫**：`load` 内两处 `guard currentCityID == cityID` ——
//     用户在等 A 城时切到 B 城，旧城结果必须被丢弃。
//
//  ── 断网保证 ─────────────────────────────────────────────────────────
//  本文件**不联网**：用 `URLProtocol` stub 把 `URLSession` 打成
//  「永不完成」（模拟卡住）与「立刻返回空 JSON」（模拟快失败），
//  确定性地制造超时 / 未超时。若将来变慢或红，**不要**改成真联网 —— 会让 CI 不稳。

import XCTest
@testable import ZhishengWeather

// MARK: - Stub 基础设施

/// 永不完成的 URLProtocol：进入后不回调任何 client 事件，也不 `stopLoading()`。
/// 用来确定性制造「取数卡住 → 超时」。
private final class HangingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // 故意**不**调用 client?.urlProtocol(...) 的任何一个回调。
    }
    override func stopLoading() {}
}

/// 立刻返回空 JSON 的 URLProtocol：模拟「快速返回但无有效数据」。
private final class EmptyJSONURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url,
                                             statusCode: 200,
                                             httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeStubbedSession(_ protocolClass: AnyClass) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [protocolClass]
    return URLSession(configuration: config)
}

// MARK: - 测试

/// `RadarCardModel` 是 `@MainActor @Observable`，故全部用例标 `@MainActor`。
@MainActor
final class RadarCardModelLoadTests: XCTestCase {

    /// 超时预算引用本仓唯一真源，不在测试里另写一个数字。
    private var budget: TimeInterval { RadarCardModel.loadTimeout }

    private func makeModel(_ protocolClass: AnyClass) -> RadarCardModel {
        let session = makeStubbedSession(protocolClass)
        return RadarCardModel(service: RainViewerService(session: session),
                              coverageService: RadarCoverageService(session: session))
    }

    /// ① 卡住 → 必须置 `hasTimedOut`（防"转圈卡死"），且 `isLoading` 复位。
    func testHangingFetchMarksTimedOutSoCardDoesNotSpinForever() async {
        let model = makeModel(HangingURLProtocol.self)

        // `now` 取「明显早于预算之前」；真正触发超时的是**完成时刻** Date()。
        let longAgo = Date().addingTimeInterval(-budget - 5)
        await model.load(cityID: "test-city", latitude: 39.9, longitude: 116.4, now: longAgo)

        XCTAssertTrue(model.hasTimedOut,
                      "取数卡住且已超预算时必须置 hasTimedOut，否则用户看到无限转圈")
        XCTAssertFalse(model.isLoading, "load 返回后 isLoading 必须复位")
    }

    /// ① 反向：快速返回 → **不得**误报超时（否则一直显示超时文案）。
    func testFastResponseDoesNotMarkTimedOut() async {
        let model = makeModel(EmptyJSONURLProtocol.self)

        await model.load(cityID: "test-city", latitude: 39.9, longitude: 116.4)

        XCTAssertFalse(model.hasTimedOut, "快速返回不得误报超时")
        XCTAssertFalse(model.isLoading, "load 返回后 isLoading 必须复位")
    }

    /// ② 切城必须更新 `currentCityID`，并复位超时/加载态（防旧城数据串到新城）。
    func testSwitchingCityUpdatesIDAndResetsFlags() async {
        let model = makeModel(EmptyJSONURLProtocol.self)

        await model.load(cityID: "city-a", latitude: 39.9, longitude: 116.4)
        XCTAssertEqual(model.currentCityID, "city-a", "前置：A 城已加载")

        await model.load(cityID: "city-b", latitude: 36.07, longitude: 120.38)

        XCTAssertEqual(model.currentCityID, "city-b", "切城后 currentCityID 必须更新")
        XCTAssertFalse(model.hasTimedOut, "切城后超时标记必须复位")
        XCTAssertNil(model.timeline, "切城先清空旧帧，避免旧城数据串号")
    }

    /// 预算常量本身钉死：若有人改动 `loadTimeout`，此用例提醒同步更新预期。
    func testLoadTimeoutConstant() {
        XCTAssertEqual(RadarCardModel.loadTimeout, 12, accuracy: 0.001,
                       "超时预算变更需同步更新 README / 设计与本用例")
    }
}

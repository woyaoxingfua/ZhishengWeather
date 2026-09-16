//
//  FaultDomainTests.swift
//  ZhishengWeatherTests
//
//  故障域分类 + 文案映射的**纯单测**（每个故障域一条精确断言）。
//
//  目的（review-2026-09-16-run37 §3）：错误文案必须按故障域重写，且每个域
//  都要能指认「下一步做什么」。这里逐域锁定**精确文案**，防止日后被人改回
//  一句泛化提示（同源盲区纪律：文案是单一真源，测试直接钉死它）。
//

import XCTest
@testable import ZhishengWeather

final class FaultDomainTests: XCTestCase {

    // MARK: - WeatherError → 故障域

    func testBadURLClassifiesToBadURL() {
        XCTAssertEqual(FaultDomain.classify(WeatherError.badURL), .badURL)
    }

    func testFourClientStatusClassifiesToHTTPClient() {
        XCTAssertEqual(FaultDomain.classify(WeatherError.badStatus(400)), .httpClient(400))
        XCTAssertEqual(FaultDomain.classify(WeatherError.badStatus(404)), .httpClient(404))
        XCTAssertEqual(FaultDomain.classify(WeatherError.badStatus(429)), .httpClient(429))
    }

    func testFiveServerStatusClassifiesToHTTPServer() {
        XCTAssertEqual(FaultDomain.classify(WeatherError.badStatus(500)), .httpServer(500))
        XCTAssertEqual(FaultDomain.classify(WeatherError.badStatus(503)), .httpServer(503))
    }

    func testNetworkClassifiesToNetworkUnreachable() {
        XCTAssertEqual(FaultDomain.classify(WeatherError.network("断网")),
                       .networkUnreachable("断网"))
    }

    func testTimeoutClassifiesToTimeout() {
        XCTAssertEqual(FaultDomain.classify(WeatherError.timeout("超时")), .timeout("超时"))
    }

    func testLegacyDecodingClassifiesToDecodeFailureWithoutPath() {
        XCTAssertEqual(FaultDomain.classify(WeatherError.decoding("坏")),
                       .decodeFailure(path: "", debugDescription: "坏"))
    }

    func testDecodingDetailPreservesCodingPath() {
        XCTAssertEqual(FaultDomain.classify(WeatherError.decodingDetail(path: "daily.sunrise",
                                                                       debugDescription: "类型不符")),
                       .decodeFailure(path: "daily.sunrise", debugDescription: "类型不符"))
    }

    func testDataMissingClassifiesToDataMissing() {
        XCTAssertEqual(FaultDomain.classify(WeatherError.dataMissing("杭州")), .dataMissing("杭州"))
    }

    func testAppGroupClassifiesToAppGroup() {
        XCTAssertEqual(FaultDomain.classify(WeatherError.appGroup("写失败")), .appGroup("写失败"))
    }

    // MARK: - URLError → 故障域

    func testURLErrorTimedOutClassifiesToTimeout() {
        guard case .timeout(_) = FaultDomain.classify(URLError(.timedOut)) else {
            return XCTFail("URLError.timedOut 必须归为 timeout")
        }
    }

    func testURLErrorNotConnectedClassifiesToNetworkUnreachable() {
        guard case .networkUnreachable(_) = FaultDomain.classify(URLError(.notConnectedToInternet)) else {
            return XCTFail("URLError.notConnectedToInternet 必须归为 networkUnreachable")
        }
    }

    // MARK: - 定位结果 → 故障域

    func testLocationOutcomeClassification() {
        XCTAssertNil(FaultDomain.classify(locationOutcome: .authorized), "已授权不是故障")
        XCTAssertEqual(FaultDomain.classify(locationOutcome: .denied), .locationDenied)
        XCTAssertNil(FaultDomain.classify(locationOutcome: .undetermined), "未作答保持静默回落")
        XCTAssertNil(FaultDomain.classify(locationOutcome: .failed), "单次失败保持静默回落")
    }

    // MARK: - 每个故障域的精确文案（逐条）

    func testNetworkUnreachableMessage() {
        XCTAssertEqual(FaultDomain.message(for: .networkUnreachable("x")),
                       "网络连接异常，请检查网络后下拉重试")
    }

    func testTimeoutMessage() {
        XCTAssertEqual(FaultDomain.message(for: .timeout("x")), "网络超时，请稍后重试")
    }

    func testHTTPClientMessageMentionsStatusCode() {
        XCTAssertEqual(FaultDomain.message(for: .httpClient(404)),
                       "请求有误（404），请检查所选城市后重试")
    }

    func testHTTPServerMessageMentionsStatusCode() {
        XCTAssertEqual(FaultDomain.message(for: .httpServer(503)),
                       "天气服务暂时不可用（503），请稍后再试")
    }

    func testDecodeFailureMessageReferencesFieldPath() {
        XCTAssertEqual(FaultDomain.message(for: .decodeFailure(path: "current.temperature_2m",
                                                               debugDescription: "类型不符")),
                       "天气数据结构与预期不符（字段 current.temperature_2m），可能是接口变更，已记录异常，建议反馈给开发者")
    }

    func testDecodeFailureWithoutPathFallsBackToShapeMessage() {
        XCTAssertEqual(FaultDomain.message(for: .decodeFailure(path: "",
                                                               debugDescription: "坏")),
                       "天气数据结构与预期不符（可能是接口变更），已记录异常，建议反馈给开发者")
    }

    func testDataMissingMessage() {
        XCTAssertEqual(FaultDomain.message(for: .dataMissing("杭州")),
                       "暂未获取到该城市的天气数据，请确认城市后重试")
    }

    func testLocationDeniedMessage() {
        XCTAssertEqual(FaultDomain.message(for: .locationDenied),
                       "定位权限被拒绝，请在系统设置中开启定位，或手动选择城市")
    }

    func testAppGroupMessage() {
        XCTAssertEqual(FaultDomain.message(for: .appGroup("写失败")),
                       "小组件共享数据异常，请检查 App Group 权限")
    }

    func testBadURLMessage() {
        XCTAssertEqual(FaultDomain.message(for: .badURL), "请求地址无效，请稍后重试")
    }

    func testUnknownMessage() {
        XCTAssertEqual(FaultDomain.message(for: .unknown("怪")), "遇到未知问题，请稍后重试")
    }

    /// 全量守卫：任何一个域都不得回落到"出错了"这类泛化文案。
    func testNoDomainYieldsGenericMessage() {
        let domains: [FaultDomain] = [
            .networkUnreachable(""), .timeout(""), .httpClient(400), .httpServer(500),
            .decodeFailure(path: "f", debugDescription: ""), .dataMissing(""),
            .locationDenied, .appGroup(""), .badURL, .unknown("")
        ]
        for domain in domains {
            let message = FaultDomain.message(for: domain)
            XCTAssertFalse(message.isEmpty, "\(domain) 文案不得为空")
            XCTAssertNotEqual(message, "出错了", "\(domain) 不得使用泛化文案")
        }
    }
}

// MARK: - 快照完整性（「请求的城市无数据」的判定）

final class SnapshotCompletenessTests: XCTestCase {

    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSnapshot(hourly: [HourlyPoint], daily: [DailyForecast]?) -> WeatherSnapshot {
        WeatherSnapshot(location: .beijing,
                        temperature: 23, apparentTemperature: 22,
                        weatherCode: 1, windSpeed: 2, windDirection: 90,
                        humidity: 50, isDay: true, hourly: hourly,
                        dailyHigh: 25, dailyLow: 15, daily: daily,
                        fetchedAt: anchor)
    }

    func testEmptyHourlyAndNoDailyIsEffectivelyEmpty() {
        XCTAssertTrue(SnapshotCompleteness.isEffectivelyEmpty(makeSnapshot(hourly: [], daily: nil)))
    }

    func testEmptyHourlyAndEmptyDailyIsEffectivelyEmpty() {
        XCTAssertTrue(SnapshotCompleteness.isEffectivelyEmpty(makeSnapshot(hourly: [], daily: [])))
    }

    func testNonEmptyHourlyIsNotEmpty() {
        let point = HourlyPoint(time: anchor, temperature: 20, weatherCode: 1)
        XCTAssertFalse(SnapshotCompleteness.isEffectivelyEmpty(makeSnapshot(hourly: [point], daily: nil)))
    }

    func testNonEmptyDailyIsNotEmpty() {
        let day = DailyForecast(date: anchor, weatherCode: 1, tempMax: 25, tempMin: 15,
                                precipitationProbability: nil)
        XCTAssertFalse(SnapshotCompleteness.isEffectivelyEmpty(makeSnapshot(hourly: [], daily: [day])))
    }
}

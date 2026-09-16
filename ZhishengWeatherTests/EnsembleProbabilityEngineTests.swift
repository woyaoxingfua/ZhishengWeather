//
//  EnsembleProbabilityEngineTests.swift
//  ZhishengWeatherTests
//
//  集合证据推导引擎（纯函数）：**手算成员集**，注释写明算术后断言精确数值。
//  覆盖：逐小时成员比例、分位（线性插值）、窗口聚合、阈值边界、nil 缺测、
//  成员数随数据（不硬编码）。
//

import XCTest
@testable import ZhishengWeather

final class EnsembleProbabilityEngineTests: XCTestCase {

    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    /// 由「逐小时 → 各成员值」的矩阵（hour-major）转成领域模型的 member-major 排布。
    /// - Parameter hourMajor: 每个小时间一行，行内为各成员值（顺序一致）。
    private func makeForecast(hourMajor: [[Double?]]) -> EnsembleForecast {
        guard let firstHour = hourMajor.first else {
            return EnsembleForecast(times: [], memberSeries: [], utcOffsetSeconds: 0)
        }
        let memberCount = firstHour.count
        let times = (0..<hourMajor.count).map { anchor.addingTimeInterval(Double($0) * 3600) }
        let memberSeries: [[Double?]] = (0..<memberCount).map { member in
            hourMajor.map { hour -> Double? in
                guard member < hour.count else { return nil }
                return hour[member]
            }
        }
        return EnsembleForecast(times: times, memberSeries: memberSeries, utcOffsetSeconds: 0)
    }

    // MARK: - 手算用例（核心）

    func testHandComputedEvidence() throws {
        // 成员矩阵（4 成员 × 2 小时；每行为一小时，列序 = 成员 0…3）：
        //   hour0 = [0.0, 0.2, 0.5, 1.0]   hour1 = [0.6, 0.6, 0.6, 0.6]
        // 阈值 0.1 mm/h。
        //
        // hour0：有效成员 4；超阈值者 = {0.2, 0.5, 1.0} → wetCount 3；fraction 3/4 = 0.75。
        //   升序 [0.0,0.2,0.5,1.0]，n=4，线性插值分位（rank=p*(n-1)）：
        //     p25: rank=0.75 → lower=0(0.0), upper=1(0.2), w=0.75 → 0.0*0.25+0.2*0.75 = 0.15
        //     p75: rank=2.25 → lower=2(0.5), upper=3(1.0), w=0.25 → 0.5*0.75+1.0*0.25 = 0.625
        //   min 0.0，max 1.0。
        // hour1：全部 0.6 → wetCount 4，fraction 4/4 = 1.0，min=p25=p75=max=0.6。
        //
        // 窗口聚合（任一小时 ≥0.1 即算「认为有雨」）：4 个成员各自 hour1 均为 0.6
        //   → wetMemberCount = 4。
        // 峰值时段：fraction 1.0（hour1）> 0.75（hour0）→ peak = hour1。
        let forecast = makeForecast(hourMajor: [
            [0.0, 0.2, 0.5, 1.0],
            [0.6, 0.6, 0.6, 0.6]
        ])

        let evidence = try XCTUnwrap(EnsembleProbabilityEngine.evidence(for: forecast))
        XCTAssertEqual(evidence.memberCount, 4)
        XCTAssertEqual(evidence.threshold, 0.1, accuracy: 1e-12)

        let hour0 = try XCTUnwrap(evidence.hourly.first)
        XCTAssertEqual(hour0.wetCount, 3)
        XCTAssertEqual(hour0.memberCount, 4)
        XCTAssertEqual(hour0.fraction, 0.75, accuracy: 1e-12)
        XCTAssertEqual(hour0.minValue, 0.0, accuracy: 1e-12)
        XCTAssertEqual(hour0.p25, 0.15, accuracy: 1e-12)
        XCTAssertEqual(hour0.p75, 0.625, accuracy: 1e-12)
        XCTAssertEqual(hour0.maxValue, 1.0, accuracy: 1e-12)

        let hour1 = try XCTUnwrap(evidence.hourly.last)
        XCTAssertEqual(hour1.wetCount, 4)
        XCTAssertEqual(hour1.fraction, 1.0, accuracy: 1e-12)
        XCTAssertEqual(hour1.p25, 0.6, accuracy: 1e-12)

        XCTAssertEqual(evidence.wetMemberCount, 4)
        XCTAssertEqual(evidence.peakHour?.time, hour1.time, "峰值应落在比例最高的 hour1")
    }

    // MARK: - 阈值边界

    func testThresholdBoundaryIsInclusive() throws {
        // 阈值 0.1：恰好 0.1 计入（≥），0.09 不计。
        let forecast = makeForecast(hourMajor: [[0.1, 0.09, 0.1001]])
        let evidence = try XCTUnwrap(EnsembleProbabilityEngine.evidence(for: forecast))
        let hour = try XCTUnwrap(evidence.hourly.first)
        XCTAssertEqual(hour.memberCount, 3)
        XCTAssertEqual(hour.wetCount, 2, "0.1 与 0.1001 计入，0.09 不计")
        XCTAssertEqual(evidence.wetMemberCount, 2)
    }

    // MARK: - nil 缺测（该小时有效成员数下降）

    func testNilValuesReduceHourlyMemberCount() throws {
        // hour0 成员 0 缺测 → 该小时有效成员 2，均超阈值 → fraction 2/2 = 1.0。
        let forecast = makeForecast(hourMajor: [[nil, 0.3, 0.5]])
        let evidence = try XCTUnwrap(EnsembleProbabilityEngine.evidence(for: forecast))
        let hour = try XCTUnwrap(evidence.hourly.first)
        XCTAssertEqual(hour.memberCount, 2)
        XCTAssertEqual(hour.wetCount, 2)
        XCTAssertEqual(hour.fraction, 1.0, accuracy: 1e-12)
        XCTAssertEqual(evidence.memberCount, 3, "成员数仍按 3（含缺测成员）")
    }

    // MARK: - 成员数随数据（不硬编码 30）

    func testMemberCountFollowsData() throws {
        let one = makeForecast(hourMajor: [[0.0]])
        XCTAssertEqual(EnsembleProbabilityEngine.evidence(for: one)?.memberCount, 1)

        let many = makeForecast(hourMajor: [Array(repeating: 0.5, count: 50)])
        XCTAssertEqual(EnsembleProbabilityEngine.evidence(for: many)?.memberCount, 50)
    }

    func testSingleMemberFractionIsZeroOrOne() throws {
        let dry = makeForecast(hourMajor: [[0.0]])
        XCTAssertEqual(EnsembleProbabilityEngine.evidence(for: dry)?.hourly.first?.fraction ?? -1,
                       0.0, accuracy: 1e-12)

        let wet = makeForecast(hourMajor: [[0.9]])
        XCTAssertEqual(EnsembleProbabilityEngine.evidence(for: wet)?.hourly.first?.fraction ?? -1,
                       1.0, accuracy: 1e-12)
    }

    // MARK: - 窗口聚合「任一小时」

    func testWindowAggregateCountsAnyHour() throws {
        // 成员 0 仅最后一小时有雨，成员 1 全程无雨 → wetMemberCount = 1。
        let forecast = makeForecast(hourMajor: [
            [0.0, 0.0],
            [0.0, 0.0],
            [0.3, 0.0]
        ])
        let evidence = try XCTUnwrap(EnsembleProbabilityEngine.evidence(for: forecast))
        XCTAssertEqual(evidence.memberCount, 2)
        XCTAssertEqual(evidence.wetMemberCount, 1, "仅在窗口末段有雨也算「认为有雨」")
    }

    // MARK: - 边界：无可用集合

    func testEmptyForecastYieldsNilEvidence() {
        XCTAssertNil(EnsembleProbabilityEngine.evidence(for: .empty))
    }

    func testNoMembersYieldsNilEvidence() {
        let noMembers = EnsembleForecast(times: [anchor], memberSeries: [], utcOffsetSeconds: 0)
        XCTAssertNil(EnsembleProbabilityEngine.evidence(for: noMembers))
    }
}

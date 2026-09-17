//
//  WidgetCopyTests.swift
//  ZhishengWeatherTests
//
//  ARCH §13 七态文案表 —— 逐格断言，保证「诚实 + 可操作」不靠人工盯视图。
//
//  为什么必须测：旧实现让四个视图各自 `==` 拼状态句（四处真源）；
//  本轮把它们收进 `WidgetCopy`，本文件就是那份**唯一真源**的锁定网
//  （视图侧再也拼不出第二套句子）。
//

import XCTest
@testable import ZhishengWeather

final class WidgetCopyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static let beijing = City.beijingDefault

    /// 造一份载荷（weatherCode = 2 → 「多云」级）。
    private func payload(updatedAt: Date) -> SharedWeatherPayload {
        let snapshot = WeatherSnapshot(location: Self.beijing.locationInfo,
                                       temperature: 23, apparentTemperature: 22,
                                       weatherCode: 2, windSpeed: 3, windDirection: 90,
                                       humidity: 50, isDay: true, hourly: [],
                                       dailyHigh: 25, dailyLow: 15,
                                       fetchedAt: updatedAt)
        return SharedWeatherPayload(snapshot: snapshot, updatedAt: updatedAt,
                                    timeZoneIdentifier: "Asia/Shanghai")
    }

    /// 空态收敛值（无城市 / 无载荷 / 指定空因）。
    private func empty(_ reason: WidgetEmptyReason,
                       status: WidgetPayloadStatus,
                       city: City? = nil) -> WidgetEntryResolution {
        WidgetEntryResolution(city: city, payload: nil, status: status,
                              dataSource: .none, emptyReason: reason)
    }

    // MARK: - 正常 / 过旧（有数据）

    func testAvailableRowUsesWMODescriptionAndPlainUpdateTime() {
        let resolution = WidgetEntryResolution(city: Self.beijing,
                                              payload: payload(updatedAt: now),
                                              status: .available,
                                              dataSource: .sharedContainer,
                                              emptyReason: nil)

        XCTAssertEqual(WidgetCopy.conditionText(resolution: resolution),
                       WMOCodeMapper.description(for: 2),
                       "有数据时现象位复用既有 WMO 映射（不新增第二套映射）")
        XCTAssertEqual(WidgetCopy.updateText(resolution: resolution, timeText: "14:05"),
                       "更新于 14:05")
        XCTAssertNil(WidgetCopy.hintText(resolution: resolution), "有数据 → 无提示行")
        XCTAssertEqual(WidgetCopy.cityText(resolution: resolution), "北京")
    }

    func testStaleRowAppendsExpiredMarker() {
        let resolution = WidgetEntryResolution(city: Self.beijing,
                                              payload: payload(updatedAt: now),
                                              status: .stale,
                                              dataSource: .sharedContainer,
                                              emptyReason: nil)

        XCTAssertEqual(WidgetCopy.updateText(resolution: resolution, timeText: "14:05"),
                       "更新于 14:05 · 已过期",
                       "过旧仍展示数据，只追加标注（§13 表）")
        XCTAssertNil(WidgetCopy.hintText(resolution: resolution))
    }

    // MARK: - 七态表逐行

    func testNoCityRowGuidesUserToConfigureCity() {
        let resolution = empty(.noCity, status: .missing)

        XCTAssertEqual(WidgetCopy.conditionText(resolution: resolution), "暂无数据")
        XCTAssertEqual(WidgetCopy.updateText(resolution: resolution, timeText: nil), "暂无数据")
        XCTAssertEqual(WidgetCopy.hintText(resolution: resolution), "点按小部件，选择要显示的城市",
                       "无城市必须给出**可操作**提示（幽灵北京的诚实替代）")
        XCTAssertNil(WidgetCopy.cityText(resolution: resolution), "无城市名可显示")
    }

    func testNoCachedDataRowPointsToMainApp() {
        let resolution = empty(.noCachedData, status: .missing, city: Self.beijing)

        XCTAssertEqual(WidgetCopy.conditionText(resolution: resolution), "暂无数据")
        XCTAssertEqual(WidgetCopy.updateText(resolution: resolution, timeText: nil), "暂无数据")
        XCTAssertEqual(WidgetCopy.hintText(resolution: resolution), "打开主 App 取数后自动显示")
        XCTAssertEqual(WidgetCopy.cityText(resolution: resolution), "北京", "城市名仍显示（不丢标题）")
    }

    func testSharedContainerDownRowIsHonestAndActionable() {
        let resolution = empty(.sharedContainerDown, status: .unavailable, city: Self.beijing)

        XCTAssertEqual(WidgetCopy.conditionText(resolution: resolution), "共享数据不可用")
        XCTAssertEqual(WidgetCopy.updateText(resolution: resolution, timeText: nil), "共享数据不可用")
        XCTAssertEqual(WidgetCopy.hintText(resolution: resolution), "请在主 App 中打开一次天气")
    }

    func testFetchFailedRowAsksUserToCheckNetwork() {
        let resolution = empty(.fetchFailed, status: .unavailable, city: Self.beijing)

        XCTAssertEqual(WidgetCopy.conditionText(resolution: resolution), "未能获取天气",
                       "自力取数失败与「共享数据不可用」必须区分（处置不同）")
        XCTAssertEqual(WidgetCopy.updateText(resolution: resolution, timeText: nil), "未能获取天气")
        XCTAssertEqual(WidgetCopy.hintText(resolution: resolution), "请检查网络后重试")
    }

    func testCityHasNoDataRowSuggestsAnotherCityAndOmitsTimeText() {
        let resolution = empty(.cityHasNoData, status: .missing, city: Self.beijing)

        XCTAssertEqual(WidgetCopy.conditionText(resolution: resolution), "该城市暂无天气数据")
        XCTAssertEqual(WidgetCopy.updateText(resolution: resolution, timeText: nil), "",
                       "§13 表该行时间位为「—」：返回空串由视图不渲染")
        XCTAssertEqual(WidgetCopy.hintText(resolution: resolution), "换一个城市试试")
    }

    // MARK: - 兜底 / 穷尽（对任意输入不崩、现象位不返回空串）

    func testEveryEmptyReasonYieldsNonEmptyConditionAndHintText() {
        let rows: [(WidgetEmptyReason, WidgetPayloadStatus)] = [
            (.noCity, .missing),
            (.noCachedData, .missing),
            (.sharedContainerDown, .unavailable),
            (.fetchFailed, .unavailable),
            (.cityHasNoData, .missing),
        ]

        for (reason, status) in rows {
            let resolution = empty(reason, status: status, city: Self.beijing)
            XCTAssertFalse(WidgetCopy.conditionText(resolution: resolution).isEmpty,
                           "\(reason) 的现象位不得为空串")
            XCTAssertNotNil(WidgetCopy.hintText(resolution: resolution),
                            "\(reason) 必须给出可操作提示")
        }
    }

    /// 有载荷但状态异常的组合（不可达）也必须给出**非空**现象位（兜底不崩）。
    func testPayloadPresentNeverYieldsEmptyConditionText() {
        let resolution = WidgetEntryResolution(city: Self.beijing,
                                              payload: payload(updatedAt: now),
                                              status: .unavailable,
                                              dataSource: .none,
                                              emptyReason: nil)

        XCTAssertFalse(WidgetCopy.conditionText(resolution: resolution).isEmpty,
                       "有载荷 → 一律走 WMO 映射，恒非空")
    }

    /// 空态时 `updateText` 复述状态句（除 cityHasNoData）；有载荷时用调用方给的时刻。
    func testUpdateTextFallsBackToConditionTextWhenNoTimeIsAvailable() {
        let noCity = empty(.noCity, status: .missing)
        XCTAssertEqual(WidgetCopy.updateText(resolution: noCity, timeText: nil),
                       WidgetCopy.conditionText(resolution: noCity),
                       "无载荷 → 时间位复述状态句（§13 表）")

        let withPayload = WidgetEntryResolution(city: Self.beijing,
                                                payload: payload(updatedAt: now),
                                                status: .available,
                                                dataSource: .selfFetched,
                                                emptyReason: nil)
        XCTAssertEqual(WidgetCopy.updateText(resolution: withPayload, timeText: "09:07"),
                       "更新于 09:07",
                       "自力取数的载荷与容器载荷共用同一套措辞（不额外标注来源）")
    }

    /// cityText 的预览回退路径（无城市但有载荷 → 回退快照 location.name）。
    func testCityTextFallsBackToPayloadLocationName() {
        let preview = WidgetEntryResolution(city: nil,
                                           payload: payload(updatedAt: now),
                                           status: .available,
                                           dataSource: .none,
                                           emptyReason: nil)

        XCTAssertNil(preview.city)
        XCTAssertEqual(WidgetCopy.cityText(resolution: preview), "北京",
                       "画廊预览路径回退快照的 location.name（既有行为不变）")
    }
}

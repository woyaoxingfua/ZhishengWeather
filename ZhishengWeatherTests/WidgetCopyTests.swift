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
//  ⚠️ 除「与 §13 表逐字一致」外，本文件还锁一条**硬规则**（见 `WidgetCopy` 文件头）：
//     提示行不得要求用户做一个**在当前分发渠道上无法改变该状态**的动作。
//     本产品的渠道是**未签名侧载** → App Group 容器永不可用 → 所有「去开主 App」类的
//     建议都不可能生效。故本文件有一条**回归防线**：断言所有提示行都不含「App」字样
//     （`testNoWidgetCopyRowEverAsksUserToOpenTheMainApp`）—— 任何人把「去开 App」写回来，
//     CI 立刻红。
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

    func testNoCityRowGuidesUserToEditTheWidgetAndPickCity() {
        let resolution = empty(.noCity, status: .missing)

        XCTAssertEqual(WidgetCopy.conditionText(resolution: resolution), "暂无数据")
        XCTAssertEqual(WidgetCopy.updateText(resolution: resolution, timeText: nil), "暂无数据")
        XCTAssertEqual(WidgetCopy.hintText(resolution: resolution), "长按小组件 → 编辑，选择城市",
                       "无城市必须给出**真正能改变该状态**的动作：侧载上「编辑→选城市」"
                       + "是唯一绕开容器的路径（硬规则；「点按」只开主 App，改不了本态）")
        XCTAssertNil(WidgetCopy.cityText(resolution: resolution), "无城市名可显示")
    }

    /// 快照路径无缓存：城市已知、只是这一路不联网 → 该态**会自愈**，不得索取用户动作。
    ///
    /// 回归防线：原文案「打开主 App 取数后自动显示」在未签名侧载上**不可能生效**
    /// （主 App 与小组件是两个容器），故已按硬规则改掉。
    func testNoCachedDataRowRequiresNoUserAction() {
        let resolution = empty(.noCachedData, status: .missing, city: Self.beijing)

        XCTAssertEqual(WidgetCopy.conditionText(resolution: resolution), "暂无数据")
        XCTAssertEqual(WidgetCopy.updateText(resolution: resolution, timeText: nil), "暂无数据")
        XCTAssertEqual(WidgetCopy.hintText(resolution: resolution), "稍候将自动获取",
                       "该态只出现在 snapshot（allowNetwork=false），随后 timeline 的 L1 自会取回"
                       + "→ 提示只能是「会自愈」，不能要求用户去开主 App")
        XCTAssertEqual(WidgetCopy.cityText(resolution: resolution), "北京", "城市名仍显示（不丢标题）")
    }

    /// 容器不可用（快照）：**前置条件是城市已解析**（无城市走 `.noCity`）→ 让用户「再选城市」
    /// 是他刚做过的事，属错的建议；该态同样会自愈。
    func testSharedContainerDownRowIsHonestAndRequiresNoUserAction() {
        let resolution = empty(.sharedContainerDown, status: .unavailable, city: Self.beijing)

        XCTAssertEqual(WidgetCopy.conditionText(resolution: resolution), "共享数据不可用")
        XCTAssertEqual(WidgetCopy.updateText(resolution: resolution, timeText: nil), "共享数据不可用")
        XCTAssertEqual(WidgetCopy.hintText(resolution: resolution), "稍候将自动获取",
                       "容器不可用不影响 timeline 的 L1 自力取数；且城市已解析 → 不应再要求选城市")
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

    // MARK: - 硬规则：提示行不得要求用户做「侧载上无法改变该状态」的动作

    /// 把硬规则锁进 CI 的最强一条防线：未签名侧载上 App Group 容器永不可用，故**任何**
    /// 要求用户「去开主 App / 等主 App 写数据」的措辞都不可能生效
    /// （主 App 写的是它自己的隔离容器，小组件永远读不到）。
    /// 故提示行 / 现象位 / 时间位一律**不得**出现「App」字样（大小写都拦）。
    func testNoWidgetCopyRowEverAsksUserToOpenTheMainApp() {
        let rows: [(WidgetEmptyReason, WidgetPayloadStatus)] = [
            (.noCity, .missing),
            (.noCachedData, .missing),
            (.sharedContainerDown, .unavailable),
            (.fetchFailed, .unavailable),
            (.cityHasNoData, .missing),
        ]

        for (reason, status) in rows {
            let resolution = empty(reason, status: status, city: Self.beijing)
            let cells: [(String, String)] = [
                ("hintText", WidgetCopy.hintText(resolution: resolution) ?? ""),
                ("conditionText", WidgetCopy.conditionText(resolution: resolution)),
                ("updateText", WidgetCopy.updateText(resolution: resolution, timeText: nil)),
            ]
            for (label, text) in cells {
                XCTAssertFalse(text.contains("App"),
                               "\(reason) 的 \(label) 出现「App」：侧载上「去开主 App」"
                               + "不可能改变小组件状态（硬规则见 WidgetCopy 文件头）")
                XCTAssertFalse(text.contains("app"),
                               "\(reason) 的 \(label) 出现「app」：同上（大小写都拦）")
            }
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

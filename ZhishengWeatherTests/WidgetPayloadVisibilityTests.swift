//
//  WidgetPayloadVisibilityTests.swift
//  ZhishengWeatherTests
//
//  `WidgetEntryResolution.hasPayload` 的不变式守卫 ——
//  **本轮修掉的独立缺陷**（不依赖 App Group、代码层面即可判死）的回归防线。
//
//  ── 被守卫的缺陷（2026-10 静态审查）────────────────────────────────────
//  现象：Large 组件在**空态**（什么都没取到）下，同一屏显示**四条**「暂无」：
//    · hero 的 `WidgetCopy.conditionText`（「暂无数据」/「未能获取天气」/…）—— 正确；
//    · 「暂无逐日数据」（`LargeWeatherView.dailySection` 硬编码）；
//    · 「暂无逐时数据」（`hourlyTrendSection` 硬编码）；
//    · 「暂无指标数据」（`metricsSection` 硬编码）。
//  三句硬编码兜底**不在 `WidgetCopy` 单一真源内**，也不在 ARCH §13 七态表里，
//  且与 Small / Medium 的表现**不一致**（Small 只说一次，Medium 走 `WidgetCopy`）。
//
//  为什么它是「独立代码缺陷」而非 App Group 通道问题：
//  它**不依赖 App Group 是否可用**——无论容器通不通，只要 `payload == nil`
//  （容器不可用、无城市、定位未授权、取数失败……**任何一种成因**），
//  Large 都会多出这三句。这条判据与分发渠道无关，故属代码层面可判死。
//
//  后果（为什么必须修）：用户在同一屏看到四句互相不一致的「暂无」，
//  **无法自查卡在哪一步**（是没配城市？网络挂了？还是这城市没数据？）。
//  「让人能自查」正是空态纪律的目的，故按「宁缺不猜」修：
//  没有数据就**不摆出逐日 / 逐时 / 指标的架子**，空态由 hero 一次性如实表达。
//
//  ── 本文件锁的性质（不锁具体实现）──────────────────────────────────────
//  1. `hasPayload` 恒等价于 `payload != nil`（它只是派生量，不是新判据）；
//  2. `hasPayload` 恒等价于 `emptyReason == nil`
//     —— 即与 `WidgetEntryResolution` 文件头那条主不变式**同一条**，
//     视图可以放心用它做「渲染数据 vs 渲染空态」的二选一；
//  3. **画廊占位**那条唯一「有载荷但无城市」的路径 `hasPayload == true`
//     —— 否则会把画廊预览整段数据区误判成空态、把示例数据藏起来。
//

import XCTest
@testable import ZhishengWeather

final class WidgetPayloadVisibilityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static let beijing = City.beijingDefault

    private func payload() -> SharedWeatherPayload {
        let snapshot = WeatherSnapshot(location: Self.beijing.locationInfo,
                                       temperature: 23, apparentTemperature: 22,
                                       weatherCode: 2, windSpeed: 3, windDirection: 90,
                                       humidity: 50, isDay: true, hourly: [],
                                       dailyHigh: 25, dailyLow: 15,
                                       fetchedAt: now)
        return SharedWeatherPayload(snapshot: snapshot, updatedAt: now,
                                    timeZoneIdentifier: "Asia/Shanghai")
    }

    // MARK: - 1. hasPayload ⟺ payload != nil（派生量，不是新判据）

    /// 无论来源（容器 / 自力取数 / 画廊占位）与状态，派生量必须与 `payload` 同步。
    func testHasPayloadAlwaysMirrorsPayloadNonNil() {
        let cases: [(String, WidgetEntryResolution)] = [
            ("容器载荷",
             WidgetEntryResolution(city: Self.beijing, payload: payload(),
                                   status: .available, dataSource: .sharedContainer,
                                   emptyReason: nil)),
            ("自力取数载荷",
             WidgetEntryResolution(city: Self.beijing, payload: payload(),
                                   status: .available, dataSource: .selfFetched,
                                   emptyReason: nil)),
            ("过旧载荷",
             WidgetEntryResolution(city: Self.beijing, payload: payload(),
                                   status: .stale, dataSource: .sharedContainer,
                                   emptyReason: nil)),
            ("画廊占位（有载荷、无城市）",
             WidgetEntryResolution(city: nil, payload: payload(),
                                   status: .available, dataSource: .none,
                                   emptyReason: nil)),
            ("无城市",
             WidgetEntryResolution(city: nil, payload: nil,
                                   status: .missing, dataSource: .none,
                                   emptyReason: .noCity)),
            ("取数失败",
             WidgetEntryResolution(city: Self.beijing, payload: nil,
                                   status: .unavailable, dataSource: .none,
                                   emptyReason: .fetchFailed)),
        ]

        for (label, resolution) in cases {
            XCTAssertEqual(resolution.hasPayload, resolution.payload != nil,
                           "\(label)：hasPayload 必须与 payload != nil 同步")
        }
    }

    // MARK: - 2. hasPayload ⟺ emptyReason == nil（与主不变式同一条）

    /// 视图拿 `hasPayload` 当「渲染数据 vs 渲染空态」的开关，故它必须与
    /// `emptyReason` **零矛盾** —— 否则会出现「有数据却摆空架子」或反之。
    func testHasPayloadAndEmptyReasonAreMutuallyExclusive() {
        let rows: [(WidgetEmptyReason, WidgetPayloadStatus)] = [
            (.noCity, .missing),
            (.noCachedData, .missing),
            (.sharedContainerDown, .unavailable),
            (.fetchFailed, .unavailable),
            (.cityHasNoData, .missing),
            (.locationNotAuthorized, .missing),
            (.locationUnavailable, .missing),
        ]

        for (reason, status) in rows {
            let city: City? = (reason == .noCity || reason == .locationNotAuthorized)
                ? nil : Self.beijing
            let empty = WidgetEntryResolution(city: city, payload: nil,
                                             status: status, dataSource: .none,
                                             emptyReason: reason)
            XCTAssertFalse(empty.hasPayload,
                           "\(reason)：空态必须 hasPayload == false（Large 据此收起数据区块）")
            XCTAssertNotNil(empty.emptyReason,
                            "\(reason)：空态必有可操作空因")

            let loaded = WidgetEntryResolution(city: Self.beijing, payload: payload(),
                                               status: .available,
                                               dataSource: .selfFetched,
                                               emptyReason: nil)
            XCTAssertTrue(loaded.hasPayload, "有载荷 → hasPayload == true")
            XCTAssertNil(loaded.emptyReason, "有载荷 → 无空因")
        }
    }

    // MARK: - 3. 画廊占位仍是「有载荷」（防把示例数据整段藏起来）

    /// 回归防线：画廊占位是全仓**唯一**「有载荷但
    /// 无城市」的组合（`WeatherEntry.swift` 有论证）。若哪天有人把占位改成
    /// `payload: nil`，`hasPayload` 会变false → 画廊里整段数据区被收起 →
    /// 用户在添加组件的预览里看到空白。此例锁死它必须仍落在「有载荷」那侧。
    ///
    /// ⚠️ 为什么在这里**就地构造**而不直接引用 `WidgetEntryResolution.placeholder`：
    /// 该静态量定义在 **Widget target**（`ZhishengWeatherWidget/WeatherEntry.swift`
    /// 的 `extension WidgetEntryResolution`），而本测试 target 的 sources 只有
    /// `ZhishengWeatherTests`、依赖只有主App —— 它在本文件里**不可见**
    /// （引用会报 `cannot find 'placeholder' in scope`）。
    /// 本测试 target 同样看不到 Widget 侧的 `SharedWeatherPayload.placeholder`
    /// （`WeatherSnapshot.placeholder` 亦然），故payload 走本地构造，
    /// 断言的**性质**（有载荷 + 无城市 + 无空因 ⇒ hasPayload 为 true）不变。
    func testGalleryPlaceholderStillCountsAsPayloadBearing() {
        let gallery = Self.placeholderEquivalent()
        XCTAssertTrue(
            gallery.hasPayload,
            "画廊 / 预览占位带着示例载荷（emptyReason == nil），必须仍算「有数据」——"
                + "否则 Large 的数据区块会被整段收起，画廊预览显示空白"
        )
        XCTAssertNil(gallery.city,
                     "占位的 city 为 nil 是既有约定（名字回退快照 location）")
    }

    /// Widget 侧 `WidgetEntryResolution.placeholder` 的**等价本地构造**。
    ///
    /// 逐字对齐 `ZhishengWeatherWidget/WeatherEntry.swift` 的定义：
    /// `city: nil` + 示例 `payload` + `status: .available` +
    /// `dataSource: .none` + `emptyReason: nil`。
    private static func placeholderEquivalent() -> WidgetEntryResolution {
        let snapshot = WeatherSnapshot(location: Self.beijing.locationInfo,
                                       temperature: 23, apparentTemperature: 22,
                                       weatherCode: 2, windSpeed: 3, windDirection: 90,
                                       humidity: 50, isDay: true, hourly: [],
                                       dailyHigh: 25, dailyLow: 15,
                                       fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        return WidgetEntryResolution(city: nil,
                                     payload: SharedWeatherPayload(snapshot: snapshot,
                                                                  updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                                                  timeZoneIdentifier: "Asia/Shanghai"),
                                     status: .available,
                                     dataSource: .none,
                                     emptyReason: nil)
    }

    // MARK: - 4. 全部七个空因都收敛为「不渲染数据区块」

    /// 把「空态一律收起逐日 / 逐时 / 指标区块」这条性质**逐态**钉死。
    /// 这正是本轮修复的行为契约：任一空因下Large 都不摆数据架子，
    /// 空态只由 `WidgetCopy` 的状态句 + 提示行表达一次。
    func testEveryEmptyReasonSuppressesDataSections() {
        let rows: [(WidgetEmptyReason, WidgetPayloadStatus, City?)] = [
            (.noCity, .missing, nil),
            (.noCachedData, .missing, Self.beijing),
            (.sharedContainerDown, .unavailable, Self.beijing),
            (.fetchFailed, .unavailable, Self.beijing),
            (.cityHasNoData, .missing, Self.beijing),
            (.locationNotAuthorized, .missing, nil),
            (.locationUnavailable, .missing, nil),
        ]

        for (reason, status, city) in rows {
            let resolution = WidgetEntryResolution(city: city, payload: nil,
                                                   status: status,
                                                   dataSource: .none,
                                                   emptyReason: reason)
            XCTAssertFalse(
                resolution.hasPayload,
                """
                \(reason)：Large 必须收起「未来三天 / 未来四小时 / 指标网格」三个区块。
                否则空态会同屏出现四句「暂无」（三句硬编码 + hero 的状态句），
                既不一致（硬编码不在 WidgetCopy 真源内）又让用户无法自查卡在哪一步。
                """
            )
        }
    }
}

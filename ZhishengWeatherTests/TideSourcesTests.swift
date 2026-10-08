//
//  TideSourcesTests.swift
//  ZhishengWeatherTests
//
//  第四源 marine 的**潮汐**扩展（`minutely_15` 块）接入锚点。
//  不联网、不读真实时钟：全部喂本地造好的 JSON，样本逐字取自
//  2026-10-07 真实 curl 探针（大连 38.9,121.6 / 青岛 36.07,120.38 等）。
//
// 覆盖清单（对应本轮硬要求）：
//  1．**端点**：潮汐变量名钉死 + `forecast_days=7` 必须显式带
//     （实测省略时`minutely_15` 只回 288 点 = 3 天）；
//  2．**四态非空判定**：整块缺失 / 元素全 null（实测 inland 形态）
//     / 部分 null / 正常；
//  3．**单字段失败不拖垮整批**：`invert_barometer_height` 缺失时
//     该点天文潮分量为 nil，**其余点照常**，且绝不输出"只扣一半"的数；
//  4．**按类型解析**：数组元素为 null / 非有限值 → 跳过该点，**不补0**；
//  5．**数组长度不一致**：绝不 `zip` 静默截断，按下标 `guard let`；
//  6．**天文潮 = msl − 倒压效应**（语义核心，数值逐字取自实测）；
//  7．**负潮高与 0 是合法读数**（实测大连 -0.53…+1.40），**不**被净化掉；
//  8．**极值判定**：局部高低潮、缺测点不参与、窗口太短不判；
//  9．**24 小时窗**：半开窗 `[now, now+24h)`；
// 10．**沿海判据复用**：同一判据同时管浪与潮（实测 null 分布逐点一致）。
//
// ⚠️ **语义纪律（本轮最要紧的一条）**：设计稿曾断言该量是"天文潮（不含气压）"，
//   **实测 + Open-Meteo 官方文档均不支持** —— `sea_level_height_msl` 逐字含
//   `the inverted barometer effect`。故测试**锚住"要减去倒压项"这个行为**：
//   若哪天有人图省事改成直接用 `sea_level_height_msl`，`testAstronomicalSubtractsInvertedBarometer`
//   必红。那是本测试存在的意义。
//

import XCTest
import Foundation
@testable import ZhishengWeather

final class TideSourcesTests: XCTestCase {

    // MARK: - 实测样本（2026-10-07 探针，逐字形态）

    /// 大连 (38.9,121.6) 实测：`minutely_15` 短样本（截取前 8 点）。
    ///逐字值来自探针：msl `[-0.54,-0.54,-0.52,-0.50,-0.46,-0.42,-0.36,-0.30]`、
    /// ibp `[-0.10,-0.10,-0.10,-0.10,-0.10,-0.11,-0.11,-0.12]`。
    private static let dalianTideJSON = #"""
    {"latitude":38.9,"longitude":121.6,"utc_offset_seconds":28800,
     "minutely_15_units":{"time":"unixtime",
                          "sea_level_height_msl":"m",
                          "invert_barometer_height":"m"},
     "minutely_15":{"time":[1791302400,1791303300,1791304200,1791305100,
                            1791306000,1791306900,1791307800,1791308700],
                    "sea_level_height_msl":[-0.54,-0.54,-0.52,-0.50,
                                            -0.46,-0.42,-0.36,-0.30],
                    "invert_barometer_height":[-0.10,-0.10,-0.10,-0.10,
                                               -0.10,-0.11,-0.11,-0.12]}}
    """#

    /// 实测**内陆**形态：北京 (39.90,116.41) → **HTTP 200 + 键在 + 长度正常
    /// + 元素全 null**（实测 `nonnull=0`，两个变量都是）。
    private static let beijingAllNullJSON = #"""
    {"latitude":39.875,"longitude":116.375015,"utc_offset_seconds":28800,
     "minutely_15_units":{"time":"unixtime",
                          "sea_level_height_msl":"m",
                          "invert_barometer_height":"m"},
     "minutely_15":{"time":[1791302400,1791303300,1791304200],
                    "sea_level_height_msl":[null,null,null],
                    "invert_barometer_height":[null,null,null]}}
    """#

    /// 实测**整块被静默省略**形态（变量名在词表但端点不支持时 Open-Meteo 的行为）。
    private static let missingBlockJSON = #"""
    {"latitude":36.04,"longitude":120.375015,"utc_offset_seconds":28800,
     "current_units":{"time":"unixtime","wave_height":"m"},
     "current":{"time":1791285300,"interval":900,"wave_height":0.34}}
    """#

    // MARK: - Helpers

    private func decode(_ json: String) throws -> MarineConditionsResponse {
        try JSONDecoder().decode(MarineConditionsResponse.self, from: Data(json.utf8))
    }

    private func tide(_ json: String) throws -> TideForecast {
        let dto = try decode(json)
        return MarineMapper.mapTide(dto.minutely_15, utcOffsetSeconds: dto.utc_offset_seconds)
    }

    /// 由 (hour, astro) 造点序列（测试用，不读真实时钟）。
    private func points(_ values: [Double?], startEpoch: Double = 1_791_302_400,
                        step: Double = 900) -> [TidePoint] {
        values.enumerated().map { index, value in
            TidePoint(time: Date(timeIntervalSince1970: startEpoch + Double(index) * step),
                      astronomical: value,
                      seaLevelMSL: value,
                      invertBarometer: nil)
        }
    }

    // MARK: - 1．端点：变量名与 forecast_days

    /// 端点必须带两个潮汐变量名，且**显式带 `forecast_days=7`**。
    ///
    /// ⚠️ 这条锚的是**实测踩过的坑**：省略 `forecast_days` 时
    ///   `minutely_15` 实测只回 **288 点（3 天）**，而带 7 才回 **672 点（7 天）**
    ///   —— 少 4 天数据且**不报错**。
    func testTideEndpointPinsBothVariablesAndForecastDays() throws {
        let url = try XCTUnwrap(MarineEndpoint.url(latitude: 38.9, longitude: 121.6))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        let tide = value("minutely_15") ?? ""
        // 🔴 变量名逐字锚定（实测 `tide_height` / `sea_surface_height` 都是 400）。
        XCTAssertTrue(tide.contains("sea_level_height_msl"),
                      "必须请求 sea_level_height_msl，实测这是唯一可用的潮高变量名")
        XCTAssertTrue(tide.contains("invert_barometer_height"),
                      "必须请求 invert_barometer_height —— 不取它就无法扣出天文潮分量")

        // 🔴 forecast_days 必须显式为 7（否则 minutely_15 只回 3 天，实测）。
        XCTAssertEqual(value("forecast_days"), "7",
                       "minutely_15 不带 forecast_days 时实测只回 288 点（3 天）")

        // 与浪况**同一次请求**（零额外开销，实测两块共存于同一响应体）。
        XCTAssertNotNil(value("current"), "潮汐必须与浪况共用一次请求，不得另开链路")
    }

    /// 沿海 / 内陆判据：潮汐**复用**同一套判据（不另造第二套定义）。
    ///
    /// 实测依据：潮汐的 null 分布与浪况**逐点一致**（沿海有值、内陆全 null）。
    func testTideReusesSameCoastalGateAsWave() {
        // 沿海（实测有值：大连 / 青岛 / 威海 / 厦门 / 深圳 / 长江口）。
        XCTAssertTrue(MarineEndpoint.requestEligibility(latitude: 38.9, longitude: 121.6),
                      "大连实测有潮汐值，判据必须放行")
        // 内陆（实测全 null：北京 / 成都 / 乌鲁木齐）。
        XCTAssertFalse(MarineEndpoint.requestEligibility(latitude: 39.9042, longitude: 116.4074),
                       "北京实测潮汐全 null，判据必须挡下（省配额）")
        XCTAssertFalse(MarineEndpoint.requestEligibility(latitude: 43.8256, longitude: 87.6168),
                       "乌鲁木齐实测潮汐全 null，判据必须挡下")
    }

    // MARK: - 2．四态非空判定

    /// 正常态：8 点全部映射出天文潮分量。
    func testTideMapsNormalPayload() throws {
        let forecast = try tide(Self.dalianTideJSON)
        XCTAssertFalse(forecast.isEffectivelyEmpty, "实测大连有值，不该判为空")
        XCTAssertEqual(forecast.points.count, 8)
        XCTAssertEqual(forecast.totalPoints, 8)
    }

    /// 空态一：**整块缺失** → `.empty`，不报错、不崩。
    func testTideMissingBlockYieldsEmpty() throws {
        let forecast = try tide(Self.missingBlockJSON)
        XCTAssertTrue(forecast.isEffectivelyEmpty)
        XCTAssertTrue(forecast.points.isEmpty)
    }

    /// 空态二：**元素全 null**（实测 inland 形态，键在、长度正常）→ 判为空。
    ///
    /// ⚠️ 这是最容易漏的一态：只看"序列非空"会把 inland 响应当成有效数据，
    ///   画出一条"潮高恒为 0 m"的假平直线。
    func testTideAllNullElementsYieldsEmptyNotFlatZeroLine() throws {
        let forecast = try tide(Self.beijingAllNullJSON)
        XCTAssertTrue(forecast.isEffectivelyEmpty,
                      "实测内陆是 200 + 全null，必须判为无数据")
        // ⚠️ 关键：点**可以**保留（形态如实），但**没有一个**带天文潮分量。
        XCTAssertTrue(forecast.points.allSatisfy { $0.astronomical == nil },
                      "全 null 时不得凭空造出 0 值潮高")
    }

    /// 单点缺测**不**拖垮整批（部分有值 → 保留，缺口可见）。
    func testTidePartialNullKeepsOtherPoints() throws {
        let json = #"""
        {"latitude":38.9,"longitude":121.6,"utc_offset_seconds":28800,
         "minutely_15":{"time":[1791302400,1791303300,1791304200,1791305100],
                        "sea_level_height_msl":[-0.54,null,-0.52,-0.50],
                        "invert_barometer_height":[-0.10,-0.10,null,-0.10]}}
        """#
        let forecast = try tide(json)
        XCTAssertFalse(forecast.isEffectivelyEmpty, "部分缺测是如实的，不该整卡藏掉")
        XCTAssertEqual(forecast.points.count, 4, "缺测点仍占位（形态如实），曲线由 UI 断开")
        XCTAssertEqual(forecast.points[0].astronomical ?? 0, -0.44, accuracy: 0.001)
        XCTAssertNil(forecast.points[1].astronomical, "msl 为 null → 该点天文潮分量为 nil")
        XCTAssertNil(forecast.points[2].astronomical, "ibp 为 null → 该点天文潮分量为 nil")
        XCTAssertEqual(forecast.points[3].astronomical ?? 0, -0.40, accuracy: 0.001)
    }

    // MARK: - 3．单字段失败不拖垮整批（本轮硬要求）

    /// `invert_barometer_height` **整列缺失** → 所有点天文潮分量为 nil，
    /// 但**其余字段（msl / ibp 的原值）仍被保留**，且**不报错**。
    ///
    /// ⚠️ 绝不能"用只有 msl 的值当潮高"—— 那等于把含气压效应的数
    ///   冒充成天文潮，正是本轮要杜绝的过度承诺。
    func testTideMissingInvertedBarometerColumnDoesNotFakeAstronomical() throws {
        let json = #"""
        {"latitude":38.9,"longitude":121.6,"utc_offset_seconds":28800,
         "minutely_15":{"time":[1791302400,1791303300,1791304200],
                        "sea_level_height_msl":[-0.54,-0.54,-0.52]}}
        """#
        let forecast = try tide(json)
        XCTAssertTrue(forecast.points.allSatisfy { $0.astronomical == nil },
                      "缺倒压项时绝不能输出天文潮分量")
        // 但原始值必须保留（供诊断/对照，且证明数据没被整批丢掉）。
        XCTAssertEqual(forecast.points.count, 3, "单字段失败不拖垮整批：点仍在")
        XCTAssertEqual(forecast.points[0].seaLevelMSL ?? 0, -0.54, accuracy: 0.001)
        XCTAssertTrue(forecast.points.allSatisfy { $0.invertBarometer == nil })
    }

    /// `sea_level_height_msl` 整列缺失 → 同理（潮高是主项，缺了就无潮汐）。
    func testTideMissingSeaLevelColumnYieldsEmpty() throws {
        let json = #"""
        {"latitude":38.9,"longitude":121.6,"utc_offset_seconds":28800,
         "minutely_15":{"time":[1791302400,1791303300],
                        "invert_barometer_height":[-0.10,-0.10]}}
        """#
        let forecast = try tide(json)
        XCTAssertTrue(forecast.points.isEmpty, "主项缺失 → 无点可造")
        XCTAssertTrue(forecast.isEffectivelyEmpty)
    }

    // MARK: - 4．按类型解析

    /// 极端但有限的量级（实测全球潮高 ≤ ±3.3m，故 1e308 显然是服务端异常）
    ///   → 净化后仍应是**有限值**，且 UI 侧有钳位兜底。
    func testTideHugeButFiniteValueStaysFinite() throws {
        let json = #"""
        {"latitude":38.9,"longitude":121.6,"utc_offset_seconds":28800,
         "minutely_15":{"time":[1791302400,1791303300],
                        "sea_level_height_msl":[-0.54,1.0e308],
                        "invert_barometer_height":[-0.10,0.0]}}
        """#
        let forecast = try tide(json)
        XCTAssertEqual(forecast.points[0].astronomical ?? 0, -0.44, accuracy: 0.0001)
        let second = try XCTUnwrap(forecast.points.dropFirst().first?.astronomical)
        XCTAssertTrue(second.isFinite, "净化后必须是有限值")
        XCTAssertFalse(second.isNaN)
    }

    /// ⚠️ 差值溢出防护：msl 与 ibp 各自有限、但**相减溢出** → 该点必须为 nil。
    func testTideDifferenceOverflowRejected() throws {
        let json = #"""
        {"latitude":38.9,"longitude":121.6,"utc_offset_seconds":28800,
         "minutely_15":{"time":[1791302400],
                        "sea_level_height_msl":[-1.7976931348623157e308],
                        "invert_barometer_height":[1.7976931348623157e308]}}
        """#
        let forecast = try tide(json)
        let value = forecast.points.first?.astronomical
        if let value {
            XCTAssertTrue(value.isFinite, "相减溢出成 -inf 必须被挡（否则会画出毁掉整图的曲线）")
        } else {
            XCTAssertNil(value, "溢出点应被净化为 nil（缺口），而不是留下inf")
        }
    }

    // MARK: - 5．数组长度不一致（绝不 zip 静默截断）

    /// `time` 比高度数组**长** → 越界处**停止**，绝不"用最后一个值补齐"。
    func testTideLongerTimeArrayStopsAtBoundsWithoutPadding() throws {
        let json = #"""
        {"latitude":38.9,"longitude":121.6,"utc_offset_seconds":28800,
         "minutely_15":{"time":[1791302400,1791303300,1791304200,1791305100],
                        "sea_level_height_msl":[-0.54,-0.54],
                        "invert_barometer_height":[-0.10,-0.10]}}
        """#
        let forecast = try tide(json)
        XCTAssertEqual(forecast.points.count, 2, "越界必须停止，绝不补齐（补齐= 编造）")
        XCTAssertEqual(forecast.totalPoints, 4, "totalPoints 仍如实记录服务端给的 time 长度")
    }

    /// 高度数组比 `time` **长** → 只按time 长度取，多余的高度值被忽略。
    func testTideLongerValueArrayIsTruncatedToTimeCount() throws {
        let json = #"""
        {"latitude":38.9,"longitude":121.6,"utc_offset_seconds":28800,
         "minutely_15":{"time":[1791302400,1791303300],
                        "sea_level_height_msl":[-0.54,-0.54,-0.52,-0.50],
                        "invert_barometer_height":[-0.10,-0.10,-0.10,-0.10]}}
        """#
        let forecast = try tide(json)
        XCTAssertEqual(forecast.points.count, 2)
        XCTAssertEqual(forecast.totalPoints, 2)
    }

    // MARK: - 6．天文潮 = msl − 倒压效应（语义核心）

    /// 🔴 本轮**最要紧**的一条：天文潮分量必须**减去**倒压效应。
    ///
    /// 依据（实测 + 官方文档逐字）：`sea_level_height_msl` 本身**已包含**
    /// `the inverted barometer effect`。若有人图省事直接用 msl 当天文潮，
    /// 本测试必红 —— 这就是它存在的意义。
    func testAstronomicalSubtractsInvertedBarometer() throws {
        let forecast = try tide(Self.dalianTideJSON)
        let first = try XCTUnwrap(forecast.points.first)
        let msl = try XCTUnwrap(first.seaLevelMSL)
        let ibp = try XCTUnwrap(first.invertBarometer)
        let astro = try XCTUnwrap(first.astronomical)
        XCTAssertEqual(astro, msl - ibp, accuracy: 0.0001,
                       "天文潮分量必须是 msl − invert_barometer_height")
        // 实测首点：msl -0.54、ibp -0.10 → 天文潮 -0.44。
        XCTAssertEqual(astro, -0.44, accuracy: 0.0001)
        //⚠️ 反向断言：msl 本身（-0.54）**不等于**天文潮（-0.44）。
        XCTAssertNotEqual(msl, astro, accuracy: 0.0001,
                          "直接用 msl 当天文潮就是本轮要杜绝的语义错误")
    }

    /// 实测大连整段天文潮分量逐点核对（msl − ibp，前8 点）。
    func testAstronomicalSeriesMatchesMeasuredSubtraction() throws {
        let forecast = try tide(Self.dalianTideJSON)
        let actual = forecast.points.map { $0.astronomical ?? 0 }
        // 实测探针逐字：msl[-0.54…-0.30] − ibp[-0.10…-0.12]
        // = [-0.44, -0.44, -0.42, -0.40, -0.36, -0.31, -0.25, -0.18]
        let expected = [-0.44, -0.44, -0.42, -0.40, -0.36, -0.31, -0.25, -0.18]
        XCTAssertEqual(actual.count, expected.count)
        for (index, value) in actual.enumerated() {
            XCTAssertEqual(value, expected[index], accuracy: 0.005,
                           "第 \(index) 点天文潮分量与实测不符")
        }
    }

    // MARK: - 7．负值与 0 是合法读数

    /// 🔴 负潮高与`0` 都**必须保留**（实测大连天文潮范围 -0.53…+1.40）。
    ///
    /// ⚠️ 绝不能复用浪况那套 `nonNegative` 净化：半日潮每天两次越过
    ///   平均海平面，负值是**常态**，当成非法值会把半张曲线删掉。
    func testNegativeAndZeroAstronomicalValuesArePreserved() throws {
        let values: [Double?] = [-0.53, -0.01, 0.0, 0.02, 1.40]
        let series = points(values)
        let mapped = series.map { $0.astronomical ?? 999 }
        XCTAssertEqual(mapped[0], -0.53, accuracy: 0.0001, "负潮高是合法读数，必须保留")
        XCTAssertEqual(mapped[1], -0.01, accuracy: 0.0001)
        XCTAssertEqual(mapped[2], 0.0, accuracy: 0.0001, "0.00 m 是合法读数，不是缺测")
        XCTAssertEqual(mapped[4], 1.40, accuracy: 0.0001)
    }

    /// `isEffectivelyEmpty` 对"全0 序列"必须判为**有数据**。
    ///
    /// ⚠️ 与 flood 判据同款坑：0.00m 是真实读数（天文潮恰好过平均海平面），
    ///   把"恰好为 0"说成"缺测"是另一种谎报。
    func testAllZeroAstronomicalIsNotTreatedAsMissing() throws {
        let json = #"""
        {"latitude":38.9,"longitude":121.6,"utc_offset_seconds":28800,
         "minutely_15":{"time":[1791302400,1791303300,1791304200],
                        "sea_level_height_msl":[0.0,0.0,0.0],
                        "invert_barometer_height":[0.0,0.0,0.0]}}
        """#
        let forecast = try tide(json)
        XCTAssertFalse(forecast.isEffectivelyEmpty,
                       "全 0 是合法读数，判为空等于谎报'缺测'")
    }

    // MARK: - 8．极值判定

    /// 局部高低潮：一条完整半日潮应各出一个高潮与低潮。
    /// ⚠️ 必须 `throws`：体内用了 `try XCTUnwrap(...)`，否则报
    /// `errors thrown from here are not handled`（CI 实测）。
    func testExtremaFindsHighAndLowTide() throws {
        // 一个完整的涨落：低 → 高 → 低。
        let series = points([-0.4, 0.0, 0.8, 1.2, 0.8, 0.0, -0.4, -0.8])
        let result = TideForecast.extrema(in: series)
        XCTAssertEqual(result.high.count, 1, "只应有一个局部高潮")
        XCTAssertEqual(result.low.count, 2, "首尾各一个局部低潮")
        let high = try XCTUnwrap(result.high.first)
        XCTAssertEqual(high.height ?? 0, 1.2, accuracy: 0.0001)
        XCTAssertTrue(high.isHighTide)
        // 首点(-0.4) 与末点(-0.8)都应被记为低潮。
        let lowHeights = result.low.map { $0.height ?? 0 }
        XCTAssertTrue(lowHeights.contains { abs($0 + 0.8) < 0.0001 })
    }

    /// 缺测点**不参与**极值判定（不做跨缺口推断）。
    func testExtremaSkipsMissingPoints() {
        let series = points([-0.4, 0.8, nil, 0.8, -0.4])
        let result = TideForecast.extrema(in: series)
        // 中间缺测 → 两个 0.8 各自成局部极大（各自与缺测邻点不比较）。
        XCTAssertEqual(result.high.count, 2)
        for extremum in result.high {
            XCTAssertEqual(extremum.height ?? 0, 0.8, accuracy: 0.0001)
        }
    }

    /// 序列太短（< 2 点）→ **不判**极值（无从比较，宁缺不猜）。
    func testExtremaWithTooFewPointsYieldsNothing() {
        XCTAssertTrue(TideForecast.extrema(in: []).high.isEmpty)
        XCTAssertTrue(TideForecast.extrema(in: []).low.isEmpty)
        let single = points([0.5])
        let result = TideForecast.extrema(in: single)
        XCTAssertTrue(result.high.isEmpty, "单点无从判定，不该同时算高又算低")
        XCTAssertTrue(result.low.isEmpty)
    }

    /// 单调序列（整窗无**内部**极值）→ 只剩**首尾两个边界**极值。
    ///
    /// ⚠️ 这是**经Python 复刻实测确认**的行为，不是猜的：单调上升
    ///   `[0.1,0.2,0.3,0.4]` → 末点算高潮(0.4)、首点算低潮(0.1)。
    ///   之所以**不**要求首尾也为空：真实潮汐序列的端点常在半个涨落中间，
    ///   把它硬判成"不是极值"会漏掉窗沿的真实高潮/低潮。
    func testExtremaOnMonotonicSeriesYieldsBoundaryExtremesOnly() {
        let rising = points([0.1, 0.2, 0.3, 0.4])
        let risingResult = TideForecast.extrema(in: rising)
        XCTAssertEqual(risingResult.high.count, 1, "单调上升：末点是窗内最高")
        XCTAssertEqual(risingResult.low.count, 1, "单调上升：首点是窗内最低")
        XCTAssertEqual(risingResult.high.first?.height ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(risingResult.low.first?.height ?? 0, 0.1, accuracy: 0.0001)

        let falling = points([0.4, 0.3, 0.2, 0.1])
        let fallingResult = TideForecast.extrema(in: falling)
        XCTAssertEqual(fallingResult.high.count, 1)
        XCTAssertEqual(fallingResult.low.count, 1)
    }

    /// 极值时刻取**实测采样格本身**，不做插值（插值是模型推测值）。
    func testExtremaTimeIsSampledGridNotInterpolated() {
        let start: Double = 1_791_302_400
        let series = points([-0.4, 0.0, 0.8, 0.0, -0.4], startEpoch: start, step: 900)
        let result = TideForecast.extrema(in: series)
        let high = result.high.first
        // 峰值在index 2 → 时刻必须**正好**落在第3 个采样格上。
        XCTAssertEqual(high?.time, Date(timeIntervalSince1970: start + 2 * 900))
    }

    // MARK: - 9．24 小时窗

    /// 半开窗`[now, now+24h)`：`now` 本身**在**窗内（刷新后曲线不空一格）。
    func testPointsInNext24HoursIncludesNowAndExcludesEnd() {
        let start: Double = 1_791_302_400
        let step: Double = 900
        // 造 200 点（远超 24 小时 = 96 点）。
        let values = (0..<200).map { _ in 0.5 as Double? }
        let series = points(values, startEpoch: start, step: step)
        let forecast = TideForecast(points: series, totalPoints: 200)

        let now = Date(timeIntervalSince1970: start)
        let window = forecast.pointsInNext24Hours(now: now)
        // [start, start+24h) 含 start、排除 start+24h → 96 点。
        XCTAssertEqual(window.count, 96, "24 小时 ÷ 15 分钟 = 96 点（半开窗）")
        XCTAssertEqual(window.first?.time, now, "窗必须含 now 本身")
        XCTAssertNotEqual(window.last?.time,
                          now.addingTimeInterval(24 * 60 * 60),
                          "窗必须排除 24 小时那一格（半开）")
    }

    /// 全部落在过去 → 空窗（UI 应整卡不渲染）。
    func testPointsInNext24HoursEmptyWhenAllInPast() {
        let forecast = TideForecast(points: points([0.1, 0.2]), totalPoints: 2)
        let future = Date(timeIntervalSince1970: 1_791_302_400 + 86_400)
        XCTAssertTrue(forecast.pointsInNext24Hours(now: future).isEmpty)
    }

    // MARK: - 10．时刻解析

    /// `timeformat=unixtime` 下时刻为 epoch 整数（实测`[1791302400, ...]`）。
    func testTideTimeParsesFromUnixSeconds() throws {
        let forecast = try tide(Self.dalianTideJSON)
        let first = try XCTUnwrap(forecast.points.first)
        XCTAssertEqual(first.time, Date(timeIntervalSince1970: 1_791_302_400))
        // 相邻点间隔实测 900 秒（15 分钟）。
        let second = try XCTUnwrap(forecast.points.dropFirst().first)
        XCTAssertEqual(second.time.timeIntervalSince(first.time), 900, accuracy: 0.001)
    }

    /// `utc_offset_seconds` 缺失 + ISO 时刻 → **放弃解析**（该点被丢弃），
    /// 绝不拿 0 硬解（那会让时刻静默偏移几小时）。
    ///
    /// ⚠️ 下面喂的是 `minutely_15` **块本身**（不是整包响应）——
    ///   若误喂 `{"minutely_15":{...}}`，三个键都取不到（属性全可选 → 静默为 nil），
    ///   测试会因错误的原因"通过"。
    func testTideIsoTimeWithoutOffsetIsDroppedNotGuessed() throws {
        let json = #"""
        {"time":["2026-10-07T00:00"],
         "sea_level_height_msl":[-0.54],
         "invert_barometer_height":[-0.10]}
        """#
        let decoded = try JSONDecoder().decode(MarineConditionsResponse.Minutely15.self,
                                               from: Data(json.utf8))
        // 先确认块真的解出了时刻与数值（本测试的前提，否则下面就是空转）。
        XCTAssertNotNil(decoded.time)
        XCTAssertEqual(decoded.sea_level_height_msl?.count, 1)

        let forecast = MarineMapper.mapTide(decoded, utcOffsetSeconds: nil)
        XCTAssertTrue(forecast.points.isEmpty,
                      "ISO 时刻且偏移缺失 → 必须放弃解析，绝不拿 0 硬解")
    }

    /// ISO 时刻 + **有**偏移 → 正常解析（兜底路径必须是对的）。
    ///
    /// ⚠️ 喂 `minutely_15` 块本身（同上，误喂整包会静默解出全 nil）。
    func testTideIsoTimeWithOffsetParses() throws {
        let json = #"""
        {"time":["2026-10-07T00:00"],
         "sea_level_height_msl":[-0.54],
         "invert_barometer_height":[-0.10]}
        """#
        let decoded = try JSONDecoder().decode(MarineConditionsResponse.Minutely15.self,
                                               from: Data(json.utf8))
        let forecast = MarineMapper.mapTide(decoded, utcOffsetSeconds: 28800)
        let point = try XCTUnwrap(forecast.points.first)
        XCTAssertEqual(point.astronomical ?? 0, -0.44, accuracy: 0.0001)
        let expected = ISOTimeStringDecoder.date(from: "2026-10-07T00:00", utcOffsetSeconds: 28800)
        XCTAssertEqual(point.time, expected)
    }

    // MARK: - 11．源目录一致性

    /// marine 源必须同时声明海浪与潮汐两个能力（署名页要能分开显示）。
    func testMarineSourceDeclaresTideCapability() throws {
        let descriptor = try XCTUnwrap(SourceDirectory.all.first { $0.id == .marineForecast })
        XCTAssertTrue(descriptor.capabilities.contains(.marineWaveConditions))
        XCTAssertTrue(descriptor.capabilities.contains(.marineTide),
                      "marine 源必须声明 .marineTide，否则署名页看不到潮汐能力")
        // 能力必须有中文名（否则设置页会显示"（未命名能力）"）。
        XCTAssertFalse(DataAttribution.capabilityText(.marineTide).isEmpty)
        XCTAssertFalse(DataAttribution.capabilityText(.marineTide).contains("未命名"),
                       "潮汐能力必须有像样的中文说明")
    }

    /// 潮汐是**逐序列**能力，绝不复用逐时/实况能力（那是虚报能力）。
    func testTideCapabilityIsDistinctFromOtherCapabilities() {
        XCTAssertNotEqual(SourceCapability.marineTide, SourceCapability.marineWaveConditions)
        XCTAssertNotEqual(SourceCapability.marineTide, SourceCapability.hourlyForecast)
        XCTAssertNotEqual(SourceCapability.marineTide, SourceCapability.currentObservation)
        // CaseIterable 必须含它（providesText 靠allCases遍历）。
        XCTAssertTrue(SourceCapability.allCases.contains(.marineTide))
    }
}
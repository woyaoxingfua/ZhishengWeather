//
//  MarineFloodSourcesTests.swift
//  ZhishengWeatherTests
//
//  第四源（marine-api.open-meteo.com 海浪）+ 第五源（flood-api.open-meteo.com
//  河道流量）的接入锚点。不联网、不读真实时钟：全部喂本地造好的 JSON。
//
// 覆盖清单（对应本轮的四项硬要求）：
//  1．**端点**：独立子域名（写主站一律 404，这是本轮的硬要求）；
//     变量名实测形态；`timeformat=unixtime` / `timezone=auto` 已钉死。
//  2．**非空判定四态**：整块缺失 / 元素全 null / 部分 null / 正常。
//     两种失败形态都得防（实测 Open-Meteo 会「静默省略整块」也会「元素给 null」）。
//  3．**坐标判据边界**：沿海放行、内陆挡下（省配额），且诚实承认它**不精确**
//     —— 上海这类沿海城市由响应后的 isEffectivelyEmpty 兜底。
//  4．**单位映射**：`river_discharge` 是 **m³/s**；`wave_direction` 是**度**。
//  5．**`0` 与缺测严格区分**：断流的 0.00 是**真实读数**，不是"没查到"。
//  6．**源目录一致性**：`SourceID.allCases` ↔ `SourceDirectory.all` 双射。
//
// ⚠️ **rawValue 一律从枚举派生，绝不硬编码字符串**（沿用 `METNorwayTests` 的
// 纪律：初版曾把 case 名 `"sunriseSunset"` 当 rawValue 写进测试，
// 而真实 rawValue 是 `"sunrise-sunset"`，导致一批测试必红）。
//
// ⚠️ 并发纪律：`XCTAssert*` 的实参是 **autoclosure**，装不下 `await`。
// 故所有 `await` 都先求值到局部常量再断言。
//

import XCTest
import Foundation
@testable import ZhishengWeather

final class MarineFloodSourcesTests: XCTestCase {

    // MARK: - 实测样本（2026-10-06 探针逐字形态）

    /// 青岛 (36.07,120.38) 实测：六项齐全（独立子域名 marine-api）。
    private static let qingdaoJSON = #"""
    {"latitude":36.041664,"longitude":120.375015,"utc_offset_seconds":28800,
     "current_units":{"time":"unixtime","interval":"seconds",
                      "wave_height":"m","wave_direction":"°","wave_period":"s",
                      "swell_wave_height":"m","swell_wave_direction":"°",
                      "swell_wave_period":"s"},
     "current":{"time":1791285300,"interval":900,
                "wave_height":0.34,"wave_direction":197,"wave_period":3.10,
                "swell_wave_height":0.22,"swell_wave_direction":181,
                "swell_wave_period":3.50}}
    """#

    /// 北京 (39.9,116.4) 实测：**HTTP 200 但三项全 null**（内陆坐标的常态形态）。
    private static let beijingNullJSON = #"""
    {"latitude":39.875,"longitude":116.375015,"utc_offset_seconds":28800,
     "current_units":{"time":"unixtime","interval":"seconds","wave_height":"m"},
     "current":{"time":1791284400,"interval":900,
                "wave_height":null,"wave_direction":null,"wave_period":null}}
    """#

    /// 武汉 (30.6,114.3) 实测：7 天逐日流量（`forecast_days=7`）。
    private static let wuhanJSON = #"""
    {"latitude":30.575005,"longitude":114.32501,"utc_offset_seconds":28800,
     "daily_units":{"time":"unixtime","river_discharge":"m³/s"},
     "daily":{"time":[1791216000,1791302400,1791388800,1791475200,
                      1791561600,1791648000,1791734400],
              "river_discharge":[5.70,2.35,1.29,0.64,0.28,0.16,0.12]}}
    """#

    // MARK: - Helpers

    private func decodeMarine(_ json: String) throws -> MarineConditionsResponse {
        try JSONDecoder().decode(MarineConditionsResponse.self, from: Data(json.utf8))
    }

    private func decodeFlood(_ json: String) throws -> FloodResponse {
        try JSONDecoder().decode(FloodResponse.self, from: Data(json.utf8))
    }

    private func marine(_ json: String) throws -> MarineConditions {
        MarineMapper.map(try decodeMarine(json))
    }

    private func flood(_ json: String) throws -> RiverDischarge {
        FloodMapper.map(try decodeFlood(json))
    }

    // MARK: - 1．端点：独立子域名（本轮硬要求）

    /// marine端点必须在 `marine-api.` 子域，且**只有一条 URL / 一次请求**。
    ///
    /// ⚠️ 锚的是**性质**（"独立子域名"），不是整串 URL：改版本路径不该让守卫失效。
    /// 但同时钉住"不得出现第二个 marine 主机"，防"新增一条重试 URL"。
    func testMarineEndpointUsesDedicatedSubdomainAndSingleRequest() throws {
        let url = try XCTUnwrap(MarineEndpoint.url(latitude: 36.07, longitude: 120.38))
        let absolute = url.absoluteString

        XCTAssertTrue(absolute.hasPrefix("https://marine-api.open-meteo.com/v1/marine"),
                      "marine 端点必须在独立子域marine-api.open-meteo.com"
                      + "（写在主站 api.open-meteo.com 上一律 404），实际=\(absolute)")
        XCTAssertEqual(absolute.components(separatedBy: "marine-api.open-meteo.com").count - 1, 1,
                       "不得新增第二条 marine 请求 URL")
        // 🔴 锚**host**，不用子串（2026-10-07 修正的测试缺陷）。
        //
        // ⚠️ 旧写法`!absolute.contains("api.open-meteo.com/v1/marine")`
        // **永远为假**：正确 host 是 `marine-api.open-meteo.com`，它本身就
        // **包含**子串 `api.open-meteo.com/v1/marine` ⇒ 该断言与本函数
        // 第一条 `hasPrefix("https://marine-api...")` 断言**自相矛盾**，
        // 两条不可能同时通过。这不是 marine 端点写错了，是**守卫写法错了**。
        //
        // 意图（"不得把 marine 挂到主站路径上，实测 404"）的正确表达是
        // **host 精确等于 marine 子域**，而不是子串否定。
        XCTAssertEqual(url.host, "marine-api.open-meteo.com",
                       "marine 请求必须打到独立子域（主站 api.open-meteo.com上一律 404）")
        XCTAssertNotEqual(url.host, "api.open-meteo.com",
                          "🔴 不得把 marine 请求挂到主站 host 上（实测 404）")

        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let names = items.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "参数名必须唯一，实际=\(names)")
        XCTAssertTrue(names.contains("current"), "必须声明 current 字段")
        XCTAssertTrue(names.contains("timezone"), "必须声明 timezone")
        XCTAssertTrue(names.contains("timeformat"))
    }

    /// `timeformat=unixtime` —— 否则 `current.time` 是 ISO 字符串，
    /// 与 DTO 的 `FlexibleTime` 之外的假设不符（且既有 run37 事故的前车之鉴）。
    func testMarineEndpointDeclaresUnixtimeAndAutoTimezone() throws {
        let url = try XCTUnwrap(MarineEndpoint.url(latitude: 36.07, longitude: 120.38))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        XCTAssertEqual(value("timeformat"), "unixtime",
                       "marine 必须钉死 timeformat=unixtime（否则时间字段是字符串）")
        XCTAssertEqual(value("timezone"), "auto", "marine 应跟随坐标时区（与主链路一致）")
    }

    /// 请求的 marine 字段**只允许**是那六个实测变量。
    ///
    /// ⚠️ 这条守卫锚的是一个**已实测的危险**：把主站变量名（`temperature_2m` 等）
    /// 加进 marine 端点不会400、而是**安静地返回 null**（静默失败）。
    /// 故断言"不含任何非 marine 变量名"，防止后人顺手加一个。
    func testMarineEndpointRequestsOnlyVerifiedMarineVariables() throws {
        let fields = MarineEndpoint.currentFields.split(separator: ",").map(String.init)
        XCTAssertEqual(Set(fields).count, fields.count, "字段列表不得重复：\(fields)")

        let verified: Set<String> = ["wave_height", "wave_direction", "wave_period",
                                     "swell_wave_height", "swell_wave_direction",
                                     "swell_wave_period"]
        XCTAssertEqual(Set(fields), verified,
                       "marine 字段集与实测不符：多出的变量名会被**静默省略**成null"
                       + "（实测：主站变量名加到 marine 端点不报错，只给 null）")

        // 明确点名主站变量，防止"看起来合理"的复制粘贴。
        for mainSiteVariable in ["temperature_2m", "relative_humidity_2m",
                                 "wind_speed_10m", "weather_code", "precipitation"] {
            XCTAssertFalse(fields.contains(mainSiteVariable),
                           "\(mainSiteVariable) 是**主站**变量，marine 端点不支持；"
                           + "加上它会静默得到 null（实测不报400）")
        }
    }

    /// flood 端点：独立子域名 + `daily` + 显式 `forecast_days`。
    ///
    /// ⚠️ `forecast_days` 必须显式声明：实测不声明时服务端返回**92 天**，
    /// 既拖长响应体又让 UI 拿到一长串用不到的远期值。
    func testFloodEndpointUsesSubdomainAndPinsForecastDays() throws {
        let url = try XCTUnwrap(FloodEndpoint.url(latitude: 30.6, longitude: 114.3))
        let absolute = url.absoluteString

        XCTAssertTrue(absolute.hasPrefix("https://flood-api.open-meteo.com/v1/flood"),
                      "flood 端点必须在独立子域 flood-api.open-meteo.com"
                      + "（写在主站上一律 404），实际=\(absolute)")
        XCTAssertEqual(absolute.components(separatedBy: "flood-api.open-meteo.com").count - 1, 1,
                       "不得新增第二条 flood 请求 URL")

        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        XCTAssertEqual(value("forecast_days"), String(FloodEndpoint.forecastDays),
                       "必须显式钉住 forecast_days（实测默认 92 天，太宽）")
        XCTAssertEqual(value("timeformat"), "unixtime")
        XCTAssertEqual(value("timezone"), "auto")
        XCTAssertEqual(value("daily"), "river_discharge")
    }

    /// ⚠️ `river_discharge` 是**逐日**变量：放进 `hourly` 会**HTTP 400**。
    ///
    /// 实测 `hourly=river_discharge` → `Invalid value: ... from invalid String
    /// value river_discharge`。故端点必须只请求 `daily`，绝不能出现 `hourly`。
    func testFloodEndpointNeverRequestsHourlyDischarge() throws {
        let url = try XCTUnwrap(FloodEndpoint.url(latitude: 30.6, longitude: 114.3))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let names = Set(items.map(\.name))

        XCTAssertFalse(names.contains("hourly"),
                       "river_discharge 是daily-only 变量（实测放进 hourly 会 HTTP 400）")
        XCTAssertFalse(names.contains("current"),
                       "flood 端点没有 current 块（实测只有 daily）")
    }

    // MARK: - 2．非空判定四态

    /// marine 四态：整块缺失 / 元素全 null / 部分 null / 正常。
    func testMarineEmptinessFourStates() throws {
        // ① 整块被静默省略（变量名在词表但端点不支持）→ 空。
        let noBlock = try marine("{}")
        XCTAssertTrue(noBlock.isEffectivelyEmpty, "① 缺 current 块 -> 实质无数据")
        XCTAssertNil(noBlock.capturedAt)

        // ② 元素全 null（实测北京）→ 空。**这是最危险的一态**：
        //    解码成功、不抛错，若不判定就会把 null 当0 画成"海面平静"。
        let allNull = try marine(Self.beijingNullJSON)
        XCTAssertTrue(allNull.isEffectivelyEmpty, "② 元素全 null -> 实质无数据")
        XCTAssertNil(allNull.waveHeight)
        XCTAssertNil(allNull.waveDirection)
        XCTAssertNil(allNull.wavePeriod)

        // ③ 部分 null → **有数据**（缺口如实展示，不整张卡藏掉）。
        let partial = try marine(#"""
        {"utc_offset_seconds":28800,
         "current":{"time":1791285300,"wave_height":0.34,"wave_direction":null}}
        """#)
        XCTAssertFalse(partial.isEffectivelyEmpty, "③ 部分 null -> 仍有数据，不得整卡隐藏")
        XCTAssertEqual(partial.waveHeight, 0.34)
        XCTAssertNil(partial.wavePeriod, "缺的仍是 nil（不是 0）")

        // ④ 正常（实测青岛六项齐全）。
        let full = try marine(Self.qingdaoJSON)
        XCTAssertFalse(full.isEffectivelyEmpty)
        XCTAssertEqual(full.waveHeight, 0.34)
        XCTAssertEqual(full.waveDirection, 197)
        XCTAssertEqual(full.wavePeriod, 3.10)
        XCTAssertEqual(full.swellWaveHeight, 0.22)
        XCTAssertEqual(full.swellWaveDirection, 181)
        XCTAssertEqual(full.swellWavePeriod, 3.50)
    }

    /// flood 四态：整块省略 / 元素全 null / 部分 null / 正常。
    func testFloodEmptinessFourStates() throws {
        // ① 整块静默省略。
        let noBlock = try flood("{}")
        XCTAssertTrue(noBlock.isEffectivelyEmpty, "① 缺 daily 块 -> 实质无数据")
        XCTAssertTrue(noBlock.daily.isEmpty)

        // ② 元素全 null。
        let allNull = try flood(#"""
        {"daily":{"time":[1791216000,1791302400],"river_discharge":[null,null]}}
        """#)
        XCTAssertTrue(allNull.isEffectivelyEmpty, "② 元素全 null -> 实质无数据")
        XCTAssertEqual(allNull.daily.count, 2, "日期本身有效，仍应保留（缺口如实）")

        // ③ 部分 null → 有数据。
        let partial = try flood(#"""
        {"daily":{"time":[1791216000,1791302400,1791388800],
                  "river_discharge":[5.07,null,null]}}
        """#)
        XCTAssertFalse(partial.isEffectivelyEmpty, "③ 部分 null -> 仍有数据")
        XCTAssertEqual(partial.daily.first?.cubicMetresPerSecond, 5.07)
        XCTAssertNil(partial.daily[1].cubicMetresPerSecond, "缺测必须是 nil，绝不补 0")

        // ④ 正常（实测武汉 7 天）。
        let full = try flood(Self.wuhanJSON)
        XCTAssertFalse(full.isEffectivelyEmpty)
        XCTAssertEqual(full.daily.count, 7)
        XCTAssertEqual(full.daily.map(\.cubicMetresPerSecond),
                       [5.70, 2.35, 1.29, 0.64, 0.28, 0.16, 0.12])
    }

    /// 权威判据必须落在 `SnapshotCompleteness`（**单一真源**），不是各模型自带一份。
    ///
    /// 这条钉的是"三处判据同源"这条性质：marine / flood / 天气快照
    /// 走同一个类型，避免出现 N 份各自实现的同名判据（必然漂移）。
    func testEmptinessJudgmentLivesInSnapshotCompleteness() {
        let conditions = MarineConditions.empty
        let discharge = RiverDischarge.empty

        XCTAssertTrue(SnapshotCompleteness.isEffectivelyEmpty(conditions),
                      "权威判据应在 SnapshotCompleteness（天气快照那份的同类型重载）")
        XCTAssertTrue(SnapshotCompleteness.isEffectivelyEmpty(discharge))

        // 便捷属性与权威判据必须一致（转发，不是各写一份）。
        XCTAssertEqual(conditions.isEffectivelyEmpty,
                       SnapshotCompleteness.isEffectivelyEmpty(conditions))
        XCTAssertEqual(discharge.isEffectivelyEmpty,
                       SnapshotCompleteness.isEffectivelyEmpty(discharge))
    }

    // MARK: - 3．`0` 与缺测严格区分

    /// 全 0 的海浪是**真静水**，是数据，不是缺测。
    ///
    /// ⚠️ 若把0 当缺测，无浪的日子会显示"无数据"；反向若把缺测当 0，
    /// 则内陆城市会显示"海面平静"。两头都要防。
    func testZeroIsAValidReadingNotMissing() throws {
        let calm = try marine(#"""
        {"utc_offset_seconds":28800,
         "current":{"time":1791285300,
                    "wave_height":0.0,"wave_direction":0.0,"wave_period":0.0,
                    "swell_wave_height":0.0,"swell_wave_direction":0.0,
                    "swell_wave_period":0.0}}
        """#)

        XCTAssertFalse(calm.isEffectivelyEmpty, "全 0 是真实静水，不得判成无数据")
        XCTAssertEqual(calm.waveHeight, 0.0, "0 是合法浪高")
        XCTAssertEqual(calm.waveDirection, 0.0, "浪向 0（正北来浪）是合法取值，不是缺失")

        // 断流：实测乌鲁木齐 [0.00,0.00,0.00] —— 有键有值，是真实断流读数。
        let driedUp = try flood(#"""
        {"daily":{"time":[1791216000,1791302400,1791388800],
                  "river_discharge":[0.00,0.00,0.00]}}
        """#)
        XCTAssertFalse(driedUp.isEffectivelyEmpty,
                       "断流的 0.00 是**真实读数**，判成无数据等于把断流说成没查到")
        XCTAssertEqual(driedUp.daily.map(\.cubicMetresPerSecond), [0.0, 0.0, 0.0])
    }

    /// 负值 / 越界来向 → 缺测（宁缺不猜，绝不冒充合法读数）。
    func testNegativeAndOutOfRangeValuesBecomeNil() throws {
        let bad = try marine(#"""
        {"utc_offset_seconds":28800,
         "current":{"time":1791285300,
                    "wave_height":-0.5,"wave_direction":360.0,"wave_period":-3.0}}
        """#)

        XCTAssertNil(bad.waveHeight, "负浪高是服务端异常数据，不得冒充合法读数")
        XCTAssertNil(bad.waveDirection, "来向 360 越界（合法值域 0–359）→ 缺测")
        XCTAssertNil(bad.wavePeriod, "负周期 → 缺测")
        XCTAssertTrue(bad.isEffectivelyEmpty, "净化后全 nil -> 实质无数据")

        // 负流量同理。
        let negativeFlow = try flood(#"""
        {"daily":{"time":[1791216000],"river_discharge":[-2.0]}}
        """#)
        XCTAssertNil(negativeFlow.daily[0].cubicMetresPerSecond,
                     "负流量不可能存在 -> 缺测")
        XCTAssertTrue(negativeFlow.isEffectivelyEmpty)
    }

    // MARK: - 4．单位映射（量纲）

    /// `river_discharge` 是 **m³/s**：原样透传、**绝不换算**。
    ///
    /// 量纲写进了字段名（`cubicMetresPerSecond`）—— 把"流量 kg/s"或"水量 m³"
    /// 搞错会因量纲不符立刻暴露，而不是悄悄显示错数。
    func testRiverDischargeUnitIsCubicMetresPerSecondAndNotConverted() throws {
        let full = try flood(Self.wuhanJSON)

        XCTAssertEqual(full.daily.first?.cubicMetresPerSecond, 5.70,
                       "5.70 m³/s 必须原样透传（服务端给的就是 m³/s，换算只会引入错误）")
        XCTAssertEqual(full.daily[3].cubicMetresPerSecond, 0.64,
                       "小数流量不得被截断或四舍五入成整数")
    }

    /// 浪向是**度**（0–359），不是百分数、不是 0–1 小数。
    ///
    /// 实测青岛 `wave_direction:197`、`swell_wave_direction:181`。
    func testWaveDirectionIsDegreesAndPreservedVerbatim() throws {
        let full = try marine(Self.qingdaoJSON)

        XCTAssertEqual(full.waveDirection, 197.0, "浪向单位是度（实测 197），不得换算成小数或方位")
        XCTAssertEqual(full.swellWaveDirection, 181.0)
        XCTAssertTrue((full.waveDirection ?? 0) >= 0 && (full.waveDirection ?? 0) < 360,
                      "浪向必须落在 [0,360) 度域内")
    }

    /// 时刻按 epoch 解析（端点钉死 unixtime），且**不加偏移**。
    func testEpochTimeIsParsedWithoutOffset() throws {
        let full = try marine(Self.qingdaoJSON)
        let captured = try XCTUnwrap(full.capturedAt)

        // epoch 1791285300 = 2026-10-06T11:15:00Z
        XCTAssertEqual(captured.timeIntervalSince1970, 1_791_285_300, accuracy: 0.001,
                       "epoch 必须原样解析（加偏移就错了——epoch 本身即绝对时刻）")

        let floodParsed = try flood(Self.wuhanJSON)
        XCTAssertEqual(floodParsed.daily.first?.date.timeIntervalSince1970 ?? 0,
                       1_791_216_000, accuracy: 0.001)
    }

    /// 兜底：ISO 形态时刻**必须有偏移**才能解析；偏移缺失就放弃（绝不拿 0 硬解）。
    ///
    /// ⚠️ 拿 `0` 硬解会让时刻静默偏移若干小时，且无报错、无崩溃——最坏的一类缺陷。
    func testIsoTimeFallbackRequiresRealOffsetAndNeverGuessesZero() throws {
        // 有偏移 -> 按该偏移解释墙钟。
        // 实测：marine 在 timezone=auto 下返回的本地墙钟正是 "2026-10-06T19:00"，
        // 而 epoch 形态对应 1791285300 = 11:15Z。两者的关系印证了偏移确实是 +08:00。
        let withOffset = try marine(#"""
        {"utc_offset_seconds":28800,
         "current":{"time":"2026-10-06T19:00","wave_height":0.34}}
        """#)
        let parsed = try XCTUnwrap(withOffset.capturedAt)
        // 19:00@+08:00 == 11:00Z == epoch 1791284400
        XCTAssertEqual(parsed.timeIntervalSince1970, 1_791_284_400, accuracy: 1.0,
                       "ISO 墙钟 19:00 必须按 +08:00 解释（= 11:00Z = 1791284400）")

        // 偏移缺失 -> **放弃解析**，但**不**影响其他字段。
        let noOffset = try marine(#"""
        {"current":{"time":"2026-10-06T19:00","wave_height":0.34}}
        """#)
        XCTAssertNil(noOffset.capturedAt,
                     "缺 utc_offset_seconds 时必须放弃 ISO 解析，绝不拿 0 硬解"
                     + "（那会静默偏移若干小时）")
        XCTAssertEqual(noOffset.waveHeight, 0.34, "放弃时刻不应连累数值字段")
    }

    /// DTO 容错：`null` 元素、缺块、null 块都**不得**让整包解码失败。
    func testNullTolerantDecoding() throws {
        // current 块为 null。
        let nullBlock = try decodeMarine(#"{"current":null}"#)
        XCTAssertNil(nullBlock.current)

        // 单个字段为 null。
        let nullField = try decodeMarine(#"{"current":{"wave_height":null}}"#)
        XCTAssertNil(nullField.current?.wave_height)

        // flood：数组含 null 元素（实测"部分支持"时的不支持变量就是 null 元素）。
        let nullElements = try decodeFlood(#"""
        {"daily":{"time":[1791216000,null,1791388800],
                  "river_discharge":[5.0,null,null]}}
        """#)
        XCTAssertEqual(nullElements.daily?.river_discharge?.count, 3,
                       "含 null 元素的数组必须能解码（否则整包失败 → 主屏与小组件同时无数据）")

        // 时刻为 null 的该日被跳过（不编造日期），且不与后续值串位。
        let mapped = FloodMapper.map(nullElements)
        XCTAssertEqual(mapped.daily.count, 2, "时刻为 null 的该日被跳过")
        // ⚠️ 显式写 [Double?]：让 nil 有确定的 Optional<Double> 类型，
        // 避免字面量 `[5.0, nil]` 的类型推断在编译期产生歧义。
        XCTAssertEqual(mapped.daily.map(\.cubicMetresPerSecond),
                       [Double(5.0), nil] as [Double?],
                       "剩下的第 2 项必须是「第 3 天对应 null」，不得串位")
    }

    /// 两个数组长度不齐时：取交集，既不越界也不串位。
    func testRaggedArraysDoNotCrashOrMisalign() throws {
        let shorter = try flood(#"""
        {"daily":{"time":[1791216000,1791302400,1791388800],
                  "river_discharge":[5.0]}}
        """#)
        XCTAssertEqual(shorter.daily.count, 1, "值数组更短 -> 只取交集")

        let longer = try flood(#"""
        {"daily":{"time":[1791216000],"river_discharge":[5.0,6.0,7.0]}}
        """#)
        XCTAssertEqual(longer.daily.count, 1, "值数组更长 -> 只取交集（不串位）")
        XCTAssertEqual(longer.daily.first?.cubicMetresPerSecond, 5.0)
    }

    // MARK: - 5．坐标判据边界

    /// 判据的核心性质：**内陆挡下、沿海放行**（锚性质，不锚具体矩形数值）。
    ///
    /// 为什么这条重要：marine 对内陆坐标返回 **HTTP 200 + 全 null**，
    /// 所以"要不要发请求"必须由我们自己回答，否则内陆城市每次刷新都白烧配额。
    func testCoordinateGateBlocksInlandAndAllowsCoastal() {
        // 实测有值的沿海点。
        let coastal: [(String, Double, Double)] = [
            ("青岛", 36.07, 120.38), ("厦门", 24.48, 118.09),
            ("威海", 37.51, 122.12), ("香港", 22.32, 114.17),
            ("三亚", 18.50, 109.80), ("纽约", 40.71, -74.01),
            ("悉尼", -33.87, 151.21), ("新加坡", 1.35, 103.82),
        ]
        for (name, lat, lon) in coastal {
            XCTAssertTrue(MarineEndpoint.requestEligibility(latitude: lat, longitude: lon),
                          "\(name) 是实测有浪数据的沿海点，判据必须放行")
        }

        // 实测 null 的内陆点。
        let inland: [(String, Double, Double)] = [
            ("北京", 39.90, 116.40), ("武汉", 30.59, 114.31),
            ("乌鲁木齐", 43.80, 87.60), ("拉萨", 29.65, 91.10),
            ("莫斯科", 55.75, 37.62), ("京都", 35.03, 135.77),
            ("广州", 23.13, 113.26), ("德黑兰", 35.68, 51.42),
        ]
        for (name, lat, lon) in inland {
            XCTAssertFalse(MarineEndpoint.requestEligibility(latitude: lat, longitude: lon),
                           "\(name) 实测无浪数据，判据必须挡下（否则白烧配额 + 空卡片）")
        }
    }

    /// 判据**允许**误放行少数沿海城市 —— 这是诚实的设计取舍，必须钉成断言。
    ///
    /// 实测上海 (31.23,121.47) / 杭州 (30.25,120.15) 是沿海城市，
    /// 但 marine 返回 null（网格吸附到陆地/河口网格点）。
    /// 判据**不为**它们负责（它们本就是沿海城市），而由响应后的
    /// `isEffectivelyEmpty` 兜住 —— 只做①不做②就会在��海显示"浪高 0"。
    func testGateMayAllowCoastalCitiesThatReturnNullAndEmptinessCatchesThem() throws {
        // 上海：判据放行（它是沿海城市）。
        XCTAssertTrue(MarineEndpoint.requestEligibility(latitude: 31.23, longitude: 121.47),
                      "上海是沿海城市，判据放行是正确取舍（真实无数据由 isEffectivelyEmpty兜）")

        // 但一旦拿到响应且全 null，必须判定为实质无数据 → 整卡隐藏。
        let shanghaiNull = #"""
        {"utc_offset_seconds":28800,
         "current":{"time":1791284400,
                    "wave_height":null,"wave_direction":null,"wave_period":null,
                    "swell_wave_height":null,"swell_wave_direction":null,
                    "swell_wave_period":null}}
        """#
        let parsed = try marine(shanghaiNull)
        XCTAssertTrue(parsed.isEffectivelyEmpty,
                      "判据放行但响应全 null 时，必须由 isEffectivelyEmpty 兜住"
                      + "（否则会把「无数据」显示成「浪高 0 m」= 凭空造一个平静海面）")
    }

    /// flood **不做**坐标判据：内陆城市实测**照样有流量值**。
    ///
    /// 实测北京 (39.9,116.4) → `[5.07, 5.05, ...]`；拉萨 → `[0.24, ...]`。
    /// 按"是否沿海"过滤会**错杀**真实数据 —— 这与 marine 恰好相反，
    /// 不可把marine 的经验外推。
    func testFloodHasNoCoastalGateBecauseInlandCitiesDoHaveDischarge() throws {
        let endpointSource = FloodEndpoint.url(latitude: 39.90, longitude: 116.40)
        XCTAssertNotNil(endpointSource,
                        "flood 对内陆坐标必须照常构造请求（实测北京有流量值）")

        // 实测北京内陆坐标的响应形态：有值，且必须被正常映射。
        let beijingFlow = try flood(#"""
        {"daily":{"time":[1791216000,1791302400],
                  "river_discharge":[5.07,5.05]}}
        """#)
        XCTAssertFalse(beijingFlow.isEffectivelyEmpty,
                       "内陆城市的河道流量是真实数据，不得因坐标判据被丢弃")
        XCTAssertEqual(beijingFlow.daily.first?.cubicMetresPerSecond, 5.07)
    }

    // MARK: - 6．源目录一致性

    /// 两个新源必须已登记在 `SourceDirectory.all`（**唯一**手工点）。
    ///
    /// 漏登记的后果（本仓现实样本）：自动摘除哑火 + 设置页隐身，且完全静默。
    func testBothSourcesAreRegisteredInSourceDirectory() throws {
        let marineDescriptor = try XCTUnwrap(
            SourceDirectory.descriptor(for: .marineForecast),
            "marine 源必须登记在 SourceDirectory.all —— 否则设置页不显示、"
            + "自动摘除查不到它的行为标记")
        let floodDescriptor = try XCTUnwrap(
            SourceDirectory.descriptor(for: .floodForecast),
            "flood 源必须登记在 SourceDirectory.all")

        for (descriptor, expectedCapability) in [
            (marineDescriptor, SourceCapability.marineWaveConditions),
            (floodDescriptor, SourceCapability.riverDischarge)
        ] {
            XCTAssertEqual(descriptor.role, .auxiliary, "\(descriptor.id.rawValue) 是辅助源")
            XCTAssertFalse(descriptor.needsCredential,
                           "\(descriptor.id.rawValue) 免 Key，绝不标成需要凭据")
            XCTAssertTrue(descriptor.capabilities.contains(expectedCapability))

            // ⚠️ 能力不得虚报：只声明自己真正提供的那一项。
            // 显式写 Set([...]) 而不是数组字面量 —— 避免类型推断歧义
            //（Set 也是 ExpressibleByArrayLiteral，两种写法都能过但意图不清）。
            XCTAssertEqual(descriptor.capabilities, Set([expectedCapability]),
                           "\(descriptor.id.rawValue) 只应声明一项能力")

            // ⚠️ requiredFields 必须**诚实留空**：海浪 / 流量字段不在
            // WeatherFieldKey 域内，塞假字段会让 EV-1 判"永远缺字段"。
            XCTAssertTrue(descriptor.requiredFields.isEmpty,
                          "\(descriptor.id.rawValue) 的字段不在 WeatherFieldKey 域内，"
                          + "requiredFields 必须留空（多写一个会被EV-1 误摘）")

            // 与空气源同处境：未接线 → 不参与自动摘除（不给设置页假开关）。
            XCTAssertFalse(descriptor.participatesInAutoExclusion,
                           "\(descriptor.id.rawValue) 尚无调用点上报 EV-1/EV-3，"
                           + "诚实置 false")

            // 署名链接（CC BY 4.0）：非空且可解析。
            XCTAssertFalse(descriptor.websiteURLString.isEmpty)
            XCTAssertNotNil(descriptor.websiteURL)
        }
    }

    /// 能力声明不得复用 `.dailyForecast` —— 那是**虚报能力**。
    ///
    /// marine / flood 都不提供高低温、天气码、降水概率。
    /// 复用 `.dailyForecast` 会让下游按能力寻址时误信。
    func testNewCapabilitiesDoNotReuseDailyForecast() {
        XCTAssertNotEqual(SourceCapability.marineWaveConditions, .dailyForecast)
        XCTAssertNotEqual(SourceCapability.riverDischarge, .dailyForecast)

        // 能力是独立 case（可在 allCases 里被单独寻址）。
        XCTAssertTrue(SourceCapability.allCases.contains(.marineWaveConditions))
        XCTAssertTrue(SourceCapability.allCases.contains(.riverDischarge))
    }

    /// `SourceID.allCases` ↔ `SourceDirectory.all` 的**双射**仍然成立。
    ///
    /// 与 `SourceDirectoryCoverageTests` 同一条性质，这里针对两个新源再钉一次，
    /// 因为「加了 case 忘了登记」正是本轮最容易犯的错。
    func testSourceIDCasesAndDirectoryStayBijective() {
        let declared = Set(SourceID.allCases)
        let catalogued = Set(SourceDirectory.all.map(\.id))

        XCTAssertEqual(declared, catalogued,
                       "声明的源集合与目录条目集合必须相等（漏登记 → 设置页隐身 + 摘除哑火）")
        XCTAssertEqual(SourceDirectory.all.count, declared.count,
                       "目录条目数应与源声明数一致（防重复条目把「相等」凑出来）")

        for id in [SourceID.marineForecast, .floodForecast] {
            XCTAssertTrue(catalogued.contains(id), "\(id.rawValue) 未登记进 SourceDirectory")
        }
    }

    /// `rawValue` 从枚举派生（绝不硬编码字符串），且与既有源不撞车。
    ///
    /// rawValue 是**持久化键**（`SourcePreferences` / `SourceHealthLedger` 用它落盘），
    /// 撞车会让账本与偏好互相串台。
    func testRawValuesAreDerivedAndUnique() {
        for id in [SourceID.marineForecast, .floodForecast] {
            let raw = id.rawValue
            XCTAssertEqual(SourceID(rawValue: raw), id, "派生的 rawValue 必须能被枚举认回")
            XCTAssertTrue(raw.contains("-"), "rawValue 用连字符串风格，实际=\(raw)")
            XCTAssertFalse(raw.contains("_"), "rawValue 不应含下划线，实际=\(raw)")

            let others = SourceID.allCases.filter { $0 != id }.map(\.rawValue)
            XCTAssertFalse(others.contains(raw), "rawValue 与已有源重复")
        }

        // ⚠️ rawValue 必须与**实际域名语义一致**：端点已迁到独立子域名。
        XCTAssertEqual(SourceID.marineForecast.rawValue, "open-meteo-marine")
        XCTAssertEqual(SourceID.floodForecast.rawValue, "open-meteo-flood")
    }
}
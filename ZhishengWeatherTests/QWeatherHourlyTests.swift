//
//  QWeatherHourlyTests.swift
//  ZhishengWeatherTests
//
//  第九源「和风天气」**逐时端点**的接入锚点。不联网、不读真实时钟：
//  全部喂本地造好的 JSON（形态逐字取自主理人 2026-10-09 实测响应）。
//
//  ══════════════════════════════════════════════════════════════════════════
//  🔴🔴 本文件存在的**首要理由**：钉死三个「看起来可以顺手改对、其实会改错」的点。
//  这三个都**不会**让编译器报错、运行时**多数也看不出来**，只有断言能挡住：
//
//  ① **顶层键是 `hours`，不是 `hourly`** —— 端点路径是 `/weather/v1/hourly/…`
//     （路径段确实是 `hourly`），但响应体的顶层数组键实测逐字是 `hours`。
//     写错 → `CodingKeys` 找不到该键 → 该字段为 nil → 整源**静默变成「无数据」**
//     （卡片显示「上游未下发逐时预报」，**没有任何报错**）。这是 P-18 最坏的形态。
//     有人看到路径里的 `hourly` 会「顺手」把 DTO 也改成 `hourly` —— 本文件挡住。
//
//  ② **`humidity = 0.33` 是小数，不是 33** —— 有人看到「湿度」会习惯性乘 100
//     再存进一个名叫 `humidity` 的字段（或者反过来，把 0.33 当百分数丢掉 100 倍）。
//     实测值 0.33 落在 `[0,1]`，与逐日**同一量纲**。本文件双向断言：
//     既要它**原样**是 0.33，也要渲染层**乘 100** 后是「33%」。
//
//  ③ **字段缺失不得抛错** —— 逐时某个套餐少给一个键是迟早的事。
//     若那条路径抛错 → **整包失败 → 整个源静默消失**（P-18）。
//     本文件用「只剩 metadata + 一个空对象」的载荷断言不抛。
//
//  ── 其余覆盖 ────────────────────────────────────────────────────────────
//  ④ `windGust`（逐时）vs `windGustMax`（逐日）—— 键名不同，写错只是解出 nil；
//  ⑤ 越界分数（`humidity = 33`）→ **判为异常 → nil**，绝不 clamp 成 1.0；
//  ⑥ `0` 与「缺测」严格区分（实测 `cloudCover = 0` / `probability = 0` 是真值）；
//  ⑦ `hours` 越界 → URL 为 nil（**不**静默改成 24）；
//  ⑧ 端点形态：路径逐字、坐标两位小数、`hours` 查询参数；
//  ⑨ 四态：`.noData`（查了没有）与 `.unavailable`（取不到）分开；
//  ⑩ 署名**并集去重**（逐日 + 逐时两份 `metadata.attributions` 只渲染一次）；
//  ⑪ 逐时与逐时**互不拖累**：逐时失败不影响逐日，反之亦然。
//
//  ⚠️ 并发纪律：`XCTAssert*` 的实参是 **autoclosure**，装不下 `await`。
//  故所有 `await` 都先求值到局部常量再断言（同 `NmcAlarmTests`）。
//

import XCTest
import Foundation
@testable import ZhishengWeather

// MARK: - 桩

/// `QWeatherProviding` 的测试桩（逐日与逐时**各自独立**控制成败/空数据）。
///
/// 🔴 逐日与逐时分开存错误，是为了能造出**最难发现的那种真机情形**：
///   「逐日 200 + 逐时 401」→ 卡片必须分区显示，而不是整卡变成「取不到」。
///
    /// ⚠️ 错误存 **`WeatherError?`** 而不是 `Result<T, Error>`：协议要求 `Sendable`，
    ///   而 `Result<T, Error>` 里的 `Error` 存在类型**不是** `Sendable`
    ///   （与 `StubTyphoonProviding` 同款处置）。
private struct StubQWeatherProviding: QWeatherProviding {
    let dailyForecast: QWeatherDailyForecast?
    let dailyError: WeatherError?
    let hourlyForecast: QWeatherHourlyForecast?
    let hourlyError: WeatherError?

    func fetchDaily(latitude: Double,
                    longitude: Double,
                    days: Int) async throws -> QWeatherDailyForecast {
        if let dailyError { throw dailyError }
        guard let dailyForecast else {
            throw WeatherError.dataMissing("测试桩未提供逐日样本")
        }
        return dailyForecast
    }

    func fetchHourly(latitude: Double,
                     longitude: Double,
                     hours: Int) async throws -> QWeatherHourlyForecast {
        if let hourlyError { throw hourlyError }
        guard let hourlyForecast else {
            throw WeatherError.dataMissing("测试桩未提供逐时样本")
        }
        return hourlyForecast
    }
}

final class QWeatherHourlyTests: XCTestCase {

    // MARK: - 实测样本（2026-10-09 逐字形态）

    /// 🔴 实测形态：`metadata` + **`hours`**（**不是 `hourly`**），
    /// 单条 13 键齐全。`humidity = 0.33`（小数）、`cloudCover = 0`、
    /// 降水概率在 `precipitation.probability`（顶层**无** `precipProbability`）。
    ///
    /// ⚠️ 用 `#"""…"""#`（**raw** 多行串）：里面的 `°C`、反斜杠都按字面处理，
    /// 不会被当转义序列（`NmcTyphoonTests` 记录过这个坑）。
    private static let hourlyJSON = #"""
    {"metadata":{"tag":"_testtag_","attributions":["https://example.com/qweather"]},
     "hours":[
       {"forecastTime":"2026-10-08T15:00Z",
        "temperature":{"value":26.01,"unit":"°C"},
        "feelsLike":{"value":27.4,"unit":"°C"},
        "humidity":0.33,
        "cloudCover":0,
        "precipitation":{"amount":{"value":0,"unit":"mm"},
                         "intensity":{"value":0,"unit":"mm/h"},
                         "type":"none","probability":0},
        "pressure":{"value":1013.25,"unit":"hPa"},
        "visibility":{"value":24.0,"unit":"km"},
        "wind":{"direction":{"degree":180,"compass":"s"},
                "speed":{"value":2.6,"unit":"m/s"},"scale":2},
        "windGust":{"value":5.1,"unit":"m/s"},
        "condition":{"text":"多云","code":"103"},
        "dewPoint":{"value":14.2,"unit":"°C"},
        "uvIndex":3},
       {"forecastTime":"2026-10-08T16:00Z",
        "temperature":{"value":25.10,"unit":"°C"},
        "feelsLike":{"value":26.0,"unit":"°C"},
        "humidity":0.41,
        "cloudCover":0.25,
        "precipitation":{"amount":{"value":0.6,"unit":"mm"},
                         "intensity":{"value":1.2,"unit":"mm/h"},
                         "type":"rain","probability":0.72},
        "pressure":{"value":1012.80,"unit":"hPa"},
        "visibility":{"value":18.5,"unit":"km"},
        "wind":{"direction":{"degree":200,"compass":"ssw"},
                "speed":{"value":3.4,"unit":"m/s"},"scale":3},
        "windGust":{"value":7.2,"unit":"m/s"},
        "condition":{"text":"小雨","code":"305"},
        "dewPoint":{"value":13.8,"unit":"°C"},
        "uvIndex":2}
     ]}
    """#

    /// 🔴 顶层键写成 **`hourly`**（错误键名）的载荷 —— 用于证明「写错不报错，
    /// 只会静默变成无数据」，并让 `hours` 键那条断言形成对照。
    private static let wrongTopLevelKeyJSON = #"""
    {"metadata":{"attributions":["https://example.com/qweather"]},
     "hourly":[{"forecastTime":"2026-10-08T15:00Z",
                "temperature":{"value":26.01,"unit":"°C"},
                "humidity":0.33}]}
    """#

    /// 🔴 **只有** `metadata` + 一个空对象 `{}` —— 13 个键**一个都没有**。
    /// 用于钉死「字段缺失不抛错」（P-18）。
    private static let emptyHourEntryJSON = #"""
    {"metadata":{"tag":"_t_","attributions":["https://example.com/qweather"]},
     "hours":[{}]}
    """#

    /// 整条是 `null` 的数组元素 + 一个正常对象 —— 钉死「一个 null 不让整包失败」。
    private static let nullElementJSON = #"""
    {"hours":[null,
              {"forecastTime":"2026-10-08T15:00Z",
               "temperature":{"value":26.01,"unit":"°C"}}]}
    """#

    /// 越界分数载荷：`humidity = 33`（**百分数**形态，落在 `[0,1]` 之外）。
    private static let outOfRangeJSON = #"""
    {"hours":[{"humidity":33,"cloudCover":100,
               "precipitation":{"probability":88}}]}
    """#

    // MARK: - ① 顶层键是 `hours`，**不是** `hourly`

    /// 🔴🔴 顶层键逐字是 **`hours`**（实测；端点路径里的 `hourly` 是**路径段**）。
    ///
    /// 这条是本文件**最重要**的断言：写错**不会**编译失败、**不会**运行时报错，
    /// 只会让 `hours` 变成 nil → 整源静默显示「上游未下发逐时预报」。
    func testTopLevelKeyIsHoursNotHourly() throws {
        let data = Data(Self.hourlyJSON.utf8)
        let decoded = try ResponseDecoding.decode(QWeatherHourlyResponse.self, from: data)
        let mapped = QWeatherMapper.mapHourly(decoded)

        XCTAssertEqual(mapped.hours.count, 2,
                       "顶层键 `hours` 必须能解出 2 条 —— 若这里为 0，"
                       + "几乎一定是把 DTO 写成了 `hourly`（实测顶层键是 `hours`）")
        XCTAssertFalse(mapped.isEffectivelyEmpty)
    }

    /// 反向对照：顶层键真写成 `hourly` 时**不报错，但解不出任何小时**。
    ///
    /// ⚠️ 这条断言的价值在于**把静默失败显式化**：
    /// 若哪天有人把 DTO 字段名同步改成 `hourly`，上一条会红；
    /// 而这条会告诉你**为什么**红（而不是让你去查解码器）。
    func testWrongTopLevelKeyDecodesToEmptyWithoutThrowing() throws {
        let data = Data(Self.wrongTopLevelKeyJSON.utf8)
        // 🔴 刻意断言「**不抛错**」：这正是它危险的地方（静默）。
        let decoded = try ResponseDecoding.decode(QWeatherHourlyResponse.self, from: data)
        XCTAssertNil(decoded.hours,
                     "载荷里是 `hourly`，按 `hours` 取必然为 nil")
        let mapped = QWeatherMapper.mapHourly(decoded)
        XCTAssertTrue(mapped.isEffectivelyEmpty,
                      "错误键名 → 空序列（合法「无数据」，但**不是**我们真拿到的东西）")
        // 关键：署名**仍然**被带回（合规义务不因无数据而消失）。
        XCTAssertEqual(mapped.attributions, ["https://example.com/qweather"],
                       "即使无数据，署名也必须带回（官方要求「与数据共同显示」）")
    }

    // MARK: - ② `humidity = 0.33` 是小数，不是 33

    /// 🔴 实测 `humidity = 0.33` → 领域模型里必须**原样**是 `0.33`。
    ///
    /// 防的是两种「顺手改成百分数」：
    /// ① 在 mapper 里 ×100 存进 `humidityFraction`（那会让渲染层再 ×100 → 3300%）；
    /// ② 觉得「0.33 不像湿度」而改成 33（那会**越过 `[0,1]` 上界**
    ///    → 被铁律①判为异常 → nil → UI 显示「暂无」，湿度直接消失）。
    /// ⚠️ `@MainActor`：`QWeatherCard` 是 `@MainActor` 类型，其 `static func`
    ///   一律主actor 隔离 → 从非隔离上下文调用是**编译错误**（不是警告）。
    @MainActor
    func testHumidityIsFractionNotPercent() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherHourlyResponse.self, from: Data(Self.hourlyJSON.utf8))
        let mapped = QWeatherMapper.mapHourly(decoded)
        let first = try XCTUnwrap(mapped.hours.first)
        // ⚠️ 先求值到局部常量再断言（`XCTAssert*` 实参是 autoclosure）。
        let fraction = try XCTUnwrap(first.humidityFraction)

        XCTAssertEqual(fraction, 0.33, accuracy: 1e-9,
                       "实测 `humidity = 0.33` 是 [0,1] 小数，领域模型必须原样保留 0.33；"
                       + "若这里被改成 33，那是**量纲事故**（上游是 0.33，不是 33）")
        XCTAssertNotEqual(fraction, 33,
                          "绝不能是 33 —— 上游实测就是 0.33")
        // 双向确认：`0.33` 经 ×100 后应是「33%」，即渲染层拿到的是 33 那一侧。
        XCTAssertEqual(QWeatherCard.fractionText(fraction), "33%",
                       "[0,1] → 百分比是渲染层唯一该做的换算（×100）")
    }

    /// `cloudCover` 同款：`0` 是**合法读数**，且落在 `[0,1]`。
    ///
    /// ⚠️ `@MainActor`：理由同 `testHumidityIsFractionNotPercent`。
    @MainActor
    func testCloudCoverZeroIsAValidReadingNotMissing() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherHourlyResponse.self, from: Data(Self.hourlyJSON.utf8))
        let mapped = QWeatherMapper.mapHourly(decoded)
        let first = try XCTUnwrap(mapped.hours.first)
        let cover = try XCTUnwrap(first.cloudCoverFraction)

        // 🔴 `nil` 与 `0` 必须可区分：实测云量确实是 0（晴/少云），
        // 那是**真实读数**，渲染成「暂无」等于凭空说「没查到」。
        XCTAssertEqual(cover, 0, accuracy: 1e-9, "实测 `cloudCover = 0`，不是缺测")
        XCTAssertEqual(QWeatherCard.fractionText(cover), "0%")
    }

    /// 降水概率在**`precipitation.probability`**（顶层**不存在** `precipProbability`）。
    ///
    /// ⚠️ 防的是「照着官方文档/别的源的习惯」去读顶层 `precipProbability`
    /// —— 那个键**实测不存在**，读了会永远 nil（降水概率整列消失）。
    ///
    /// ⚠️ `@MainActor`：理由同 `testHumidityIsFractionNotPercent`。
    @MainActor
    func testPrecipitationProbabilityLivesUnderPrecipitation() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherHourlyResponse.self, from: Data(Self.hourlyJSON.utf8))
        let mapped = QWeatherMapper.mapHourly(decoded)
        let second = try XCTUnwrap(mapped.hours.last)

        let probability = try XCTUnwrap(
            second.precipitation?.probability,
            "降水概率必须在 `precipitation.probability`（实测 0.72）；"
            + "顶层**不存在** `precipProbability`")
        XCTAssertEqual(probability, 0.72, accuracy: 1e-9,
                       "概率同样是 [0,1] 小数（0.72 = 72%），不是 72")
        XCTAssertEqual(QWeatherCard.fractionText(probability), "72%")

        // 降水量与类型也在同一块里。
        XCTAssertEqual(second.precipitation?.amount?.value ?? -1, 0.6, accuracy: 1e-9)
        XCTAssertEqual(second.precipitation?.type, "rain")
    }

    // MARK: - ③ 字段缺失不抛错（P-18）

    /// 🔴 13 个键**一个都没有**（`{}`）→ **绝不抛错**，逐项为 nil。
    ///
    /// 这是 P-18 的直接对策：非可选字段会让合成解码器抛 `keyNotFound`
    /// → **整包失败 → 整个源静默消失**（卡片空白、无提示）。
    func testMissingFieldsDoNotThrow() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherHourlyResponse.self, from: Data(Self.emptyHourEntryJSON.utf8))
        let mapped = QWeatherMapper.mapHourly(decoded)

        // 上游确实下发了「一小时」→ **不是**无数据，应如实展示。
        XCTAssertFalse(mapped.isEffectivelyEmpty,
                       "下发了一个（空）条目就算有数据 —— 字段空 ≠ 没数据")
        let hour = try XCTUnwrap(mapped.hours.first)
        XCTAssertNil(hour.forecastTime)
        XCTAssertNil(hour.temperature)
        XCTAssertNil(hour.feelsLike)
        XCTAssertNil(hour.humidityFraction)
        XCTAssertNil(hour.cloudCoverFraction)
        XCTAssertNil(hour.precipitation)
        XCTAssertNil(hour.pressure)
        XCTAssertNil(hour.visibility)
        XCTAssertNil(hour.wind)
        XCTAssertNil(hour.windGust)
        XCTAssertNil(hour.condition)
        XCTAssertNil(hour.dewPoint)
        XCTAssertNil(hour.uvIndex)
    }

    /// 顶层 `hours` 整键缺失 → 不抛错，判为「无数据」。
    func testMissingHoursKeyIsEmptyNotThrow() throws {
        let json = #"{"metadata":{"tag":"_t_"}}"#
        let decoded = try ResponseDecoding.decode(
            QWeatherHourlyResponse.self, from: Data(json.utf8))
        let mapped = QWeatherMapper.mapHourly(decoded)
        XCTAssertTrue(mapped.isEffectivelyEmpty)
        XCTAssertEqual(mapped.hours.count, 0)
    }

    /// 空数组 → 合法「无数据」，**不是**故障。
    func testEmptyHoursArrayIsNoData() throws {
        let json = #"{"hours":[]}"#
        let decoded = try ResponseDecoding.decode(
            QWeatherHourlyResponse.self, from: Data(json.utf8))
        let mapped = QWeatherMapper.mapHourly(decoded)
        XCTAssertTrue(mapped.isEffectivelyEmpty,
                      "空数组是**合法响应**（`.noData`），不是取不到（`.unavailable`）")
    }

    /// 数组里有 `null` 元素 → 丢弃该元素，**保住其余数据**。
    ///
    /// ⚠️ 理由同 `MarineFloodSourcesTests` 记录的真机形态：上游会「静默给 null」。
    ///   若 DTO 声明 `[Hour]`，一个 null 就会让**整个数组**解码失败。
    func testNullElementIsDroppedButOthersSurvive() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherHourlyResponse.self, from: Data(Self.nullElementJSON.utf8))
        let mapped = QWeatherMapper.mapHourly(decoded)
        XCTAssertEqual(mapped.hours.count, 1,
                       "null 元素应被丢弃，其余条目必须保住（P-18：绝不为一个元素牺牲整包）")
        XCTAssertEqual(mapped.hours.first?.temperature?.value ?? -1, 26.01, accuracy: 1e-9)
    }

    // MARK: - ④ `windGust` vs `windGustMax`

    /// 逐时键名逐字是 **`windGust`**（**不是**逐日的 `windGustMax`）。
    ///
    /// ⚠️ 写错**不会**编译失败（属性名与 JSON 键自动对应），
    /// 只会让阵风永远解不出 → 整列「暂无」，且没有任何报错。
    func testHourlyUsesWindGustKeyNotWindGustMax() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherHourlyResponse.self, from: Data(Self.hourlyJSON.utf8))
        let mapped = QWeatherMapper.mapHourly(decoded)
        let first = try XCTUnwrap(mapped.hours.first)

        let gust = try XCTUnwrap(first.windGust?.value,
                                 "实测载荷里的键是 `windGust`（逐时= 瞬时阵风）；"
                                 + "若解不出，多半被错写成了逐日的 `windGustMax`")
        XCTAssertEqual(gust, 5.1, accuracy: 1e-9)
        XCTAssertEqual(first.windGust?.unit, "m/s")
    }

    // MARK: - ⑤ 越界分数 → nil（绝不 clamp）

    /// `humidity = 33`（百分数形态）→ **判为异常 → nil**，**绝不** clamp 成 1.0。
    ///
    /// clamp 会把「上游返回了 33」悄悄变成「湿度 1%」/「云量 100%」——
    /// 那是**把一个错误变成另一个错误**，比显示「暂无」坏得多。
    func testOutOfRangeFractionsBecomeNilNotClamped() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherHourlyResponse.self, from: Data(Self.outOfRangeJSON.utf8))
        let hour = try XCTUnwrap(QWeatherMapper.mapHourly(decoded).hours.first)

        XCTAssertNil(hour.humidityFraction, "33 越界 → nil，**不可** clamp 成 1.0")
        XCTAssertNil(hour.cloudCoverFraction, "100 越界 → nil，**不可** clamp 成 1.0")
        XCTAssertNil(hour.precipitation?.probability, "88 越界 → nil，**不可** clamp 成 1.0")

        // 越界事实必须**可被观测**（否则「变成了 nil」就悄悄消失了）。
        let findings = QWeatherMapper.outOfRangeDiagnostics(decoded)
        XCTAssertFalse(findings.isEmpty,
                       "越界事实必须留在诊断里，供真机核验「上游是否改了量纲」")
    }

    /// 正常量纲下诊断表必须为空（防「永远非空」把守卫变成恒真）。
    func testDiagnosticsAreEmptyForValidFixtures() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherHourlyResponse.self, from: Data(Self.hourlyJSON.utf8))
        XCTAssertTrue(QWeatherMapper.outOfRangeDiagnostics(decoded).isEmpty,
                      "实测载荷全部落在 [0,1]，诊断表应为空")
    }

    // MARK: - ⑥ 标识唯一性（ForEach 的地基）

    /// `sequenceIndex` 必须唯一且连续（`Identifiable` 的地基）。
    ///
    /// ⚠️ 刻意**不用** `forecastTime` 当 id：官方**未承诺**它唯一、它也可能缺失
    /// → `ForEach` 拿到重复 id 会静默错渲。
    func testSequenceIndexIsUniqueAndDense() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherHourlyResponse.self, from: Data(Self.hourlyJSON.utf8))
        let mapped = QWeatherMapper.mapHourly(decoded)
        let identifiers = mapped.hours.map(\.id)
        XCTAssertEqual(identifiers, Array(0..<mapped.hours.count))
        XCTAssertEqual(Set(identifiers).count, identifiers.count, "id 必须唯一")
    }

    // MARK: - 端点形态

    /// 端点逐字：`/weather/v1/hourly/{lat}/{lon}?hours=24&lang=zh`。
    func testHourlyURLPathAndQuery() throws {
        let url = try XCTUnwrap(QWeatherEndpoint.hourlyURL(
            apiHost: "abcdefg.qweatherapi.com",
            latitude: 39.9042,
            longitude: 116.4074))
        XCTAssertEqual(url.scheme, "https", "和风是 HTTPS-only")
        XCTAssertEqual(url.host, "abcdefg.qweatherapi.com")
        XCTAssertEqual(url.path, "/weather/v1/hourly/39.9/116.41",
                       "🔴 路径段是 `hourly`（不是 `hours`）；坐标保留两位小数")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems)
        let pairs = Dictionary(items.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
        XCTAssertEqual(pairs["hours"], "24")
        XCTAssertEqual(pairs["lang"], "zh")
    }

    /// 默认 `hours` 逐字是 **24**（产品取舍，官方上限是 360）。
    func testDefaultHoursIsTwentyFour() {
        XCTAssertEqual(QWeatherEndpoint.defaultHours, 24)
        XCTAssertEqual(QWeatherEndpoint.hoursRange.upperBound, 360,
                       "官方文档：`hours` 上限 360")
    }

    /// 🔴 `hours` 越界 → **URL 为 nil**，**绝不**静默改成 24。
    ///
    /// 静默改成一个「看起来对但完全错」的小时数，比明确报错坏得多。
    func testOutOfRangeHoursYieldsNilURL() {
        XCTAssertNil(QWeatherEndpoint.hourlyURL(apiHost: "h.qweatherapi.com",
                                                 latitude: 39.9, longitude: 116.4, hours: 0),
                     "0 越界 → nil")
        XCTAssertNil(QWeatherEndpoint.hourlyURL(apiHost: "h.qweatherapi.com",
                                                 latitude: 39.9, longitude: 116.4, hours: -1),
                     "负数越界 → nil")
        XCTAssertNil(QWeatherEndpoint.hourlyURL(apiHost: "h.qweatherapi.com",
                                                 latitude: 39.9, longitude: 116.4, hours: 361),
                     "361 越过官方上限 360 → nil")
        // 边界值必须**放行**（1 与 360 都合法）。
        XCTAssertNotNil(QWeatherEndpoint.hourlyURL(apiHost: "h.qweatherapi.com",
                                                    latitude: 39.9, longitude: 116.4, hours: 1))
        XCTAssertNotNil(QWeatherEndpoint.hourlyURL(apiHost: "h.qweatherapi.com",
                                                    latitude: 39.9, longitude: 116.4, hours: 360))
    }

    /// Host 规范化沿用逐日那套（容忍带 `https://` / 带尾斜杠的粘贴）。
    func testHostNormalizationIsSharedWithDaily() throws {
        let url = try XCTUnwrap(QWeatherEndpoint.hourlyURL(
            apiHost: "https://AbcDef.qweatherapi.com/",
            latitude: 39.9, longitude: 116.4))
        XCTAssertEqual(url.host, "abcdef.qweatherapi.com", "主机名统一小写")
        XCTAssertNil(QWeatherEndpoint.hourlyURL(apiHost: "  ", latitude: 39.9, longitude: 116.4),
                     "空 Host → nil")
        XCTAssertNil(QWeatherEndpoint.hourlyURL(apiHost: "http://h.qweatherapi.com",
                                                 latitude: 39.9, longitude: 116.4),
                     "显式 http → nil（凭据不得明文发送）")
    }

    /// 坐标非法 → nil（NaN / 越界）。逐时与逐日同一判据。
    func testInvalidCoordinateYieldsNilURL() {
        XCTAssertNil(QWeatherEndpoint.hourlyURL(apiHost: "h.qweatherapi.com",
                                                 latitude: .nan, longitude: 116.4))
        XCTAssertNil(QWeatherEndpoint.hourlyURL(apiHost: "h.qweatherapi.com",
                                                 latitude: 39.9, longitude: 181))
    }

    // MARK: - 卡片状态机（④ 态分离）

    /// 逐时下发数据 → `.available`，序列可读。
    @MainActor
    func testHourlyAvailableState() async throws {
        let service = StubQWeatherProviding(
            dailyForecast: Self.sampleDailyForecast, dailyError: nil,
            hourlyForecast: try Self.sampleHourlyForecast(), hourlyError: nil)
        let model = QWeatherCardModel(service: service)
        await model.load(latitude: 39.9, longitude: 116.4)

        XCTAssertEqual(model.hourlyState, .available)
        XCTAssertEqual(model.hours.count, 2)
        XCTAssertEqual(model.hours.first?.temperature?.value ?? -1, 26.01, accuracy: 1e-9)
    }

    /// 🔴 逐时**空数组** → `.noData`（**查了、没有**），**不是** `.unavailable`。
    @MainActor
    func testHourlyEmptyIsNoDataNotUnavailable() async {
        let service = StubQWeatherProviding(
            dailyForecast: Self.sampleDailyForecast, dailyError: nil,
            hourlyForecast: QWeatherHourlyForecast(attributions: [], tag: nil, hours: []),
            hourlyError: nil)
        let model = QWeatherCardModel(service: service)
        await model.load(latitude: 39.9, longitude: 116.4)

        // 🔴 与 `.unavailable` **必须是两个状态** ——把「上游没给」显示成
        //   「取不到」，用户会去查网络，而问题在上游。
        XCTAssertEqual(model.hourlyState, .noData)
        XCTAssertNotEqual(model.hourlyState, .unavailable(""))
    }

    /// 逐时取不到 → `.unavailable`，且**不**落成 `.noData`。
    @MainActor
    func testHourlyFailureIsUnavailableNotNoData() async {
        let service = StubQWeatherProviding(
            dailyForecast: Self.sampleDailyForecast, dailyError: nil,
            hourlyForecast: nil, hourlyError: WeatherError.network("断网"))
        let model = QWeatherCardModel(service: service)
        await model.load(latitude: 39.9, longitude: 116.4)

        guard case .unavailable = model.hourlyState else {
            return XCTFail("取不到必须是 .unavailable（否则会被显示成「上游没给数据」）")
        }
    }

    /// 🔴🔴 **逐时失败不得拖累逐日**（两条链路是两个独立失败域）。
    ///
    /// 真机上是常见情形：同一凭据下逐日 200、逐时 401（套餐无逐时权限）。
    /// 若压成单一状态，用户会把**整个源**关掉，而其实逐日是好的。
    @MainActor
    func testHourlyFailureDoesNotBreakDaily() async {
        let service = StubQWeatherProviding(
            dailyForecast: Self.sampleDailyForecast, dailyError: nil,
            hourlyForecast: nil, hourlyError: WeatherError.badStatus(401))
        let model = QWeatherCardModel(service: service)
        await model.load(latitude: 39.9, longitude: 116.4)

        XCTAssertEqual(model.state, .available, "逐日必须照常可用")
        XCTAssertEqual(model.days.count, 1)
        guard case .unavailable = model.hourlyState else {
            return XCTFail("逐时应是 .unavailable")
        }
    }

    /// 反向：逐日失败**不得**影响逐时（对称，防只测了一半）。
    @MainActor
    func testDailyFailureDoesNotBreakHourly() async throws {
        let service = StubQWeatherProviding(
            dailyForecast: nil, dailyError: WeatherError.badStatus(403),
            hourlyForecast: try Self.sampleHourlyForecast(), hourlyError: nil)
        let model = QWeatherCardModel(service: service)
        await model.load(latitude: 39.9, longitude: 116.4)

        XCTAssertEqual(model.hourlyState, .available, "逐时必须照常可用")
        XCTAssertEqual(model.hours.count, 2)
        guard case .unavailable = model.state else {
            return XCTFail("逐日应是 .unavailable")
        }
    }

    /// 🔴 401 与 403 的**人话文案必须不同**（处置完全不同：重签 vs 改配置）。
    @MainActor
    func testAuthenticationHintsDifferFor401And403() {
        let unauthorized = QWeatherCardModel.describe(WeatherError.badStatus(401))
        let forbidden = QWeatherCardModel.describe(WeatherError.badStatus(403))
        XCTAssertNotEqual(unauthorized, forbidden,
                          "401（可重签自愈）与 403（必须改配置）不能同一句文案")
        XCTAssertTrue(unauthorized.contains("401"))
        XCTAssertTrue(forbidden.contains("403"))
    }

    // MARK: - 署名（许可条件）

    /// 🔴 逐日 + 逐时两份 `attributions` → **并集去重**（页脚只渲染一处）。
    ///
    /// 和风官方明文：「必须与当前数据共同显示」= **许可条件**。
    /// 漏渲染 = 违反许可条件（比少一个 UI 元素严重得多）；
    /// 重复渲染两遍同一串链接会让用户以为出了bug，故去重。
    @MainActor
    func testAttributionsAreUnionedAndDeduplicated() async throws {
        let daily = QWeatherDailyForecast(
            attributions: ["https://example.com/a", "https://example.com/shared"],
            tag: nil,
            days: [])
        let hourly = QWeatherHourlyForecast(
            attributions: ["https://example.com/shared", "https://example.com/b"],
            tag: nil,
            hours: [])
        let service = StubQWeatherProviding(
            dailyForecast: daily, dailyError: nil,
            hourlyForecast: hourly, hourlyError: nil)
        let model = QWeatherCardModel(service: service)
        await model.load(latitude: 39.9, longitude: 116.4)

        XCTAssertEqual(model.attributions,
                       ["https://example.com/a",
                        "https://example.com/shared",
                        "https://example.com/b"],
                       "并集 + 去重 + 逐日在前；**任一端点带来的署名都不许丢**")
    }

    /// 逐时**失败**时，逐日已取到的署名**仍要**保留（页脚无条件渲染）。
    @MainActor
    func testAttributionsSurviveWhenHourlyFails() async {
        let daily = QWeatherDailyForecast(
            attributions: ["https://example.com/qweather"], tag: nil, days: [])
        let service = StubQWeatherProviding(
            dailyForecast: daily, dailyError: nil,
            hourlyForecast: nil, hourlyError: WeatherError.network("断网"))
        let model = QWeatherCardModel(service: service)
        await model.load(latitude: 39.9, longitude: 116.4)

        XCTAssertEqual(model.attributions, ["https://example.com/qweather"],
                       "逐时失败**不得**抹掉逐日取到的署名（合规义务与数据是否取到无关）")
    }

    // MARK: - 渲染格式化（纯函数）

    /// 时刻文本：`forecastTime` 是 **UTC**，必须按传入时区渲染。
    @MainActor
    func testHourTextRendersInGivenTimeZone() {
        let hour = QWeatherHour(sequenceIndex: 0,
                                forecastTime: "2026-10-08T15:00Z",
                                temperature: nil, feelsLike: nil,
                                humidityFraction: nil, cloudCoverFraction: nil,
                                precipitation: nil, pressure: nil, visibility: nil,
                                wind: nil, windGust: nil, condition: nil,
                                dewPoint: nil, uvIndex: nil)
        let beijing = try? XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let utc = try? XCTUnwrap(TimeZone(identifier: "UTC"))

        let beijingText = QWeatherHourlyCard.hourText(hour, timeZone: beijing ?? .current)
        let utcText = QWeatherHourlyCard.hourText(hour, timeZone: utc ?? .current)
        XCTAssertEqual(beijingText, "23:00", "UTC 15:00 → 北京 23:00")
        XCTAssertEqual(utcText, "15:00", "UTC 15:00 → UTC 15:00")
    }

    /// 时刻**解析不了** → 如实退回原始串，**绝不**空白或编造。
    @MainActor
    func testHourTextFallsBackToRawStringOnParseFailure() {
        let broken = QWeatherHour(sequenceIndex: 0,
                                  forecastTime: "不是时间",
                                  temperature: nil, feelsLike: nil,
                                  humidityFraction: nil, cloudCoverFraction: nil,
                                  precipitation: nil, pressure: nil, visibility: nil,
                                  wind: nil, windGust: nil, condition: nil,
                                  dewPoint: nil, uvIndex: nil)
        XCTAssertEqual(QWeatherHourlyCard.hourText(broken, timeZone: .current), "不是时间",
                       "解析失败 → 显示上游原文（仍是有用信息），不假装成合法时刻")
    }

    /// 缺测 vs 零值：温度缺测 → 「暂无」，**不用 0 顶替**。
    @MainActor
    func testTemperatureAndProbabilityDistinguishMissingFromZero() {
        let missing = QWeatherHour(sequenceIndex: 0, forecastTime: nil,
                                   temperature: nil, feelsLike: nil,
                                   humidityFraction: nil, cloudCoverFraction: nil,
                                   precipitation: nil, pressure: nil, visibility: nil,
                                   wind: nil, windGust: nil, condition: nil,
                                   dewPoint: nil, uvIndex: nil)
        XCTAssertEqual(QWeatherHourlyCard.temperatureText(missing), "暂无")
        XCTAssertEqual(QWeatherHourlyCard.precipitationText(missing), "暂无",
                       "`nil` → 「暂无」，**绝不**显示 0%（那是凭空造一条读数）")

        // 0 是**合法读数** → 照实显示。
        let zero = QWeatherHour(sequenceIndex: 0, forecastTime: nil,
                                temperature: QWeatherQuantity(value: 0, unit: "°C"),
                                feelsLike: nil,
                                humidityFraction: 0, cloudCoverFraction: 0,
                                precipitation: QWeatherPrecipitation(
                                    amount: QWeatherQuantity(value: 0, unit: "mm"),
                                    probability: 0, type: "none"),
                                pressure: nil, visibility: nil,
                                wind: nil, windGust: nil, condition: nil,
                                dewPoint: nil, uvIndex: nil)
        XCTAssertEqual(QWeatherHourlyCard.temperatureText(zero), "0.0°")
        XCTAssertEqual(QWeatherHourlyCard.precipitationText(zero), "0%",
                       "实测 `probability = 0` 是真值 → 照实显示 0%")
    }

    // MARK: - 能力登记

    /// 逐时能力必须**已登记**（未接即不声明；已接就必须声明）。
    func testHourlyCapabilityIsRegistered() {
        XCTAssertTrue(SourceCapability.allCases.contains(.qWeatherHourlyForecast),
                      "逐时已接入 → 必须声明该能力（漏登记 = 静默哑火）")
        let descriptor = SourceDirectory.descriptor(for: .qWeather)
        XCTAssertNotNil(descriptor, "和风源必须在源目录里登记")
        XCTAssertTrue(descriptor?.capabilities.contains(.qWeatherHourlyForecast) == true,
                      "`.qWeather` 的能力集必须含逐时")
        XCTAssertTrue(descriptor?.capabilities.contains(.qWeatherDailyForecast) == true,
                      "逐时是**新增**能力，逐日那条**不许被挤掉**")
    }

    /// 🔴 逐时**不得**复用 `.hourlyForecast`（虚报能力 + 量纲事故）。
    func testHourlyDoesNotReuseGenericHourlyCapability() {
        let descriptor = SourceDirectory.descriptor(for: .qWeather)
        XCTAssertFalse(descriptor?.capabilities.contains(.hourlyForecast) == true,
                       "`.hourlyForecast` 隐含既有逐时域的裸标量，"
                       + "和风逐时是量纲对象 + [0,1] 分数 → 复用即虚报能力")
    }

    /// 能力集变化后，署名文案里**必须**看得见逐时（不能落到兜底文案）。
    ///
    /// ⚠️ `DataAttribution.capabilityText` 对未知能力返回「（未命名能力）」——
    ///   若只加了枚举 case 而没补文案，设置页会显示「（未命名能力）」，
    ///   用户看到的是**一个说不清是什么的条目**。这条断言就是钉住那个缺口。
    func testHourlyCapabilityHasUserFacingText() {
        let text = DataAttribution.capabilityText(.qWeatherHourlyForecast)
        XCTAssertNotEqual(text, "（未命名能力）",
                          "新能力必须补上用户可读文案，否则设置页显示「（未命名能力）」")
        XCTAssertFalse(text.isEmpty)
    }

    // MARK: - 私有样本构造

    /// 一条最小逐日领域模型（只为让逐日链路「成功」）。
    private static var sampleDailyForecast: QWeatherDailyForecast {
        QWeatherDailyForecast(attributions: [], tag: nil, days: [
            QWeatherDay(sequenceIndex: 0,
                        forecastStartTime: "2026-10-08T16:00Z",
                        forecastEndTime: "2026-10-09T16:00Z",
                        astro: nil,
                        temperatureMax: QWeatherQuantity(value: 27.0, unit: "°C"),
                        temperatureMin: QWeatherQuantity(value: 15.0, unit: "°C"),
                        temperatureAvg: nil, uvIndexMax: nil,
                        daytime: nil, nighttime: nil)
        ])
    }

    /// 由实测 JSON 走完整链路得到的逐时领域模型（供状态机测试复用）。
    private static func sampleHourlyForecast() throws -> QWeatherHourlyForecast {
        let decoded = try ResponseDecoding.decode(
            QWeatherHourlyResponse.self, from: Data(hourlyJSON.utf8))
        return QWeatherMapper.mapHourly(decoded)
    }
}

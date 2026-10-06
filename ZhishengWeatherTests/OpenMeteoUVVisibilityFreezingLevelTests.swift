//
//  OpenMeteoUVVisibilityFreezingLevelTests.swift
//  ZhishengWeatherTests
//
//  P2 · AC-B17c（逐时 uv_index / visibility / freezing_level_height）单测。
//
//  ── 为什么有这份文件（防的是本仓最严重的一类事故）──
//  Open-Meteo 存在「变量在全局词表里存在、但某端点/部署不支持」的行为：
//  此时它返回 **HTTP 200 但静默省略整个键**。若 DTO 把该字段声明成**非可选**，
//  合成解码器会抛 `DecodingError` → **整包解码失败** → 主屏与小组件**同时无数据**
//  （Core 被两个 target 共用）。本仓已因"截断日 null 元素"真实发生过一次全 App 无数据。
//
//  故本文件的第一组用例就是那道**回归守卫**：
//  「构造一份**三个新键全部缺失**的响应体，断言整包解码仍然成功、且既有字段完好」。
//  将来谁把字段改成非可选，这条用例会立刻变红。
//
//  覆盖：
//   ① 端点：三个变量名出现在 hourly 参数里，且仍**只有一个** hourly（配额 ×1）；
//   ② DTO：三键缺失 / 三键为 null 元素 → 整包解码成功；
//   ③ mapper：新字段真的落到 `HourlyPoint`（**接线守卫**，防"哑火线"）；
//   ④ `0` 与缺失严格区分（UV 0 是合法夜间值，绝不当 nil）；
//   ⑤ 旧缓存兼容：不含新键的旧 JSON 解码成功且新字段全 nil。
//

import XCTest
@testable import ZhishengWeather

final class OpenMeteoUVVisibilityFreezingLevelTests: XCTestCase {

    private let baseEpoch = 1_700_000_000

    // MARK: - ① 端点参数面

    func testEndpointHourlyContainsNewFields() throws {
        let url = try XCTUnwrap(OpenMeteoEndpoint.url(latitude: 0, longitude: 0))
        let hourly = try XCTUnwrap(try queryItems(url)["hourly"])
        let fields = hourly.split(separator: ",").map(String.init)
        for field in ["uv_index", "visibility", "freezing_level_height"] {
            XCTAssertTrue(fields.contains(field), "hourly 缺少新字段 \(field)，实际=\(hourly)")
        }
    }

    /// 加字段**不新增请求**：hourly 只出现一次、端点仍是同一个 URL（R-Q2 纪律）。
    func testEndpointKeepsSingleRequest() throws {
        let url = try XCTUnwrap(OpenMeteoEndpoint.url(latitude: 0, longitude: 0))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(items.filter { $0.name == "hourly" }.count, 1,
                       "仍只有一条 hourly 请求（Open-Meteo 配额计数不得 ×2）")
        XCTAssertTrue(url.absoluteString.hasPrefix(OpenMeteoEndpoint.baseURLString),
                      "端点 URL 不得变更")
    }

    // MARK: - ② DTO：三键缺失 / 元素为 null → 整包解码仍成功（本批最高风险守卫）

    /// ⭐ 核心回归守卫：服务端**整键省略**三个新变量（HTTP 200 但静默缺键）时，
    /// 整包解码必须成功，且既有 hourly / daily 字段**完好无损**。
    /// 若有人把 `uv_index` / `visibility` / `freezing_level_height` 改成非可选，此用例变红。
    func testMissingNewKeysStillDecodeWholeResponse() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai",
          "utc_offset_seconds": 28800,
          "current": { "time": \(baseEpoch), "temperature_2m": 19.0, "relative_humidity_2m": 50,
                       "apparent_temperature": 18.0, "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1 },
          "hourly": { "time": [\(baseEpoch), \(baseEpoch + 3600)],
                      "temperature_2m": [20.0, 21.0],
                      "weather_code": [1, 1] },
          "daily": { "time": [\(baseEpoch)],
                     "temperature_2m_max": [27.0],
                     "temperature_2m_min": [17.0],
                     "weather_code": [2] }
        }
        """
        // 这一行若抛 DecodingError，测试即失败 —— 修复前全App 会无数据。
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))

        XCTAssertNil(dto.hourly.uv_index, "缺键 → nil")
        XCTAssertNil(dto.hourly.visibility)
        XCTAssertNil(dto.hourly.freezing_level_height)
        // 既有字段必须完好（证明"缺新键"没有牵连别的东西）。
        XCTAssertEqual(dto.hourly.temperature_2m.count, 2)
        XCTAssertEqual(dto.hourly.weather_code.count, 2)
        XCTAssertEqual(dto.current.temperature_2m, 19.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(dto.daily).temperature_2m_max.count, 1)

        // mapper 侧同样不得崩，且新字段全 nil（缺值绝不写 0）。
        let snapshot = OpenMeteoMapper.map(dto,
                                           location: .beijing,
                                           now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))
        XCTAssertEqual(snapshot.hourly.count, 2, "既有逐时点不受影响")
        XCTAssertNil(snapshot.hourly.first?.uvIndex)
        XCTAssertNil(snapshot.hourly.first?.visibility)
        XCTAssertNil(snapshot.hourly.first?.freezingLevelHeight)
        XCTAssertEqual(snapshot.temperature, 19.0, accuracy: 1e-9, "实况不受影响")
    }

    /// 键存在但**元素为 null**（v1.6 截断日形态）→ 解码成功、该点该字段 nil。
    func testNullElementsDecodeAndSkipOnlyThatField() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai",
          "utc_offset_seconds": 28800,
          "current": { "time": \(baseEpoch), "temperature_2m": 19.0, "relative_humidity_2m": 50,
                       "apparent_temperature": 18.0, "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1 },
          "hourly": { "time": [\(baseEpoch), \(baseEpoch + 3600), \(baseEpoch + 7200)],
                      "temperature_2m": [20.0, 21.0, 22.0],
                      "weather_code": [1, 1, 1],
                      "uv_index": [0.0, null, 4.9],
                      "visibility": [16740.0, null, 18480.0],
                      "freezing_level_height": [2690.0, null, 4010.0] }
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))

        let uv = try XCTUnwrap(dto.hourly.uv_index)
        XCTAssertEqual(uv.count, 3, "null 元素不计为缺项，长度仍为 3")
        XCTAssertEqual(try XCTUnwrap(uv[0]), 0.0, accuracy: 1e-9, "下标 0 为 0，是合法夜间值")
        XCTAssertNil(uv[1], "null → nil")
        XCTAssertEqual(try XCTUnwrap(uv[2]), 4.9, accuracy: 1e-9)

        let snapshot = OpenMeteoMapper.map(dto,
                                           location: .beijing,
                                           now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))
        XCTAssertEqual(snapshot.hourly.count, 3, "三行必需字段齐全 → 三点全保留")
        XCTAssertEqual(try XCTUnwrap(snapshot.hourly[0].uvIndex), 0.0, accuracy: 1e-9,
                       "UV 0 必须保留为 0，绝不当缺失")
        XCTAssertNil(snapshot.hourly[1].uvIndex, "null 元素 → 该点该字段 nil")
        XCTAssertEqual(try XCTUnwrap(snapshot.hourly[2].visibility), 18480.0, accuracy: 1e-9)
        XCTAssertNil(snapshot.hourly[1].visibility)
        XCTAssertEqual(try XCTUnwrap(snapshot.hourly[2].freezingLevelHeight), 4010.0, accuracy: 1e-9,
                       "零度层高度单位为米，原值透传")
        XCTAssertNil(snapshot.hourly[1].freezingLevelHeight)
    }

    // MARK: - ③ mapper 接线守卫（防"哑火线"：字段有默认值，漏传也编译通过）

    /// ⚠️ 本用例锚的是一类**编译器抓不到**的缺陷：`HourlyPoint` 的可选属性都有默认值 `nil`，
    /// mapper 里**漏传**实参时照样编译通过、照样全绿，只是字段永远为nil。
    /// 本仓已真实发生过一次（`precipitationProbability` 从未接线，概率行恒显示 "--"）。
    /// 故这里对三个新字段逐个断言"确实落到了点上"。
    func testNewHourlyFieldsActuallyReachHourlyPoint() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai",
          "utc_offset_seconds": 28800,
          "current": { "time": \(baseEpoch), "temperature_2m": 19.0, "relative_humidity_2m": 50,
                       "apparent_temperature": 18.0, "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1 },
          "hourly": { "time": [\(baseEpoch)],
                      "temperature_2m": [20.0],
                      "weather_code": [1],
                      "uv_index": [4.9],
                      "visibility": [16740.0],
                      "freezing_level_height": [2690.0] }
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        let snapshot = OpenMeteoMapper.map(dto,
                                           location: .beijing,
                                           now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))
        let point = try XCTUnwrap(snapshot.hourly.first)
        XCTAssertEqual(try XCTUnwrap(point.uvIndex), 4.9, accuracy: 1e-9,
                       "逐时UV 必须由 mapper 赋值（漏传不会编译失败，只能靠本用例兜住）")
        XCTAssertEqual(try XCTUnwrap(point.visibility), 16740.0, accuracy: 1e-9,
                       "逐时能见度必须由 mapper 赋值")
        XCTAssertEqual(try XCTUnwrap(point.freezingLevelHeight), 2690.0, accuracy: 1e-9,
                       "逐时零度层高度必须由 mapper 赋值")
    }

    // MARK: - ④ `0` 与缺失严格区分

    /// 三个新字段的 `0.0` 都是合法读数，必须原样保留为 0（UI 显示"0.0"而非 "--"）。
    func testZeroValuesArePreservedNotTurnedIntoNil() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai",
          "utc_offset_seconds": 28800,
          "current": { "time": \(baseEpoch), "temperature_2m": 19.0, "relative_humidity_2m": 50,
                       "apparent_temperature": 18.0, "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1 },
          "hourly": { "time": [\(baseEpoch)],
                      "temperature_2m": [20.0],
                      "weather_code": [1],
                      "uv_index": [0.0],
                      "visibility": [0.0],
                      "freezing_level_height": [0.0] }
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        let snapshot = OpenMeteoMapper.map(dto,
                                           location: .beijing,
                                           now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))
        let point = try XCTUnwrap(snapshot.hourly.first)
        XCTAssertEqual(try XCTUnwrap(point.uvIndex), 0.0, accuracy: 1e-9, "UV 0 是合法夜间值")
        XCTAssertEqual(try XCTUnwrap(point.visibility), 0.0, accuracy: 1e-9, "0 保留为 0")
        XCTAssertEqual(try XCTUnwrap(point.freezingLevelHeight), 0.0, accuracy: 1e-9, "0 保留为 0")
        // 分级侧：UV 0 → 低档（不是 nil）。
        XCTAssertEqual(UVIndexLevel(uv: point.uvIndex), .low,
                       "UV 0 应得「低」档，绝不可当成无数据")
    }

    /// 逐时 UV 全为 0（极夜/夜间）时，峰值**合法地**是 0，而不是 nil。
    func testAllZeroUVStillYieldsPeak() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai",
          "utc_offset_seconds": 28800,
          "current": { "time": \(baseEpoch), "temperature_2m": 19.0, "relative_humidity_2m": 50,
                       "apparent_temperature": 18.0, "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1 },
          "hourly": { "time": [\(baseEpoch), \(baseEpoch + 3600)],
                      "temperature_2m": [20.0, 21.0],
                      "weather_code": [1, 1],
                      "uv_index": [0.0, 0.0] }
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        let snapshot = OpenMeteoMapper.map(dto,
                                           location: .beijing,
                                           now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let peak = try XCTUnwrap(
            UVIndexGuide.dailyPeak(points: snapshot.hourly,
                                   now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)),
                                   timeZone: timeZone),
            "全天 UV 为 0 是**结论**，必须给出峰值而不是 nil")
        XCTAssertEqual(peak.value, 0.0, accuracy: 1e-9)
    }

    // MARK: - ⑤ 旧缓存兼容（不含新键的旧 JSON）

    func testOldCacheWithoutNewKeysMapsToNil() throws {
        let json = """
        {
          "timezone": "Asia/Shanghai",
          "utc_offset_seconds": 28800,
          "current": { "time": \(baseEpoch), "temperature_2m": 19.0, "relative_humidity_2m": 50,
                       "apparent_temperature": 18.0, "weather_code": 1, "wind_speed_10m": 1.0,
                       "wind_direction_10m": 90.0, "is_day": 1 },
          "hourly": { "time": [\(baseEpoch)],
                      "temperature_2m": [20.0],
                      "weather_code": [1] }
        }
        """
        let dto = try JSONDecoder().decode(OpenMeteoResponse.self, from: Data(json.utf8))
        XCTAssertNil(dto.hourly.uv_index)
        XCTAssertNil(dto.hourly.visibility)
        XCTAssertNil(dto.hourly.freezing_level_height)

        // 快照本身也要能编码/解码（新字段缺失往返后仍为 nil，不破坏共享容器载荷）。
        let snapshot = OpenMeteoMapper.map(dto,
                                           location: .beijing,
                                           now: Date(timeIntervalSince1970: TimeInterval(baseEpoch)))
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(WeatherSnapshot.self, from: data)
        XCTAssertNil(restored.hourly.first?.uvIndex)
        XCTAssertNil(restored.hourly.first?.visibility)
        XCTAssertNil(restored.hourly.first?.freezingLevelHeight)
    }

    // MARK: - Helpers

    private func queryItems(_ url: URL) throws -> [String: String] {
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(components.queryItems)
        return Dictionary(items.map { ($0.name, $0.value ?? "") },
                          uniquingKeysWith: { first, _ in first })
    }
}
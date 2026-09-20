//
//  METNorwayTests.swift
//  ZhishengWeatherTests
//
//  第三源 MET Norway（api.met.no locationforecast compact，免 Key）的接入锚点：
//  1．请求面：**只有一条 URL**、含坐标参数（AC：不新增第二次请求）；
//  2．DTO 容错：缺 `instant` / 缺 `details` / 缺属性块 / 空序列 / **数组元素为 null**
//     → 解码**不抛错**，对应字段 nil（本仓库曾因元素写非可选导致整包解码失败）；
//  3．`0` 与缺失严格区分：`wind_from_direction = 0`（正北）原样保留为 0；
//  4．取**离 `now` 最近**的那一条（不是插值、不是估算），且不可解析 / 非 UTC 偏移的
//     条目被**跳过**（宁缺不猜：绝不静默偏移时刻）；
//  5．`requiredFields` 与 mapper 实际写入字段集合**双向相等**（防误摘 + 防哑火）；
//  6．描述符自洽：已登记、辅助源、参与自动摘除、含新能力；
//  7．`SourceID.rawValue` **从枚举派生**（绝不硬编码字符串 —— 见下）；
//  8．端点 / 服务层：请求带 `User-Agent`（MET 条款要求，缺它可能被拒）、
//     单次请求、非 2xx 透传状态码、未请求能力时不联网。
//
//  ⚠️ **rawValue 一律从枚举派生，绝不硬编码字符串**：本仓库初版曾把 **case 名**
//  （`"sunriseSunset"`）当成 rawValue 写进测试，而真实 rawValue 是连带字符串
//  （`"sunrise-sunset"`）—— 结果是那一批测试 **8 条里 6 条必红**，看似"修复没生效"。
//  派生写法的意义：rawValue 将来改了，测试跟着改，不会静默失效。
//
//  并发纪律：`XCTAssert*` 的实参是 **autoclosure**，装不下 `await`。
//  故所有 `await` 都先求值到局部常量 / 局部绑定，再断言；不使用 Task /
//  XCTestExpectation / 信号量绕过。
//
//  不联网：全部喂本地造好的 JSON（服务层用 URLProtocol 桩注入响应）。
//

import XCTest
@testable import ZhishengWeather

/// 可编程 URLProtocol：startLoading 时调用静态 handler。
///
/// 与本 target 内既有的 `MockURLProtocol`（`ClimateProfileServiceTests.swift`）
/// 同名但 `private`（文件级可见），互不冲突。
private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class METNorwayTests: XCTestCase {

    /// 2026-09-20T05:00:00Z（与探针时刻同形的整点）。
    private let nowAt0500 = Date(timeIntervalSince1970: 1_789_880_400)

    /// 一次"正常响应"（探针实测形态的缩影；含 `next_1_hours` 以证明其被忽略）。
    private static let fullJSON = #"""
    {"type":"Feature",
     "geometry":{"type":"Point","coordinates":[116.4074,39.9042,48]},
     "properties":{
       "meta":{"updated_at":"2026-09-20T05:18:28Z",
               "units":{"air_pressure_at_sea_level":"hPa","air_temperature":"celsius",
                        "cloud_area_fraction":"%","relative_humidity":"%",
                        "wind_from_direction":"degrees","wind_speed":"m/s"}},
       "timeseries":[
         {"time":"2026-09-20T04:00:00Z",
          "data":{"instant":{"details":{"air_pressure_at_sea_level":1019.3,"air_temperature":26.9,
                                       "cloud_area_fraction":47.7,"relative_humidity":45.7,
                                       "wind_from_direction":68.2,"wind_speed":2.4}},
                  "next_1_hours":{"summary":{"symbol_code":"clearsky_day"},
                                  "details":{"precipitation_amount":0.0}}}},
         {"time":"2026-09-20T05:00:00Z",
          "data":{"instant":{"details":{"air_pressure_at_sea_level":1019.7,"air_temperature":27.5,
                                       "cloud_area_fraction":50.1,"relative_humidity":44.2,
                                       "wind_from_direction":0,"wind_speed":0}},
                  "next_1_hours":{"summary":{"symbol_code":"partlycloudy_day"},
                                  "details":{"precipitation_amount":0.0}}}}
       ]}}
    """#

    // MARK: - Helpers

    private func decode(_ json: String) throws -> METNorwayResponse {
        try JSONDecoder().decode(METNorwayResponse.self, from: Data(json.utf8))
    }

    private func patch(_ json: String, now: Date? = nil) throws -> FieldPatch {
        METNorwayMapper.map(try decode(json), now: now ?? nowAt0500)
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// 成功响应（200 + 指定 JSON）的桩，返回累计请求次数。
    private func stubSuccess(json: String) -> () -> Int {
        var count = 0
        MockURLProtocol.handler = { request in
            count += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }
        return { count }
    }

    // MARK: - 1．请求面：只有一条 URL

    func testBuildsSingleURLWithCoordinates() throws {
        let url = try XCTUnwrap(METNorwayEndpoint.url(latitude: 39.9042, longitude: 116.4074))
        let absolute = url.absoluteString

        XCTAssertTrue(absolute.hasPrefix("https://api.met.no/weatherapi/locationforecast/2.0/compact"),
                      "主机与端点必须与实测探针一致，实际=\(absolute)")
        XCTAssertTrue(absolute.contains("lat=39.9042"))
        XCTAssertTrue(absolute.contains("lon=116.4074"))

        // 只有一条 URL / 一次请求：主机与端点路径各只出现一次，参数各唯一。
        XCTAssertEqual(absolute.components(separatedBy: "api.met.no").count - 1, 1,
                       "不得新增第二条 MET 请求 URL")
        XCTAssertEqual(absolute.components(separatedBy: "/compact").count - 1, 1,
                       "不得新增第二个端点")

        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.count, 2, "请求面只应有 lat / lon 两个参数，实际=\(items.map(\.name))")
        for name in ["lat", "lon"] {
            XCTAssertEqual(items.filter { $0.name == name }.count, 1,
                           "参数 \(name) 必须唯一（并入既有请求，而非并列第二次请求）")
        }
    }

    // MARK: - 2．DTO 容错（缺键 / 缺块 / 空序列 / null 元素一律不抛错）

    func testMissingBlocksAndEmptySeriesDecodeWithoutThrowing() throws {
        // 缺 properties / 缺 timeseries / timeseries 为空。
        let noProperties = try patch("{}")
        XCTAssertTrue(noProperties.fields.isEmpty, "缺 properties → 空补丁（不崩、不抛）")
        XCTAssertTrue(noProperties.isMissing(.temperature))

        let noSeries = try patch(#"{"properties":{}}"#)
        XCTAssertTrue(noSeries.fields.isEmpty, "缺 timeseries → 空补丁")

        let emptySeries = try patch(#"{"properties":{"timeseries":[]}}"#)
        XCTAssertTrue(emptySeries.fields.isEmpty, "空序列 → 空补丁（不用假值填）")
    }

    func testMissingInstantOrDetailsDecodesWithoutThrowing() throws {
        // 有 time / 有 data，但缺 instant。
        let noInstant = try patch(
            #"{"properties":{"timeseries":[{"time":"2026-09-20T05:00:00Z","data":{}}]}}"#)
        XCTAssertTrue(noInstant.fields.isEmpty, "缺 instant → 空补丁")

        // 有 instant，但缺 details。
        let noDetails = try patch(
            #"{"properties":{"timeseries":[{"time":"2026-09-20T05:00:00Z","data":{"instant":{}}}]}}"#)
        XCTAssertTrue(noDetails.fields.isEmpty, "缺 details → 空补丁")

        // instant 为 null（元素/块为 null 不得让整包解码失败）。
        let nullInstant = try patch(
            #"{"properties":{"timeseries":[{"time":"2026-09-20T05:00:00Z","data":{"instant":null}}]}}"#)
        XCTAssertTrue(nullInstant.fields.isEmpty, "instant 为 null → 空补丁")
    }

    /// 序列里出现 `null` 元素 → **解码不抛错**，该条被跳过，其余照常。
    ///
    /// 本仓库真实事故：DTO 把数组元素写成非可选，响应末尾一个 `null` 就让
    /// **整包**解码失败 → 主屏与小组件同时无数据。本用例就是那条线的守卫。
    func testNullArrayElementDoesNotBreakDecoding() throws {
        let dto = try decode(#"""
        {"properties":{"timeseries":[null,
          {"time":"2026-09-20T05:00:00Z","data":{"instant":{"details":{"air_temperature":27.5}}}},
          null]}}
        """#)

        let p = METNorwayMapper.map(dto, now: nowAt0500)
        XCTAssertEqual(p.number(.temperature), 27.5, "null 元素被跳过后，可用条目仍应照常映射")
    }

    /// 单字段缺失 → 该字段 nil，其余字段照常解析。
    func testPartiallyMissingDetailsYieldsNilOnlyForMissingKeys() throws {
        let p = try patch(#"""
        {"properties":{"timeseries":[{"time":"2026-09-20T05:00:00Z",
          "data":{"instant":{"details":{"air_temperature":27.5,"relative_humidity":44.2}}}}]}}
        """#)

        XCTAssertEqual(p.number(.temperature), 27.5)
        XCTAssertEqual(p.number(.humidity), 44.2)
        XCTAssertTrue(p.isMissing(.pressure), "缺键 → 缺失（不是 0）")
        XCTAssertTrue(p.isMissing(.cloudCover))
        XCTAssertTrue(p.isMissing(.windSpeed))
        XCTAssertTrue(p.isMissing(.windDirection))
    }

    // MARK: - 3．`0` 与缺失严格区分

    func testZeroValuesArePresentNotMissing() throws {
        let p = try patch(#"""
        {"properties":{"timeseries":[{"time":"2026-09-20T05:00:00Z",
          "data":{"instant":{"details":{"air_temperature":0,"air_pressure_at_sea_level":0,
            "relative_humidity":0,"cloud_area_fraction":0,
            "wind_speed":0,"wind_from_direction":0}}}}]}}
        """#)

        XCTAssertFalse(p.isMissing(.windDirection), "风向 0（正北）是合法值，绝不是缺失")
        XCTAssertEqual(p.number(.windDirection), 0.0)
        XCTAssertEqual(p.number(.windSpeed), 0.0, "静风 0 m/s 是合法值")
        XCTAssertEqual(p.number(.temperature), 0.0)
        XCTAssertEqual(p.number(.pressure), 0.0)
        XCTAssertEqual(p.number(.humidity), 0.0)
        XCTAssertEqual(p.number(.cloudCover), 0.0)
        // 反向自检：未出现的字段仍必须是"缺失"，别把「全 0」误当成「全在」。
        XCTAssertTrue(p.isMissing(.dewPoint), "未映射的字段不在补丁里")
    }

    // MARK: - 4．取离 now 最近的一格

    func testPicksEntryNearestToNowAndSkipsUnusableTimes() throws {
        // now = 2026-09-20T05:20:00Z；候选：04:00(Δ80m) / 05:00(Δ20m) / 06:00(Δ40m)。
        // 另有两条"陷阱"：时刻不可解析的、以及**非 UTC 偏移**（+02:00）的 —— 都必须被跳过。
        let json = #"""
        {"properties":{"timeseries":[
          {"time":"2026-09-20T04:00:00Z","data":{"instant":{"details":{"air_temperature":10}}}},
          {"time":"not-a-timestamp","data":{"instant":{"details":{"air_temperature":-100}}}},
          {"time":"2026-09-20T05:30:00+02:00","data":{"instant":{"details":{"air_temperature":999}}}},
          {"time":"2026-09-20T05:00:00Z","data":{"instant":{"details":{"air_temperature":20}}}},
          {"time":"2026-09-20T06:00:00Z","data":{"instant":{"details":{"air_temperature":30}}}}
        ]}}
        """#
        let p = try patch(json, now: nowAt0500.addingTimeInterval(20 * 60))

        XCTAssertEqual(p.number(.temperature), 20.0,
                       "必须取离 now 最近的一格（05:00，Δ20min），不是插值/估算")
        XCTAssertNotEqual(p.number(.temperature), 999.0,
                          "非 UTC 偏移条目必须被**跳过**，绝不把带 +02:00 的墙钟当 UTC 硬解（静默偏移）")
        XCTAssertNotEqual(p.number(.temperature), -100.0, "时刻不可解析的条目必须被跳过")
    }

    /// `now` 早于 / 晚于整个序列 → 取序列两端（最接近的那一端）。
    func testPicksNearestEvenOutsideSeriesRange() throws {
        let json = #"""
        {"properties":{"timeseries":[
          {"time":"2026-09-20T05:00:00Z","data":{"instant":{"details":{"air_temperature":20}}}},
          {"time":"2026-09-20T06:00:00Z","data":{"instant":{"details":{"air_temperature":30}}}}
        ]}}
        """#
        let afterAll = try patch(json, now: nowAt0500.addingTimeInterval(10 * 3600))
        XCTAssertEqual(afterAll.number(.temperature), 30.0, "now 晚于序列 → 取最后一条")

        let beforeAll = try patch(json, now: nowAt0500.addingTimeInterval(-10 * 3600))
        XCTAssertEqual(beforeAll.number(.temperature), 20.0, "now 早于序列 → 取第一条")
    }

    // MARK: - 5．requiredFields 与 mapper 写入字段集合双向对齐

    func testFullResponseCoversEveryRequiredField() throws {
        let p = try patch(Self.fullJSON)
        XCTAssertFalse(p.fields.isEmpty, "正常响应必须产出字段")

        let declared = METNorwayService().requiredFields
        XCTAssertFalse(declared.isEmpty, "参与自动摘除的源必须有必填集（否则 EV-1 恒不触发）")

        let stillMissing = declared.filter { p.isMissing($0) }
        XCTAssertTrue(stillMissing.isEmpty,
                      "正常响应下仍缺的必填字段：\(stillMissing) —— 这些字段一旦列入 requiredFields，"
                      + "本源会在 3 次轮询后被 EV-1 **误摘**（静默自伤）")

        // **反向**：mapper 真的写了的字段必须**全部**被声明。
        // 只声明一半的后果是另一半**永不参与 EV-1**（守卫哑火，坏了也不摘）。
        XCTAssertEqual(Set(p.fields), declared,
                       "mapper 写入的字段集合必须**恰好**等于 requiredFields："
                       + "写入集=\(Set(p.fields).map(\.rawValue).sorted())，"
                       + "声明集=\(declared.map(\.rawValue).sorted())")
    }

    /// compact 端点**没有**阵风字段（实测 0/90 条）→ 绝不映射 `.windGust`。
    func testNeverDeclaresOrMapsGust() throws {
        let declared = METNorwayService().requiredFields
        XCTAssertFalse(declared.contains(.windGust),
                       "compact 端点无 wind_speed_of_gust：声明它会让本源被 EV-1 误摘")
        XCTAssertFalse(declared.contains(.precipitationProbability),
                       "compact 端点无降水概率字段")

        let mapped = try patch(Self.fullJSON)
        XCTAssertFalse(mapped.fields.contains(.windGust))
        XCTAssertFalse(mapped.fields.contains(.precipitationProbability))
    }

    // MARK: - 6．描述符自洽（登记 / 角色 / 摘除开关 / 能力）

    func testDescriptorIsRegisteredAsAuxiliaryWithNewCapability() throws {
        let descriptor = try XCTUnwrap(SourceDirectory.descriptor(for: .metNorwayForecast),
                                       "新源必须登记在 SourceDirectory.all —— 否则自动摘除查不到"
                                       + "行为标记、设置页也根本不显示它（静默哑火）")

        XCTAssertEqual(descriptor.displayName, METNorwayService().displayName)
        XCTAssertEqual(descriptor.role, .auxiliary, "MET Norway 是辅助源，不参与主源链路")
        XCTAssertTrue(descriptor.participatesInAutoExclusion, "辅助源必须参与自动摘除")
        XCTAssertFalse(descriptor.needsCredential, "本源免 Key，绝不标成需要凭据")
        XCTAssertTrue(descriptor.capabilities.contains(.basicNumericFields))
        XCTAssertEqual(descriptor.capabilities, METNorwayService().capabilities,
                       "描述符与运行期能力集必须一致（漂移会让设置页/守卫与实际取数各看一份）")
        XCTAssertEqual(descriptor.requiredFields, METNorwayService().requiredFields)

        // 设置页「多源管理」按此目录逐行渲染 → 登记了就自动出现，且带停用入口。
        let row = try XCTUnwrap(SourceCatalog.all.first { $0.id == .metNorwayForecast })
        XCTAssertEqual(row.role, .auxiliary)
        XCTAssertTrue(row.participatesInAutoExclusion, "设置页据此给出「手动停用」入口")
    }

    // MARK: - 7．rawValue 从枚举派生（不硬编码）

    func testSourceIDRawValueIsDerivedFromEnum() throws {
        let raw = SourceID.metNorwayForecast.rawValue

        // 自检：派生的必须是**能被枚举认回**的真 rawValue。
        XCTAssertEqual(SourceID(rawValue: raw), .metNorwayForecast,
                       "派生的 rawValue 必须能被 SourceID 认回")

        // 沿用既有源的**连字符串**风格（不是 case 名 camelCase）。
        XCTAssertTrue(raw.contains("-"), "rawValue 应为连字符串，实际=\(raw)")
        XCTAssertFalse(raw.contains("_"), "rawValue 不应使用下划线，实际=\(raw)")

        // 与既有源的 rawValue 不撞车（账本 / 偏好按它落盘，撞了会互相串台）。
        let others = SourceID.allCases.filter { $0 != .metNorwayForecast }.map(\.rawValue)
        XCTAssertFalse(others.contains(raw), "rawValue 与已有源重复")
    }

    // MARK: - 8．服务层（UA / 单次请求 / 状态码透传）

    /// 请求必须带可识别的 `User-Agent`（MET 条款要求标识自身，缺它可能被拒）。
    ///
    /// 这里**不联网**地钉住它（直接查端点拼出的 URLRequest），
    /// 避免把「URLSession 是否把该头透传给 URLProtocol」这种实现细节混进断言。
    func testEndpointRequestCarriesRequiredUserAgent() throws {
        let request = try XCTUnwrap(METNorwayEndpoint.request(latitude: 39.9042,
                                                              longitude: 116.4074))
        let userAgent = request.value(forHTTPHeaderField: "User-Agent")

        XCTAssertEqual(userAgent, METNorwayEndpoint.userAgent)
        XCTAssertFalse((userAgent ?? "").isEmpty,
                       "MET 条款要求可识别 User-Agent，缺它可能被 403 拒")
    }

    /// 正常响应 → **只发一次请求**，且走「解码 → 映射」全链路。
    func testServiceIssuesSingleRequestAndMapsResponse() async throws {
        let requestCount = stubSuccess(json: Self.fullJSON)
        let service = METNorwayService(session: session())

        let p = try await service.fetchFields(latitude: 39.9042, longitude: 116.4074,
                                             capabilities: [.basicNumericFields], now: nowAt0500)

        XCTAssertEqual(requestCount(), 1, "只应发生一次请求（不新增第二次）")
        XCTAssertEqual(p.number(.temperature), 27.5, "05:00 那一格")
        XCTAssertEqual(p.number(.windDirection), 0.0, "0（正北）与缺失严格区分")
        XCTAssertEqual(Set(p.fields), METNorwayService().requiredFields)
    }

    /// 非 2xx → 透传为 `WeatherError.badStatus(code)`（EV-3 据此裁定冷却 / 会话摘除）。
    func testServicePassesThroughNon2xxStatus() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 429,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }
        let service = METNorwayService(session: session())

        do {
            _ = try await service.fetchFields(latitude: 39.9042, longitude: 116.4074,
                                             capabilities: [.basicNumericFields], now: nowAt0500)
            XCTFail("非 2xx 必须抛错（EV-3 的输入），不得静默回空补丁")
        } catch let error as WeatherError {
            guard case .badStatus(let code) = error else {
                XCTFail("应为 .badStatus（EV-3 输入），实际 \(error)")
                return
            }
            XCTAssertEqual(code, 429)
        } catch {
            XCTFail("必须收敛为 WeatherError，实际 \(error)")
        }
    }

    /// 未请求本源能力 → **不联网**，直接回空补丁。
    func testServiceDoesNotRequestWhenCapabilityNotAsked() async throws {
        let requestCount = stubSuccess(json: Self.fullJSON)
        let service = METNorwayService(session: session())

        let p = try await service.fetchFields(latitude: 39.9042, longitude: 116.4074,
                                             capabilities: [], now: nowAt0500)

        XCTAssertTrue(p.fields.isEmpty)
        XCTAssertEqual(requestCount(), 0, "未请求该能力时绝不应联网")
    }

    /// MET Norway 只映射数值字段，**绝不**产出 solar 键（sunrise/sunset/solarNoon/daylightDuration）。
    ///
    /// 这是「overlay 不内嵌主源 solar 值」不变量的**源侧前提**：MET 作为非 solar 辅助源，
    /// 若它意外开始产 solar 键，协调器按 provenance 过滤时这些键的 kind 会是 `.fallback`
    /// （主源有 sunrise/sunset 时），从而把 MET 的 solar 值顶进 overlay —— 与本意相悖。
    /// 钉死 MET 的补丁字段集恰好等于其数值 `requiredFields`，不含任何 solar 键。
    func testMapperNeverEmitsSolarKeys() throws {
        let p = try patch(Self.fullJSON)
        let solarKeys: Set<WeatherFieldKey> = [.sunrise, .sunset, .solarNoon, .daylightDuration]
        XCTAssertTrue(solarKeys.isDisjoint(with: Set(p.fields)),
                      "MET 补丁不得含任何 solar 键，实际含：\(Set(p.fields).intersection(solarKeys))")
        XCTAssertEqual(Set(p.fields), METNorwayService().requiredFields,
                       "MET 补丁集必须恰好等于其数值 requiredFields")
    }
}

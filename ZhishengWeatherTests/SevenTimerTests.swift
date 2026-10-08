//
//  SevenTimerTests.swift
//  ZhishengWeatherTests
//
//  第八源 7timer!（`www.7timer.info/bin/api.pl`，免 Key）**兜底源**的接入锚点：
//  1．请求面：**只有一条 URL**，且**必须带 `product`**（实测漏它会得到
//     `ERR: no product specified`）；含 lon / lat / product / output 四个参数。
//  2．DTO 容错：缺块 / 空序列 / 序列元素为 `null` → 解码**不抛错**，对应字段 nil。
//  3．单位**直通**：本源 JSON 恒为公制（实测 `unit=metric|imperial` 输出逐字相同），
//     故 mapper 对 `temp2m`(℃) / `msl_pressure`(hPa) 是**原样搬运**，绝不换算。
//  4．`-9999` 哨兵 = 缺失（实测偏远/极地响应里成片出现），**绝不当读数**；
//     `0` 与缺失严格区分。
//  5．`wind10m.direction` 是**字符串**（实测 `"25"`/`"195"`）；非数字串（跨产品的
//     方位字母）→ 该字段缺失（宁缺不猜）。
//  6．取**离 `now` 最近**的一条，且 |时间差| > 一个步长（3h）→ **返回空补丁**
//     （窗口外不拿陈旧值冒充当前值）。
//  7．`requiredFields` 与 mapper 实际写入字段集合**双向相等**（防误摘 + 防哑火），
//     且**绝不含**档位码字段（湿度 / 云量 / 风速）。
//  8．描述符自洽：已登记、辅助源、免凭据、参与自动摘除、含新能力、官网链接非空。
//  9．服务层：**200-错误正文**（四种）必须先于解码判别 → 抛 `.dataMissing`；
//     非 2xx 透传 `.badStatus`；未请求能力时不联网。
//
//  ⚠️ **反事实自查**：若把 `SevenTimerMapper.map` 改成**永远返回空补丁**，
//     下面断言「温度 / 气压 / 风向确有值」「补丁字段集 == requiredFields」的用例
//     （`testMapsTemperaturePressureAndWindDirection` / `testRequiredFieldsEqualMappedKeys`
//      / `testZeroValuesArePresentNotMissing` / `testMetricValuesPassThroughWithoutConversion`
//      / `testPicksNearestEntryToNow` / `testServiceMapsSuccessResponse`）
//      **会全部变红** → 测试对「实现了还是有输出」有判别力（非空转）。
//
//  ⚠️ **rawValue 一律从枚举派生，绝不硬编码字符串**（沿用本仓 METNorwayTests 的纪律）。
//
//  并发纪律：`XCTAssert*` 的实参是 autoclosure，装不下 `await` → 先求值到局部常量再断言。
//  不联网：全部喂本地造好的 JSON（服务层用 URLProtocol 桩注入响应）。
//

import XCTest
@testable import ZhishengWeather

/// 可编程 URLProtocol（本文件私有，避免与其它测试文件的同名桩冲突）。
private final class SevenTimerMockURLProtocol: URLProtocol {
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

final class SevenTimerTests: XCTestCase {

    /// `init = 2026100800`（2026-10-08T00:00:00Z）对应的 epoch（由 UTC 手工核算）。
    private static let initEpoch: TimeInterval = 1_791_417_600
    /// `now` 恰落在 `timepoint = 3` 的格点上（03:00Z，漂移 0）。
    private let nowAt0300 = Date(timeIntervalSince1970: Self.initEpoch + 3 * 3600)
    /// `now` 落在 tp=3 与 tp=6 之间偏 tp=6（05:00Z）——用于验证「取最近」而非「取首条」。
    private let nowAt0500 = Date(timeIntervalSince1970: Self.initEpoch + 5 * 3600)

    /// 一份形态完整的 `product=meteo` 缩影（逐字字段名取自实测响应）。
    private static let meteoJSON = #"""
    {"product":"meteo","init":"2026100800","dataseries":[
      {"timepoint":3,"cloudcover":1,"temp2m":16,"rh2m":2,"msl_pressure":1020,
       "wind10m":{"direction":"25","speed":2},"prec_type":"none","prec_amount":0},
      {"timepoint":6,"cloudcover":3,"temp2m":19,"rh2m":-1,"msl_pressure":1019,
       "wind10m":{"direction":"185","speed":3}},
      {"timepoint":9,"cloudcover":5,"temp2m":24,"rh2m":1,"msl_pressure":1017,
       "wind10m":{"direction":"310","speed":4}}
    ]}
    """#

    // MARK: - Helpers

    private func decode(_ json: String) throws -> SevenTimerResponse {
        try JSONDecoder().decode(SevenTimerResponse.self, from: Data(json.utf8))
    }

    private func patch(_ json: String, now: Date) throws -> FieldPatch {
        SevenTimerMapper.map(try decode(json), now: now)
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SevenTimerMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// 成功响应（200 + 指定正文）的桩，返回累计请求次数。
    private func stubSuccess(json: String) -> () -> Int {
        var count = 0
        SevenTimerMockURLProtocol.handler = { request in
            count += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }
        return { count }
    }

    // MARK: - 1．请求面：只有一条 URL，且必须带 product

    func testBuildsSingleURLWithRequiredProduct() throws {
        let url = try XCTUnwrap(SevenTimerEndpoint.url(latitude: 39.9042, longitude: 116.4074))
        let absolute = url.absoluteString

        XCTAssertTrue(absolute.hasPrefix("https://www.7timer.info/bin/api.pl"),
                      "主机与端点必须与实测探针一致，实际=\(absolute)")

        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let names = items.map(\.name).sorted()
        XCTAssertEqual(names, ["lat", "lon", "output", "product"],
                       "请求面必须恰好是 lon/lat/product/output 四个参数，实际=\(names)")

        // 「必须带 product」是本源的**实测硬约束**：漏了会得到 ERR: no product specified。
        XCTAssertEqual(items.first { $0.name == "product" }?.value, SevenTimerEndpoint.product,
                       "product 缺失 / 值不对会让上游返回错误正文而非数据")
        XCTAssertEqual(SevenTimerEndpoint.product, "meteo", "本源采用的产品（实测合法值之一）")
        XCTAssertEqual(items.first { $0.name == "output" }?.value, "json")

        // 只有一条 URL / 一次请求：主机只出现一次。
        XCTAssertEqual(absolute.components(separatedBy: "7timer.info").count - 1, 1,
                       "不得新增第二条 7timer 请求 URL")
    }

    // MARK: - 2．DTO 容错（缺块 / 空序列 / null 元素一律不抛错）

    func testMissingBlocksAndEmptySeriesDecodeWithoutThrowing() throws {
        let empty = try patch("{}", now: nowAt0300)
        XCTAssertTrue(empty.fields.isEmpty, "全缺 → 空补丁（不崩、不抛）")
        XCTAssertEqual(empty.sourceID, .sevenTimer)
        XCTAssertTrue(empty.isMissing(.temperature))

        let noSeries = try patch(#"{"product":"meteo","init":"2026100800"}"#, now: nowAt0300)
        XCTAssertTrue(noSeries.fields.isEmpty, "缺 dataseries → 空补丁")

        let emptySeries = try patch(#"{"init":"2026100800","dataseries":[]}"#, now: nowAt0300)
        XCTAssertTrue(emptySeries.fields.isEmpty, "空序列 → 空补丁（不用假值填）")
    }

    /// 序列里出现 `null` 元素 → **解码不抛错**，该条被跳过，其余照常。
    func testNullArrayElementDoesNotBreakDecoding() throws {
        let dto = try decode(#"""
        {"init":"2026100800","dataseries":[null,
          {"timepoint":3,"temp2m":16,"msl_pressure":1020,
           "wind10m":{"direction":"25","speed":2}},
          null]}
        """#)
        let p = SevenTimerMapper.map(dto, now: nowAt0300)
        XCTAssertEqual(p.number(.temperature), 16.0, "null 元素被跳过后仍应照常映射")
    }

    // MARK: - 3/4．字段映射、单位直通、哨兵过滤

    /// 温度 / 气压 / 风向三个字段被正确搬运（**这是本源的产出本体**）。
    func testMapsTemperaturePressureAndWindDirection() throws {
        let p = try patch(Self.meteoJSON, now: nowAt0300)
        XCTAssertEqual(p.number(.temperature), 16.0)
        XCTAssertEqual(p.number(.pressure), 1020.0)
        XCTAssertEqual(p.number(.windDirection), 25.0)
        XCTAssertEqual(p.sourceID, .sevenTimer)
    }

    /// 单位**直通**：℃ / hPa 原样搬运，**绝不**换算（JSON 恒公制，实测 unit 参数无效）。
    func testMetricValuesPassThroughWithoutConversion() throws {
        let p = try patch(Self.meteoJSON, now: nowAt0300)
        // 若有人「顺手」做了 ℉ 或 mmHg 换算，下面两条会立刻变红。
        XCTAssertEqual(p.number(.temperature), 16.0, "temp2m 是 ℃，原样传入，不做换算")
        XCTAssertEqual(p.number(.pressure), 1020.0, "msl_pressure 是 hPa，原样传入，不做换算")
    }

    /// `0` 是**真实读数**，不是缺失（哨兵是 `-9999`，不是 `0`）。
    func testZeroValuesArePresentNotMissing() throws {
        let p = try patch(#"""
        {"init":"2026100800","dataseries":[
          {"timepoint":3,"temp2m":0,"msl_pressure":0,"wind10m":{"direction":"0","speed":2}}]}
        """#, now: nowAt0300)
        XCTAssertEqual(p.number(.temperature), 0.0)
        XCTAssertFalse(p.isMissing(.temperature), "0 必须存在，不得当成缺失")
        XCTAssertEqual(p.number(.pressure), 0.0)
        XCTAssertEqual(p.number(.windDirection), 0.0, "0°（正北）与缺失严格区分")
    }

    /// `-9999` 哨兵 → 一律当缺失（实测偏远/极地响应里成片出现）。
    func testSentinelBecomesMissing() throws {
        let p = try patch(#"""
        {"init":"2026100800","dataseries":[
          {"timepoint":3,"temp2m":-9999,"msl_pressure":-9999,
           "wind10m":{"direction":"-9999","speed":2}}]}
        """#, now: nowAt0300)
        XCTAssertTrue(p.fields.isEmpty,
                      "哨兵一律转缺失，绝不让 -9999 冒充读数（实测 (lat=-85) 全条如此）")
        XCTAssertTrue(p.isMissing(.temperature))
        XCTAssertTrue(p.isMissing(.pressure))
        XCTAssertTrue(p.isMissing(.windDirection))
    }

    /// 风向是**字符串**：非数字串（跨产品的方位字母，如 "S"）→ 缺失，**绝不猜**。
    func testNonNumericWindDirectionBecomesMissing() throws {
        let p = try patch(#"""
        {"init":"2026100800","dataseries":[
          {"timepoint":3,"temp2m":16,"msl_pressure":1020,
           "wind10m":{"direction":"S","speed":2}}]}
        """#, now: nowAt0300)
        XCTAssertEqual(p.number(.temperature), 16.0, "其余字段照常")
        XCTAssertTrue(p.isMissing(.windDirection), "方位字母不可解析 → 缺失（不猜 0/180）")
    }

    /// 越界风向（> 360）说明语义已变 → 当缺失。
    func testOutOfRangeWindDirectionBecomesMissing() throws {
        let p = try patch(#"""
        {"init":"2026100800","dataseries":[
          {"timepoint":3,"temp2m":16,"wind10m":{"direction":"400","speed":2}}]}
        """#, now: nowAt0300)
        XCTAssertTrue(p.isMissing(.windDirection), "> 360° 说明语义已变 → 缺失")
    }

    // MARK: - 5．时间归一：取离 now 最近的一格，超差返回空

    func testPicksNearestEntryToNow() throws {
        // now = 05:00Z：tp=3（03:00，差 2h）与 tp=6（06:00，差 1h）→ 应取 tp=6（19℃）。
        let p = try patch(Self.meteoJSON, now: nowAt0500)
        XCTAssertEqual(p.number(.temperature), 19.0, "取最近一格，而非序列首条")
        XCTAssertEqual(p.number(.pressure), 1019.0)
    }

    /// `now` 落在预报窗口（`init` + 3…192h）之外 → **空补丁**，不拿陈旧值冒充当前值。
    func testNowOutsideWindowYieldsEmptyPatch() throws {
        // init + 192h（窗口末端）再往后再走 6h → 全部条目超差。
        let farFuture = Date(timeIntervalSince1970: Self.initEpoch + 192 * 3600 + 6 * 3600)
        let p = try patch(Self.meteoJSON, now: farFuture)
        XCTAssertTrue(p.fields.isEmpty, "全部条目 |时间差| > 3h → 返回空补丁（诚实红线）")
    }

    /// `init` 非 10 位 / 非法 → 无法定位基准时刻 → 空补丁（绝不静默偏移）。
    func testMalformedInitYieldsEmptyPatch() throws {
        let short = try patch(#"""
        {"init":"20261008","dataseries":[{"timepoint":3,"temp2m":16,"msl_pressure":1020}]}
        """#, now: nowAt0300)
        XCTAssertTrue(short.fields.isEmpty, "init 非 10 位 → 空补丁")

        let badMonth = try patch(#"""
        {"init":"2026130800","dataseries":[{"timepoint":3,"temp2m":16,"msl_pressure":1020}]}
        """#, now: nowAt0300)
        XCTAssertTrue(badMonth.fields.isEmpty, "月=13 非法 → 空补丁（不让日历翻滚掩盖）")
    }

    // MARK: - 6．声明与产出的双向一致（防误摘 + 防哑火 + 诚实）

    func testRequiredFieldsEqualMappedKeys() throws {
        let p = try patch(Self.meteoJSON, now: nowAt0300)
        XCTAssertEqual(Set(p.fields), SevenTimerService().requiredFields,
                       "补丁字段集必须**恰好**等于 requiredFields"
                       + "（多则 EV-1 误摘、少则该字段永不参与 EV-1）")
    }

    /// **诚实红线**：档位码字段（湿度 / 云量 / 风速）**绝不**被接成物理量。
    func testNeverMapsCodeLikeFieldsAsPhysicalQuantities() throws {
        let p = try patch(Self.meteoJSON, now: nowAt0300)
        let declared = SevenTimerService().requiredFields
        XCTAssertFalse(declared.contains(.humidity), "rh2m 是档位码（实测 −2…11），不是百分比")
        XCTAssertFalse(declared.contains(.cloudCover), "cloudcover 是档位码（实测 1…9）")
        XCTAssertFalse(declared.contains(.windSpeed), "wind10m.speed 是风力等级码（实测 1…4）")

        XCTAssertFalse(p.fields.contains(.humidity))
        XCTAssertFalse(p.fields.contains(.cloudCover))
        XCTAssertFalse(p.fields.contains(.windSpeed))
        XCTAssertTrue(Set(p.fields).isDisjoint(with: [.humidity, .cloudCover, .windSpeed]),
                      "档位码字段一旦混入补丁，UI 会显示一个看起来正常、实际错得离谱的值")
    }

    // MARK: - 7．描述符自洽（登记 / 角色 / 凭据 / 摘除开关 / 能力 / 官网）

    func testDescriptorIsRegisteredAsAuxiliaryFallback() throws {
        let descriptor = try XCTUnwrap(SourceDirectory.descriptor(for: .sevenTimer),
                                       "新源必须登记在 SourceDirectory.all —— 否则双射守卫"
                                       + "报缺项、自动摘除查不到行为标记、设置页也隐身")

        XCTAssertEqual(descriptor.displayName, SevenTimerService().displayName)
        XCTAssertEqual(descriptor.role, .auxiliary, "7timer 是辅助源，不参与主源链路")
        XCTAssertTrue(descriptor.participatesInAutoExclusion, "在链的真实取数源须参与自动摘除")
        XCTAssertFalse(descriptor.needsCredential, "本源免 Key，绝不标成需要凭据")
        XCTAssertEqual(descriptor.capabilities, SevenTimerService().capabilities)
        XCTAssertTrue(descriptor.capabilities.contains(.coarseFallbackFields))
        XCTAssertFalse(descriptor.capabilities.contains(.basicNumericFields),
                       "绝不复用 MET Norway 的能力：那样会把档位码当物理量的风险带进来")
        XCTAssertEqual(descriptor.requiredFields, SevenTimerService().requiredFields)

        // CC BY 4.0 署名：官网链接非空且可解析为 http(s)。
        XCTAssertFalse(descriptor.websiteURLString.isEmpty)
        let url = try XCTUnwrap(descriptor.websiteURL, "官网链接必须能解析（否则设置页署名点不出去）")
        XCTAssertTrue(["http", "https"].contains(url.scheme ?? ""))

        // 设置页「多源管理」自动出现该行，且带停用入口。
        let row = try XCTUnwrap(SourceCatalog.all.first { $0.id == .sevenTimer })
        XCTAssertEqual(row.role, .auxiliary)
        XCTAssertTrue(row.participatesInAutoExclusion)
    }

    /// **装配**：兜底源必须真的被组装进辅助链，且在**末位**（顺序即优先级）。
    @MainActor
    func testComposedAsLastAuxiliarySource() {
        let composed = SourceComposition.makeAuxiliarySources()
        XCTAssertTrue(composed.contains { $0.id == .sevenTimer },
                      "7timer 必须是组装点的一员 —— 否则编译过、测试过、**没人调用**（死代码）")
        XCTAssertEqual(composed.last?.id, .sevenTimer,
                       "兜底源必须排在辅助链末位（merge 取链序第一个有值者）")
    }

    // MARK: - 8．rawValue 从枚举派生（不硬编码）

    func testSourceIDRawValueIsDerivedFromEnum() throws {
        let raw = SourceID.sevenTimer.rawValue
        XCTAssertEqual(SourceID(rawValue: raw), .sevenTimer, "派生的 rawValue 必须能被认回")
        XCTAssertFalse(raw.isEmpty)
        let others = SourceID.allCases.filter { $0 != .sevenTimer }.map(\.rawValue)
        XCTAssertFalse(others.contains(raw), "rawValue 与已有源重复（账本/偏好会串台）")
    }

    // MARK: - 9．服务层（200-错误正文 / 状态码透传 / 不联网）

    /// 四种错误正文（全部 **HTTP 200**）必须被判出 —— 否则会被误报成「解码失败」。
    func testErrorBodyDetectionCoversAllMeasuredForms() {
        for body in ["ERR: no product specified",
                     "ERR: invalid product",
                     "ERR: invalid coordinate",
                     "ERR: no geographic location specified"] {
            XCTAssertTrue(SevenTimerEndpoint.isErrorBody(Data(body.utf8)),
                          "实测错误正文应被判出：\(body)")
        }
        XCTAssertFalse(SevenTimerEndpoint.isErrorBody(Data(#"{"product":"meteo"}"#.utf8)),
                       "正常 JSON 不得被判成错误正文")
        XCTAssertFalse(SevenTimerEndpoint.isErrorBody(Data()), "空正文不得判成错误")
    }

    func testServiceMapsSuccessResponse() async throws {
        let requestCount = stubSuccess(json: Self.meteoJSON)
        let service = SevenTimerService(session: session())

        let p = try await service.fetchFields(latitude: 39.9042, longitude: 116.4074,
                                             capabilities: [.coarseFallbackFields], now: nowAt0300)

        XCTAssertEqual(requestCount(), 1, "只应发生一次请求（不新增第二次）")
        XCTAssertEqual(p.number(.temperature), 16.0)
        XCTAssertEqual(p.number(.pressure), 1020.0)
        XCTAssertEqual(p.number(.windDirection), 25.0)
        XCTAssertEqual(Set(p.fields), SevenTimerService().requiredFields)
    }

    /// HTTP 200 + 错误正文 → 必须抛 `.dataMissing`，**不是** `.decodingDetail`
    /// （否则上层把「请求参数无效」误报成「接口变更」）。
    func testServiceThrowsDataMissingOnErrorBody() async {
        SevenTimerMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data("ERR: invalid product".utf8))
        }
        let service = SevenTimerService(session: session())

        do {
            _ = try await service.fetchFields(latitude: 39.9042, longitude: 116.4074,
                                             capabilities: [.coarseFallbackFields], now: nowAt0300)
            XCTFail("200-错误正文必须抛错，不得静默回空补丁")
        } catch let error as WeatherError {
            guard case .dataMissing = error else {
                XCTFail("应为 .dataMissing（归因=请求参数无效），实际 \(error)")
                return
            }
        } catch {
            XCTFail("必须收敛为 WeatherError，实际 \(error)")
        }
    }

    func testServicePassesThroughNon2xxStatus() async {
        SevenTimerMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }
        let service = SevenTimerService(session: session())

        do {
            _ = try await service.fetchFields(latitude: 39.9042, longitude: 116.4074,
                                             capabilities: [.coarseFallbackFields], now: nowAt0300)
            XCTFail("非 2xx 必须抛错（EV-3 的输入），不得静默回空补丁")
        } catch let error as WeatherError {
            guard case .badStatus(let code) = error else {
                XCTFail("应为 .badStatus（EV-3 输入），实际 \(error)")
                return
            }
            XCTAssertEqual(code, 503)
        } catch {
            XCTFail("必须收敛为 WeatherError，实际 \(error)")
        }
    }

    func testServiceDoesNotRequestWhenCapabilityNotAsked() async throws {
        let requestCount = stubSuccess(json: Self.meteoJSON)
        let service = SevenTimerService(session: session())

        let p = try await service.fetchFields(latitude: 39.9042, longitude: 116.4074,
                                             capabilities: [], now: nowAt0300)

        XCTAssertTrue(p.fields.isEmpty)
        XCTAssertEqual(requestCount(), 0, "未请求该能力时绝不应联网")
    }
}

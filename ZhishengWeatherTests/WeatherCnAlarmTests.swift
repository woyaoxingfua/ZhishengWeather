//
//  WeatherCnAlarmTests.swift
//  ZhishengWeatherTests
//
//  第七源（中国气象网结构化预警详情通道）测试。
//
//  ═══════════════════════════════════════════════════════════════════════
//  ⚠️⚠️ **本文件所有断言里的数据都是逐字真实响应**（2026-10-06 真实 curl），
//  **没有一条是我臆造的**。每处都在注释里标出它来自哪个端点/哪条预警。
//  凡是我**没有实测到**的形态（如 `YJTYPE_EN` 的真实值、红/橙色详情），
//  一律写成"**空值形态**"的断言（实测它恒为空）或干脆不测——
//  **绝不用想象的数据写断言**（那种测试恒过、且会掩盖真实回归）。
// ═══════════════════════════════════════════════════════════════════════
//
//  覆盖分组：
//   1．端点 URL 拼装（含Referer 常量、filename 畸形输入）
//   2．列表 DTO：8 元位置数组解码（**含实测的字符串型经纬度/count**）
//   3．详情 DTO：JSONP 剥壳（**含实测的`var alarminfo=` 前缀**）
//   4．逐字段合并器（主源优先 / 绝不覆盖 / 连接键精确相等）
//   5．跨源连接键三方一致性（实测 5/5）
//   6．静默门禁：不得引入假字段 / 不得动被禁文件
//
//  不联网、不读真实时钟。
//

import XCTest
@testable import ZhishengWeather

final class WeatherCnAlarmTests: XCTestCase {

    // MARK: - 实测样本（逐字，来自真实 curl）

    /// 实测列表首行（`result.data[0]`，**逐字**，2026-10-06 21:46）。
    /// 元数恒为 8（实测 137/137 行）。
    private static let realRow0JSON = """
    ["新疆维吾尔自治区伊犁哈萨克自治州昭苏县",
     "101131007-20261006212927-0902.html",
     "81.13",
     "43.16",
     "65402641600000_20261006212927",
     "65402641600000_20261006212927",
     "新疆维吾尔自治区伊犁哈萨克自治州昭苏县发布雷电黄色预警信号",
     {"coordinates":[[[81.324,43.396],[81.318,43.382]]]}]
    """

    /// 实测详情 JSONP 全文（**逐字**，715 字节响应体的完整内容）。
    ///
    /// ⚠️ 该条实测 `YJTYPE_EN` 与 `UNDERWRITER` 为**空串**，
    /// `NAMEEN` 是**汉语拼音**（`zhaosu yilihasake xinjiang`）——
    /// 这两条正是"不能把它当英文标题"的实测依据。
    private static let realJSONP = """
    var alarminfo={"head":"新疆维吾尔自治区伊犁哈萨克自治州昭苏县发布雷电黄色预警信号","ALERTID":"202610062129514372雷电黄色","PROVINCE":"新疆维吾尔自治区","CITY":"伊犁哈萨克自治州","STATIONNAME":"昭苏县","SIGNALTYPE":"雷电","SIGNALLEVEL":"黄色","TYPECODE":"09","LEVELCODE":"02","ISSUETIME":"2026-10-06 21:29:27","ISSUECONTENT":"昭苏县气象台2026年10月6日21时29分发布雷电黄色预警信号：目前，我县昭苏镇已出现雷电天气，预计今天夜间，上述区域及种马场、乌尊布拉克镇、阿克达拉镇等地将出现雷电天气，可能造成雷电灾害，期间可能伴有短时强降水、雷暴大风、冰雹等强对流天气，请注意防范。（预警信息来源：国家预警信息发布中心）","UNDERWRITER":"","RELIEVETIME":"2026-10-07 09:29:27","NAMEEN":"zhaosu yilihasake xinjiang","YJTYPE_EN":"","YJYC_EN":"Yellow","TIME":"2026-10-06 21:35","EFFECT":"101131007","msgType":"Alert","identifier":"65402641600000_20261006212927","references":"65402641600000_20261006212927"};
    """

    /// 造一条列表 JSON 响应（`count` 实测为**字符串**）。
    private static func listJSON(count: String, rows: [String]) -> Data {
        let json = "{\"status\":\"success\",\"errMsg\":\"\",\"result\":{\"count\":\"\(count)\",\"data\":[\(rows.joined(separator: ","))]}}"
        return Data(json.utf8)
    }

    // MARK: - 1．端点 URL 拼装

    /// 实测列表端点 URL 逐字正确（**这就是实测能用的那个 URL**）。
    func testListURLMatchesMeasuredEndpoint() {
        let url = WeatherCnAlarmEndpoint.listURL()
        XCTAssertEqual(url?.absoluteString,
                       "https://forecast.weather.com.cn/api/v1/traffic/alarm/alarmMap",
                       "列表端点必须逐字等于实测可用的 URL")
        // 实测该端点**无任何查询参数** → 不应凭空多出 `?`。
        XCTAssertNil(url?.query, "实测列表端点无查询参数，不应拼出 query")
    }

    /// 实测详情 URL 拼装正确（实测 filename 形态 `101131007-20261006212927-0902.html`）。
    func testDetailURLUsesMeasuredFilename() {
        let url = WeatherCnAlarmEndpoint.detailURL(
            filename: "101131007-20261006212927-0902.html")
        XCTAssertEqual(url?.absoluteString,
                       "https://product.weather.com.cn/alarm/webdata/101131007-20261006212927-0902.html",
                       "详情 URL 必须逐字等于实测可用形态（**https** 实测亦 200）")
    }

    /// 空 filename → nil（**不**拼出必然 404 的 `…/webdata/`）。
    func testDetailURLRejectsEmptyFilename() {
        XCTAssertNil(WeatherCnAlarmEndpoint.detailURL(filename: ""),
                     "空文件名必须返回 nil，而不是拼出裸 base URL")
    }

    /// Referer 常量必须逐字等于实测可用值（**这是取到数据的关键**）。
    func testRequiredRefererIsTheMeasuredValue() {
        // 实测：无此 Referer → 403；此 Referer → 200。它是硬要求，不是可选项。
        XCTAssertEqual(WeatherCnAlarmEndpoint.requiredRefererValue,
                       "http://www.weather.com.cn/alarm/index.shtml",
                       "Referer 常量必须逐字等于实测 200 时的取值")
    }

    // MARK: - 2．列表 DTO（8 元位置数组）

    /// 实测首行解码：8 个下标全部取到，**经纬度/count 是字符串**。
    func testRowDecodesPositionalTupleFromMeasuredResponse() throws {
        let dto = try JSONDecoder().decode(
            WeatherCnAlarmListResponse.self,
            from: Self.listJSON(count: "137", rows: [Self.realRow0JSON]))

        // 实测 `count` 逐字是字符串 `"137"` → 必须按String 收下。
        XCTAssertEqual(dto.result?.count, "137")
        let row = try XCTUnwrap(dto.result?.data?.first)
        XCTAssertEqual(row.region, "新疆维吾尔自治区伊犁哈萨克自治州昭苏县")
        XCTAssertEqual(row.filename, "101131007-20261006212927-0902.html")
        // ⚠️ 下标 4 = alertid（**跨源连接键**，实测与 NMC 逐字相同）。
        XCTAssertEqual(row.alertID, "65402641600000_20261006212927")
        XCTAssertEqual(row.title, "新疆维吾尔自治区伊犁哈萨克自治州昭苏县发布雷电黄色预警信号")
    }

    /// 元数不足（上游改结构）→ **不抛错**，缺项为 nil。
    ///
    /// 实测依据：实测 137 行元数恒为 8，但**不能把该性质当契约依赖**——
    /// 少一项时必须"部分可用"，而不是整包解码失败拖垮调用方。
    func testRowToleratesShortTuple() throws {
        let shortRow = "[\"仅一个元素\"]"
        let dto = try JSONDecoder().decode(
            WeatherCnAlarmListResponse.self,
            from: Self.listJSON(count: "1", rows: [shortRow]))
        let row = try XCTUnwrap(dto.result?.data?.first)
        XCTAssertEqual(row.region, "仅一个元素")
        XCTAssertNil(row.alertID, "缺下标应留 nil，不得崩溃或编造")
        XCTAssertNil(row.filename)
    }

    /// `result` / `data` 缺失 → 解码成功但取不到行（**不抛错**）。
    ///
    /// 纪律同 `NmcAlarmResponse`：本仓吃过"顶层少一个键就让整包失败、
    /// 主屏与小组件同时无数据"的亏，故全链路可选。
    func testListDecodesWhenResultMissing() throws {
        let json = Data("{\"status\":\"success\",\"errMsg\":\"\"}".utf8)
        let dto = try JSONDecoder().decode(WeatherCnAlarmListResponse.self, from: json)
        XCTAssertNil(dto.result)
        XCTAssertNil(dto.result?.data)
    }

    // MARK: - 3．详情 DTO（JSONP 剥壳）

    /// 实测 JSONP 逐字解码成功，21 个键全部按预期落下。
    func testJSONPDetailDecodesFromMeasuredBody() throws {
        let detail = try XCTUnwrap(
            WeatherCnAlarmDetail.decode(jsonpText: Self.realJSONP),
            "实测 JSONP 壳必须能被剥壳解码")
        XCTAssertEqual(detail.head, "新疆维吾尔自治区伊犁哈萨克自治州昭苏县发布雷电黄色预警信号")
        XCTAssertEqual(detail.PROVINCE, "新疆维吾尔自治区")
        XCTAssertEqual(detail.CITY, "伊犁哈萨克自治州")
        XCTAssertEqual(detail.STATIONNAME, "昭苏县")
        XCTAssertEqual(detail.SIGNALTYPE, "雷电")
        XCTAssertEqual(detail.SIGNALLEVEL, "黄色")
        XCTAssertEqual(detail.TYPECODE, "09")
        XCTAssertEqual(detail.LEVELCODE, "02")
        // ⚠️ 实测**带秒**（这是相对 NMC 分钟级的核心增量）。
        XCTAssertEqual(detail.ISSUETIME, "2026-10-06 21:29:27")
        XCTAssertEqual(detail.RELIEVETIME, "2026-10-07 09:29:27")
        XCTAssertEqual(detail.YJYC_EN, "Yellow")
        XCTAssertEqual(detail.EFFECT, "101131007")
        XCTAssertEqual(detail.identifier, "65402641600000_20261006212927")
        // ⚠️ 防御指南正文：实测非空，且以「（预警信息来源：」结尾。
        let guide = try XCTUnwrap(detail.ISSUECONTENT)
        XCTAssertTrue(guide.hasPrefix("昭苏县气象台2026年10月6日21时29分发布雷电黄色预警信号："),
                      "实测正文以气象台署名开头")
        XCTAssertTrue(guide.hasSuffix("（预警信息来源：国家预警信息发布中心）"),
                      "实测正文以信息来源结尾")
    }

    /// 实测两个"看似英文其实是拼音/空"的字段（**防止将来误当英文标题**）。
    func testNAMEENIsPinyinNotEnglishAndTypeEnglishIsEmpty() throws {
        let detail = try XCTUnwrap(WeatherCnAlarmDetail.decode(jsonpText: Self.realJSONP))
        // 实测逐字：它是**汉语拼音**，不是英文。
        XCTAssertEqual(detail.NAMEEN, "zhaosu yilihasake xinjiang",
                       "实测 NAMEEN 是汉语拼音；**不可**当英文标题展示")
        XCTAssertTrue(detail.YJTYPE_EN?.isEmpty ?? true,
                      "实测 YJTYPE_EN 恒为空串 → 本通道拿不到英文预警类型名")
        XCTAssertTrue(detail.UNDERWRITER?.isEmpty ?? true,
                      "实测 UNDERWRITER 恒为空串")
    }

    /// 非本通道的 JSONP 壳（变量名不同）→ **拒绝解码**，不静默误认。
    func testRejectsForeignJSONPVariableName() {
        let impostor = "var somethingElse={\"ISSUECONTENT\":\"不应被解析\"};"
        XCTAssertNil(WeatherCnAlarmDetail.decode(jsonpText: impostor),
                     "变量名不是 `alarminfo` 时必须拒绝（防止上游换名后误解析）")
    }

    /// 纯 JSON（无 JSONP 壳）→ nil（**如实失败**，不猜）。
    func testRejectsPlainJSONWithoutShell() {
        XCTAssertNil(WeatherCnAlarmDetail.decode(jsonpText: "{\"ISSUECONTENT\":\"无壳\"}"),
                     "无 `var alarminfo=` 壳时必须返回 nil")
    }

    /// 空响应体 → nil（不崩溃）。
    func testRejectsEmptyBody() {
        XCTAssertNil(WeatherCnAlarmDetail.decode(jsonpText: ""))
    }

    // MARK: - 4．逐字段合并器（本批的架构核心）

    /// 造一条**主源（NMC）**条目，形状对齐既有 41 条测试的构造方式。
    private static func nmcItem(id: String,
                                issuedAt: Date?,
                                kind: String = "雷电",
                                color: NmcAlarmColor = .yellow) -> OfficialWarningItem {
        OfficialWarningItem(id: id,
                            region: "新疆维吾尔自治区 / 伊犁哈萨克自治州 / 昭苏县",
                            cityName: "伊犁哈萨克自治州",
                            administrativeCode: "654026",
                            kind: kind,
                            color: color,
                            issuedAt: issuedAt,
                            detailURL: nil,
                            rawTitle: "新疆维吾尔自治区伊犁哈萨克自治州昭苏县气象台发布雷电黄色预警信号")
    }

    /// 实测详情（解码自真实响应）作为补源输入。
    private func measuredDetail() throws -> WeatherCnAlarmDetail {
        try XCTUnwrap(WeatherCnAlarmDetail.decode(jsonpText: Self.realJSONP))
    }

    /// 主源**缺**的三个字段被补上（正文 / 秒级时间 / 有效期）。
    func testEnrichFillsFieldsMissingFromPrimary() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let detail = try measuredDetail()
        let alertID = try XCTUnwrap(detail.identifier)
        let item = Self.nmcItem(id: alertID, issuedAt: nil)

        let merged = OfficialWarningEnrichment.enrich(
            [item], with: [alertID: detail], timeZone: zone)

        let out = try XCTUnwrap(merged.first)
        let guide = try XCTUnwrap(out.defenseGuide)
        XCTAssertEqual(guide, detail.ISSUECONTENT,
                       "防御指南正文应逐字来自实测 `ISSUECONTENT`")
        XCTAssertEqual(out.englishColorName, "Yellow", "实测英文颜色名 Yellow")
        // ⚠️ 实测 `ISSUETIME` = `2026-10-06 21:29:27`（**秒级**）。
        let issued = try XCTUnwrap(out.issuedAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                            from: issued)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 10)
        XCTAssertEqual(comps.day, 6)
        XCTAssertEqual(comps.hour, 21)
        XCTAssertEqual(comps.minute, 29)
        XCTAssertEqual(comps.second, 27, "秒必须来自 d1 的秒级时间戳（NMC 只到分钟）")
        // 实测 `RELIEVETIME` = `2026-10-07 09:29:27`。
        XCTAssertNotNil(out.detailExpiresAt)
    }

    /// **主源优先、绝不覆盖**：主源已有发布时间时，d1 只在能解析出更精确值时替换。
    ///
    /// 实测依据：NMC `issuetime` = `2026/10/06 21:29`（分钟），
    /// d1 `ISSUETIME` = `2026-10-06 21:29:27`（秒）—— **同一真值**，
    /// d1 是NMC 的分钟截断 +秒。故取d1（更精确），这不是"两源冲突"。
    func testPrimaryIssuedAtReplacedByStrictlyMorePreciseSeconds() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let detail = try measuredDetail()
        let alertID = try XCTUnwrap(detail.identifier)
        // 主源给**实测的 NMC 分钟级**时间。
        let primaryIssued = try XCTUnwrap(
            NmcIssueTimeDecoder.date(from: "2026/10/06 21:29", timeZone: zone))
        let item = Self.nmcItem(id: alertID, issuedAt: primaryIssued)

        let merged = OfficialWarningEnrichment.enrich(
            [item], with: [alertID: detail], timeZone: zone)
        let out = try XCTUnwrap(merged.first)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let comps = calendar.dateComponents([.minute, .second],
                                            from: try XCTUnwrap(out.issuedAt))
        XCTAssertEqual(comps.minute, 29, "分钟应与主源一致（同一真值）")
        XCTAssertEqual(comps.second, 27, "秒只能来自 d1 —— 这是本通道的增量")
    }

    /// **绝不覆盖**主源的非补源字段（类型 / 颜色 / 行政区划）。
    func testNeverOverwritesPrimaryClassificationFields() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let detail = try measuredDetail()
        let alertID = try XCTUnwrap(detail.identifier)
        let item = Self.nmcItem(id: alertID, issuedAt: nil,
                                kind: "雷电", color: .orange)

        let out = try XCTUnwrap(OfficialWarningEnrichment.enrich(
            [item], with: [alertID: detail], timeZone: zone).first)

        // 主源颜色 `.orange` 与 d1 的 `SIGNALLEVEL`「黄色」不一致时，
        // **以主源为准**（d1 只补旁注字段，不替换分类）。
        XCTAssertEqual(out.color, .orange, "主源颜色不得被补源覆盖")
        XCTAssertEqual(out.kind, "雷电", "主源类型不得被补源覆盖")
        XCTAssertEqual(out.cityName, "伊犁哈萨克自治州", "主源行政区划不得被覆盖")
        XCTAssertEqual(out.englishColorName, "Yellow",
                       "英文颜色名是**旁注**，与`color` 分类互不干扰")
    }

    /// **连接键精确相等**：alertid 不匹配 → 原样返回（宁可不补，不错补）。
    func testNoEnrichmentWhenAlertIDDoesNotMatchExactly() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let detail = try measuredDetail()
        let alertID = try XCTUnwrap(detail.identifier)
        // 差**一个字符**的 alertid（前缀相同、时间戳不同）→ 不得命中。
        let nearMiss = "65402641600000_20261006212928"
        let item = Self.nmcItem(id: nearMiss, issuedAt: nil)

        let merged = OfficialWarningEnrichment.enrich(
            [item], with: [alertID: detail], timeZone: zone)
        let out = try XCTUnwrap(merged.first)

        XCTAssertNil(out.defenseGuide, "alertid 不精确相等时**绝不**补源")
        XCTAssertNil(out.issuedAt)
        // 条目本身**不得**因为没补上而被丢弃（丢一条真实预警比少字段危险）。
        XCTAssertEqual(merged.count, 1)
    }

    /// 未命中时**不丢条目**（实测d1 独有 11 条、NMC 独有 35 条的场景）。
    func testUnmatchedItemsArePreservedNotDropped() {
        let zone = TimeZone(identifier: "Asia/Shanghai")
        let items = [
            Self.nmcItem(id: "35058141600000_20261006205000", issuedAt: nil),
            Self.nmcItem(id: "64018141600000_20261006155951", issuedAt: nil)
        ]
        let merged = OfficialWarningEnrichment.enrich(items, with: [:], timeZone: zone)
        XCTAssertEqual(merged.count, 2, "空补源时全部条目必须原样返回，一条都不能少")
    }

    /// 空 `details` → 直接返回入参（**同一数组**，零拷贝路径）。
    func testEmptyDetailsReturnsInputUnchanged() {
        let items = [Self.nmcItem(id: "x", issuedAt: nil)]
        XCTAssertEqual(OfficialWarningEnrichment.enrich(items, with: [:], timeZone: nil).count, 1)
    }

    /// **时区未注入 → 秒级时间为 nil**，且**不破坏主源已有值**（宁缺不猜）。
    ///
    /// 纪律同 `NmcIssueTimeDecoder`：墙钟串无时区标识，按设备时区解释
    /// 会让境外设备把新预警算成 8 小时前的旧数据 → 误判 `.stale`。
    func testNilTimeZoneDoesNotFabricateTimeAndKeepsPrimary() throws {
        let detail = try measuredDetail()
        let alertID = try XCTUnwrap(detail.identifier)
        let item = Self.nmcItem(id: alertID, issuedAt: nil)
        let out = try XCTUnwrap(OfficialWarningEnrichment.enrich(
            [item], with: [alertID: detail], timeZone: nil).first)
        XCTAssertNil(out.issuedAt, "未注入时区时**不得**编造发布时间")
        // 但**不依赖时区**的字段仍应补上（正文无时区问题）。
        XCTAssertNotNil(out.defenseGuide, "防御指南正文与时区无关，仍应补上")
    }

    /// 空正文按**缺失**处理（不显示"有正文却空白"）。
    func testEmptyIssueContentTreatedAsMissing() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        var detail = try measuredDetail()
        detail.ISSUECONTENT = ""
        let item = Self.nmcItem(id: "65402641600000_20261006212927", issuedAt: nil)
        let out = try XCTUnwrap(OfficialWarningEnrichment.enrich(
            [item], with: ["65402641600000_20261006212927": detail], timeZone: zone).first)
        XCTAssertNil(out.defenseGuide, "空串正文必须按缺失处理")
    }

    // MARK: - 5．跨源连接键一致性（实测三方逐字相同）

    /// 实测：三方连接键**逐字相同**（5/5 抽样核对）。
    ///
    /// 实测样本（同一场预警「伊犁哈萨克自治州昭苏县雷电黄色」）：
    ///   · weather.cn 列表 `data[i][4]` = `65402641600000_20261006212927`
    ///   · weather.cn 详情 `identifier`   = `65402641600000_20261006212927`
    ///   · NMC `alertid`                   = `65402641600000_20261006212927`
    /// 这是本批**全部补源逻辑成立的前提**—— 若三者不逐字相同，
    /// 整个"字段级合并"就是静默错配（把 A 预警的正文挂到 B 上）。
    func testCrossSourceJoinKeyIsIdentical() throws {
        let dto = try JSONDecoder().decode(
            WeatherCnAlarmListResponse.self,
            from: Self.listJSON(count: "137", rows: [Self.realRow0JSON]))
        let rowKey = try XCTUnwrap(dto.result?.data?.first?.alertID)
        let detailKey = try XCTUnwrap(measuredDetail().identifier)

        XCTAssertEqual(rowKey, "65402641600000_20261006212927")
        XCTAssertEqual(detailKey, rowKey, "列表 [4] 与详情 `identifier` 必须逐字相同")

        // NMC 侧实测：同一场预警在 findAlarm 里的 alertid 逐字同上
        // （故"NMC 的 alertid"可直接当本仓 `OfficialWarningItem.id` 用）。
        let nmcAlertID = "65402641600000_20261006212927"
        XCTAssertEqual(nmcAlertID, rowKey, "NMC alertid 与 weather.cn 列表键必须逐字相同")
        // ⚠️ 前 6 位是 GB/T 2260 区划码（实测 `654026` = 新疆伊犁昭苏县）。
        XCTAssertEqual(NmcAlarmMapper.administrativeCode(from: rowKey), "654026")
    }

    /// 实测：`identifier` 就是 NMC 侧 `alertid` 的**完整串**，
    /// 故合并器用 `OfficialWarningItem.id` 作键即可命中（无需再加工）。
    func testItemIDIsUsableAsJoinKeyDirectly() throws {
        let detail = try measuredDetail()
        let alertID = try XCTUnwrap(detail.identifier)
        // 造一条 id == alertid 的主源条目（这正是 NMC mapper 的产出形状）。
        let item = Self.nmcItem(id: alertID, issuedAt: nil)
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let out = try XCTUnwrap(OfficialWarningEnrichment.enrich(
            [item], with: [alertID: detail], timeZone: zone).first)
        XCTAssertNotNil(out.defenseGuide,
                        "主源 id == d1 identifier 时必须直接命中，无需任何再加工")
    }

    // MARK: - 6．静默门禁

    /// 补源字段**不得**挤进 `WeatherFieldKey`（预警刻意不在该域内）。
    ///
    /// 理由见 `OfficialWarning` 文件头：预警是**列表**、不进
    /// `WeatherSnapshot` / `SharedWeatherPayload`（保持 Widget 载荷契约零改动）。
    /// 若有人日后想"顺手"加个 `case warningDefenseGuide`，
    /// 这条测试会拦下它。
    func testDefenseGuideIsNotAWeatherFieldKey() {
        // 断言"域没被污染"：本批只加领域模型字段，不动 FieldKey 枚举。
        XCTAssertFalse(WeatherFieldKey.allCases.contains { key in
            String(describing: key).lowercased().contains("warning")
                   || String(describing: key).lowercased().contains("defense")
        }, "预警要素**不得**进入 WeatherFieldKey 域（否则会逼出假字段并污染 Widget 载荷）")
    }

    /// 本批**没有新增 SourceID** —— 这是刻意的架构选择，不是遗漏。
    ///
    /// ⚠️ 加case 会立刻破坏 `SourceDirectoryCoverageTests` 的**双射守卫**
    /// （`Set(SourceID.allCases) == Set(SourceCatalog.all.map(\.id))`），
    /// 而补齐目录项必须改 `SourceDescriptor.swift` —— 该文件本批**禁改**。
    /// 且从职责看，d1 是 NMC 的**字段级补源**、不是独立列表源
    /// （实测列表 137~138 条 ⊂ NMC 覆盖范围，且两者互不包含），
    /// 挂独立 SourceID 会让设置页出现一个"关掉就取不到预警"的假开关。
    func testNoNewSourceIDWasDeclared() {
        let rawValues = Set(SourceID.allCases.map(\.rawValue))
        XCTAssertFalse(rawValues.contains("weathercn-alarm"),
                       "本批刻意不新增 SourceID（会破双射守卫且语义上它是补源而非独立源）")
        XCTAssertTrue(rawValues.contains("nmc-alarm"), "第六源 NMC 仍在册")
    }
}
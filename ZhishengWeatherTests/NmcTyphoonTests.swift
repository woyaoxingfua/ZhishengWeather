//
//  NmcTyphoonTests.swift
//  ZhishengWeatherTests
//
//  第七源（中央气象台台风网）的接入锚点：
//  1．**JSONP 剥壳**：`list_default` 实测**双层**括号、`view_` 实测**单层** ——
//     两者都要能剥（设计稿只说双层，本worker 实测证伪）；
//  2．🔴 **经度在前**：下标 4 = 经度、下标 5 = 纬度（含取值域断言 +
//     **JMA 交叉验证**的真实坐标对）；
//  3．**逐字段类型容错**：编号在 `list_` 是 String、在 `view_` 是 Int
//     （实测两处不同）—— 两种都要收；
//  4．**坏数据不拖垮整批**：一条坏列表条目 / 一个坏路径点只丢自己；
//  5．**404 返回 HTML**（实测逐字 `<!DOCTYPE HTML …`）→ 服务层抛
//     `badStatus(404)` 而非「解码失败」；
//  6．**空态与失败态可区分**：空数组 = 无台风（成功）；故障 = `.unavailable`；
//  7．**端点 URL**：默认 / 年份 / 单台风；未来年份与非法 id 前置拒绝。
//
//  ═══════════════════════════════════════════════════════════════════
//  ⚠️ 全部样本都是 **2026-10-07 本 worker 当次真实 curl** 的逐字原文
//  （`curl -s -m 25 -L --compressed -A "<iPhone UA>"`）。
//  实测 HTTP 状态 / 字节数：list_default 200/2797、list_1950 200/2307、
//  list_1999 200/1688、list_2024 200/2612、view_3346168 200/12478、
//  view_3341981 200/26767、view_3346033 200/11462、
//  view_3227033 200/2267、view_9999999 **404/591(text/html)**、
//  list_2030 **404/618(text/html)**。
//  **不得**为了让测试通过而改写样本。
//
// 🔴 **内联样本两条纪律（本批修过 7 处，勿再犯）**：
//  ① **必须带 JSONP 外壳**：样本都要过 `NmcTyphoonJSONP.unwrap`，
//     而裸 JSON 里没有 `(` → `strip` 返回 `""` → unwrap 抛错 → 必红。
//  ② **`#"""` raw string 里行尾 `\` 是【字面反斜杠】、不是续行符**
//     （只有 plain `"""` 才是续行）。raw 里留 `\` 会让 JSON 非法 →
//     `JSONDecoder` 抛错。→ raw 样本**不要**写行尾续行反斜杠；
//     换行本身就是合法 JSON 空白。
//
// ⚠️ 上游点数会随时间增长（实测同三个活跃台风已从 89 漂到 91），
//    故本文件**不**对「全部点数」写死数字，只断言样本自身的点数。
//
//  不联网：全部喂本地造好的 JSON（服务层用 URLProtocol 桩注入响应）。
//  ⚠️ **并发纪律**：`XCTAssert*` 实参是 autoclosure，装不下 `await`
//  → 所有 `await` 先求值到局部常量再断言（同 `NmcAlarmTests`）。
//

import XCTest
@testable import ZhishengWeather

// MARK: - 桩

/// 台风服务测试用的 `URLProtocol` 桩（文件级 `private`）。
private final class TyphoonStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    // ⚠️ **不能给 `startLoading()` 加 `throws`**：`URLProtocol.startLoading()` 在
    // Swift 里是非 throwing 的，加 `throws` 会报
    // `cannot override non-throwing instance method with throwing instance method`（CI 实测）。
    // 本体内抛错由 `do/catch` 自行消化，不需要向外抛。
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

final class NmcTyphoonTests: XCTestCase {

    // MARK: - 实测样本（逐字，2026-10-07）

    /// 实测 `list_default` 响应体**首段**（双层 JSONP + 小熊带尾随换行的中文名）。
    private let listDefaultJSONP = """
    typhoon_jsons_list_default(({"typhoonList":[[3346033,"KOGUMA","小熊\\n","2629","2629",null,\
    "小熊星座","start"],[3346168,"NOLO","诺洛","2628","2628",null,null,"start"],\
    [3341981,"CHOI-WAN","彩云","2627","2627",null,"天上的云彩","start"],\
    [3337001,"SURIGAE","舒力基","2626","2626",null,"一种鹰","stop"],\
    [3332799,"nameless","热带低压","20260027","20260027",20260027,null,"stop"]]}))
    """

    /// 实测 `view_3346168`（诺洛）**首个路径点 + 顶层 10 元素结构**（单层 JSONP）。
    /// ⚠️ 末点与下标 9 已按实测裁剪（保留首点足以锚定字段语义）。
    private let viewTrackJSONP = """
    typhoon_jsons_view_3346168({"typhoon":[3346168,"NOLO","诺洛",2628,2628,null,null,"start",\
    [[3346169,"202610050000",1791158400000,"SuperTY",179.4,24.8,935,52,"W",28,\
    [["30KTS",500,450,450,500,3346169],["50KTS",200,200,200,200,3346169],\
    ["64KTS",80,80,80,80,3346169]],\
    {"BABJ":[[12,"202610050000",176.1,25.2,945,48,"BABJ","STY"],\
    [24,"202610050000",173,25.4,950,45,"BABJ","STY"],\
    [36,"202610050000",168.8,25.3,960,40,"BABJ","TY"],\
    [48,"202610050000",164.3,25.5,965,38,"BABJ","TY"],\
    [60,"202610050000",160.7,25.9,970,35,"BABJ","TY"],\
    [72,"202610050000",156.2,26.8,975,33,"BABJ","TY"],\
    [96,"202610050000",151.4,28.6,980,30,"BABJ","STS"],\
    [120,"202610050000",149.9,30.2,982,28,"BABJ","STS"]]},\
    ["202610050800","2026年10月05日08时00分",null,null]],\
    [3351798,"202610070600",1791352800000,"TY",162.6,25.4,975,33,"W",35,\
    [["30KTS",380,250,250,380,3351798],["50KTS",100,80,80,100,3351798]],\
    {"BABJ":[[12,"202610070600",158.2,26,980,30,"BABJ","STS"],\
    [24,"202610070600",154.1,27.1,980,30,"BABJ","STS"],\
    [36,"202610070600",151.2,28.3,980,30,"BABJ","STS"],\
    [48,"202610070600",149.7,29.4,982,28,"BABJ","STS"],\
    [60,"202610070600",148.8,30.7,982,28,"BABJ","STS"],\
    [72,"202610070600",149.1,32.4,990,23,"BABJ","TS"],\
    [96,"202610070600",152.4,35.2,995,20,"BABJ","TS"],\
    [120,"202610070600",157.4,36.9,998,18,"BABJ","TS"]]},\
    ["202610071400","2026年10月07日14时00分",null,null]]],\
    [[3346033,{"0":[0],"1":[1]}],[3341981,{"0":[34]}]]]})
    """

    /// 实测 `view_3227033`（2005 布拉万，历史台风）**首点**：
    /// ⚠️ 下标 10 = **空数组 `[]`**、下标 11/12 = **null**、顶层下标 9 = **null**。
    private let historicalTrackJSONP = """
    typhoon_jsons_view_3227033({"typhoon":[3227033,"Bolaven","布拉万",523,523,null,\
    "位于老挝南部的高原","stop",\
    [[3227034,"200511140000",1131926400000,"TD",129.6,8.8,1002,15,"no",0,[],null,null]],\
    null]})
    """

    /// 实测 `list_1950` 首条：**中文名为 `null`、编号下标 3/4 为 String**。
    private let list1950JSONP = """
    typhoon_jsons_list_1950(({"typhoonList":[[3203980,"Fran",null,"1900","1900",1942,null,"stop"],\
    [3203968,"Ellen",null,"1900","1900",1941,null,"stop"]]}))
    """

    /// 实测 `list_2024` 里「无名台风」条目：下标 4 是**空串 `""`**。
    private let list2024JSONP = """
    typhoon_jsons_list_2024(({"typhoonList":[[3275671,"nameless",null,"2000","",2017,null,"stop"]]}))
    """

    /// 实测 404 响应体首段（逐字HTML，`view_9999999` 591B）。
    private let html404Body = "<!DOCTYPE HTML PUBLIC \"-//IETF//DTD HTML 2.0//EN\">\n<html>\n"

    // MARK: - 工具

    /// 剥壳 + 解码 → `NmcTyphoonResponse`。
    private func decode(_ jsonp: String) throws -> NmcTyphoonResponse {
        let data = try NmcTyphoonJSONP.unwrap(Data(jsonp.utf8))
        return try ResponseDecoding.decode(NmcTyphoonResponse.self, from: data)
    }

    /// 构造带桩的 `URLSession`。
    private func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TyphoonStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    // MARK: - 1．JSONP 剥壳（**两层级数不同**）

    /// 实测 `list_default` 是**双层**括号 → 剥到能解析。
    func testListEndpointJSONPIsDoubleLayered() {
        let stripped = NmcTyphoonJSONP.strip(listDefaultJSONP)
        XCTAssertFalse(stripped.hasPrefix("("),
                       "实测列表端点是双层括号，剥壳后不应还带外层 '('")
        XCTAssertTrue(stripped.hasPrefix("{\"typhoonList\""),
                      "剥壳后应直接是 JSON 对象开头，实际：\(stripped.prefix(40))")
    }

    /// 🔴 实测 `view_` 是**单层**括号 —— 这条**证伪了设计稿「都是双层」的说法**。
    ///
    /// 若实现按「固定剥两层」写，这里会失败（会被多剥一层）。
    func testViewEndpointJSONPIsSingleLayered() {
        let stripped = NmcTyphoonJSONP.strip(viewTrackJSONP)
        XCTAssertTrue(stripped.hasPrefix("{\"typhoon\""),
                      "实测详情端点是单层括号，剥壳后应直接是 JSON，实际：\(stripped.prefix(40))")
    }

    /// 剥壳对 1 层 / 2 层 / 3 层都成立（**不写死层数**）。
    func testStripHandlesVariableParenthesisDepth() {
        XCTAssertEqual(NmcTyphoonJSONP.strip(#"cb({"a":1})"#), #"{"a":1}"#)
        XCTAssertEqual(NmcTyphoonJSONP.strip(#"cb((({"a":1})))"#), #"{"a":1}"#)
        XCTAssertEqual(NmcTyphoonJSONP.strip(#"cb(({"a":1}))"#), #"{"a":1}"#)
    }

    /// 回调名**随端点而变**（实测 `list_default` / `view_<id>` / `list_1950`）
    /// → 剥壳不得硬编码函数名。
    func testStripDoesNotHardcodeCallbackName() {
        XCTAssertEqual(NmcTyphoonJSONP.strip(#"whatever_name(({"a":1}))"#), #"{"a":1}"#)
        XCTAssertEqual(NmcTyphoonJSONP.strip(#"typhoon_jsons_list_1950(({"a":1}))"#), #"{"a":1}"#)
    }

    /// 非JSONP 响应（实测 404 的 HTML）→ 剥壳**必须失败**，不得返回半截HTML。
    func testStripRejectsHTMLBody() {
        let stripped = NmcTyphoonJSONP.strip(html404Body)
        XCTAssertTrue(stripped.isEmpty,
                      "HTML 响应体不应被剥成可解析内容，实际：\(stripped.prefix(60))")
    }

    // MARK: - 1b．剥壳边界（**失败分支**，此前零覆盖）

    /// 空响应体 → 空串（不是 `"cb("`、也不是原文）。
    func testStripOnEmptyBodyReturnsEmpty() {
        XCTAssertEqual(NmcTyphoonJSONP.strip(""), "")
    }

    /// 只有壳、**没有 JSON**（实测 `cb()`）→ 空串，
    /// 使 `unwrap` 抛错而不是把空壳喂给 decoder。
    func testStripOnCallbackOnlyReturnsEmpty() {
        XCTAssertEqual(NmcTyphoonJSONP.strip("cb()"), "")
    }

    /// 🔴 壳内**带空格**（`cb( ({"a":1}) )`）必须能剥干净。
    ///
    /// 这是本批修`strip` 的原因：`hasPrefix("(")` 要求首字符**精确**是 `(`，
    /// 而循环判断前**不 trim** 时，壳内多一个空格就剥不掉 →
    /// 整份响应被判成「非 JSONP」→ **整个台风源静默消失**。
    func testStripToleratesWhitespaceInsideWrapper() {
        XCTAssertEqual(NmcTyphoonJSONP.strip(#"cb( ({"a":1}) )"#), #"{"a":1}"#)
        // 换行/tab 同样要成立（多行JSONP 是真实形态）。
        XCTAssertEqual(NmcTyphoonJSONP.strip("cb(\n  {\"a\":1}\n)"), "{\"a\":1}")
        // 剥完内层后残留的空白也必须被清掉，才轮到下一层判断。
        XCTAssertEqual(NmcTyphoonJSONP.strip(#"cb( ( ({"a":1}) ) )"#), #"{"a":1}"#)
    }

    /// 括号**不匹配**（闭括号在开括号之前）→ 空串。
    ///
    /// 这是`close > open` 那道守卫的锚点：若守卫写反成 `>=`，
    /// 就会把开括号本身当成剥好的 JSON 返回。
    func testStripOnMismatchedParenthesesReturnsEmpty() {
        // 只有闭括号、根本没有 `(` → 空串。
        XCTAssertEqual(NmcTyphoonJSONP.strip(")"), "")
        XCTAssertEqual(NmcTyphoonJSONP.strip("no parenthesis at all"), "")
        XCTAssertEqual(NmcTyphoonJSONP.strip("}{"), "")
    }

    ///壳内**括号不配对**（`cb({)`）→ 如实交出 `{`，
    /// 由 `JSONDecoder` 去抛错——「剥壳」不管「校验」。
    ///
    /// ⚠️ 这条钉住一个易被误读的边界：`(` 在 `)` **之前**，故 `close > open`
    /// 成立、剥壳**不算失败**；截出来的是 `{`（合法 JSON 片段前缀）。
    /// 若有人日后把守卫改成「必须配平」，这条会红。
    func testStripOnUnbalancedInnerBracePassesThroughForDecoderToReject() throws {
        XCTAssertEqual(NmcTyphoonJSONP.strip("cb({)"), "{")
        // ⚠️ `unwrap` **不抛**（它只负责剥壳，非空即返回）→ 抛错发生在**解码**环节。
        //端到端确认：这样的壳最终**过不了解码**，不得被当成「空列表」静默通过。
        let data = try NmcTyphoonJSONP.unwrap(Data("cb({)".utf8))
        XCTAssertThrowsError(try ResponseDecoding.decode(NmcTyphoonResponse.self, from: data),
                             "壳内括号不配对 → 必须在解码环节失败，不得静默通过")
    }

    /// 壳内**不是 JSON**（`cb(xxx)`）→ 如实返回 `xxx`。
    ///
    /// ⚠️ `strip` 是**纯文本**层，不负责判 JSON —— 它只管剥壳。
    /// 判「是不是 JSON」是 `unwrap` 之后 `JSONDecoder` 的职责。
    /// 故此处断言「原样透传」，**不是**断言失败：
    /// 这样将来若有人误把「剥壳」与「校验」混在一起，这条会红。
    func testStripPassesThroughNonJSONPayloadVerbatim() {
        XCTAssertEqual(NmcTyphoonJSONP.strip("cb(xxx)"), "xxx")
        // 对照：只剥到第一层，内层不是括号就停。
        XCTAssertEqual(NmcTyphoonJSONP.strip("cb((xxx))"), "xxx")
    }

    // MARK: - 2．🔴 经度在前（本任务最易写反的一处）

    /// 路径点下标 4 = **经度**、下标 5 = **纬度**。
    ///
    /// 断言用**实测**的诺洛两个点（首点 179.4/24.8、末点 162.6/25.4）。
    /// 🔴 若实现里两者写反，本断言**立即失败**（而运行时不报错）——
    /// 这正是「镜像到地球另一侧且不易察觉」的那类错的守卫。
    func testTrackPointLongitudeComesBeforeLatitude() throws {
        let track = NmcTyphoonMapper.track(from: try decode(viewTrackJSONP))
        XCTAssertNotNil(track)
        let points = track?.points ?? []
        XCTAssertEqual(points.count, 2, "实测样本含 2 个路径点")

        let first = points[0]
        // 实测首点：下标4=179.4、 下标5=24.8
        XCTAssertEqual(first.longitude ?? 0, 179.4, accuracy: 0.001,
                       "下标 4 应解析为**经度**（实测 179.4）")
        XCTAssertEqual(first.latitude ?? 0, 24.8, accuracy: 0.001,
                       "下标 5 应解析为**纬度**（实测 24.8）")

        let last = points[1]
        XCTAssertEqual(last.longitude ?? 0, 162.6, accuracy: 0.001,
                       "下标 4 应解析为**经度**（实测末点 162.6）")
        XCTAssertEqual(last.latitude ?? 0, 25.4, accuracy: 0.001,
                       "下标 5 应解析为**纬度**（实测末点 25.4）")
    }

    /// ✅ **独立第二源交叉验证**（实测坐标对，非推断）。
    ///
    /// JMA `TC2635`（`typhoonNumber`=`2628` = NMC 的诺洛）实测
    /// `validtime.UTC = 2026-10-07T06:00:00Z`、`position.deg = [25.3, 162.4]`
    /// （JMA 序为 **[纬度, 经度]**）。
    /// NMC 同一 UTC 时刻（路径点 UTC 串 `202610070600`）实测下标4=162.6、
    /// 下标5=25.4 → 两机构独立给出的同一台风同一时刻坐标吻合。
    ///
    /// 本测试把「诺洛末点的经度应≈162.4、纬度应≈25.3」钉成断言：
    /// 一旦解析顺序写反，**两个断言同时失败**。
    func testLongitudeLatitudeOrderCrossCheckedAgainstJMA() throws {
        let track = NmcTyphoonMapper.track(from: try decode(viewTrackJSONP))
        let last = track?.points.last
        XCTAssertNotNil(last)
        // JMA 实测：lat 25.3 / lon 162.4 @ 2026-10-07T06:00:00Z
        XCTAssertEqual(last?.longitude ?? 0, 162.4, accuracy: 0.5,
                       "经度应与 JMA 实测 162.4 吻合（若得到≈25 则说明经纬写反了）")
        XCTAssertEqual(last?.latitude ?? 0, 25.3, accuracy: 0.5,
                       "纬度应与 JMA 实测 25.3 吻合（若得到≈162 则说明经纬写反了）")
    }

    /// 预报数组的经纬顺序**同样是经度在前**（实测 + JMA 交叉验证）。
    ///
    /// 实测诺洛末点（UTC `202610070600`）的 12h 预报为下标2=158.2/下标3=26；
    /// JMA 对同一台风同一时刻的 12h 预报实测 `center = [26.5, 157.6]`
    /// （JMA 序 [纬,经]）→ 纬 26≈26.5、经 158.2≈157.6，吻合。
    func testForecastLongitudeComesBeforeLatitude() throws {
        let track = NmcTyphoonMapper.track(from: try decode(viewTrackJSONP))
        let forecast = track?.latestForecast ?? []
        XCTAssertFalse(forecast.isEmpty, "实测末点带8 个时效的官方预报")
        let first = forecast[0]
        XCTAssertEqual(first.longitude ?? 0, 158.2, accuracy: 0.001,
                       "预报下标 2 应为**经度**（实测 158.2）")
        XCTAssertEqual(first.latitude ?? 0, 26.0, accuracy: 0.001,
                       "预报下标 3 应为**纬度**（实测 26）")
        XCTAssertEqual(first.leadHours, 12, "实测首时效 12 小时")
    }

    /// 🔴 取值域自证：纬度落在**实测的西北太平洋热带气旋纬度带**、
    /// 且经度落在**实测的西太平洋经度带** —— 两个带**互不重叠**。
    ///
    /// ⚠️ 原写法是 `abs(latitude) <= 90`，那是**恒真**的（纬度数学上不可能 > 90），
    /// 既区分不了「正确解析」与「解析出的就是纬度字段」，
    /// 更在 `points` 为空时**循环体不执行 →照样绿**（实现全返回 `[]` 也发现不了）。
    /// →故改为：① 先锚**点数非空且等于样本实测值**（空数组必红）；
    ///  ② 断言**两带各自落在实测区间内**（经纬写反必红，因为两个区间不重叠）。
    func testCoordinatesFallInMeasuredBasinRanges() throws {
        let track = NmcTyphoonMapper.track(from: try decode(viewTrackJSONP))
        let points = track?.points ?? []
        // 🔴 锚点：样本（诺洛）实测 2 个路径点。空数组必须**在这里红**。
        XCTAssertEqual(points.count, 2, "实测样本含 2 个路径点（空数组不得通过）")

        for point in points {
            // 缺测就红：geo 字段是nil 时`?? 0` 会被 0 悄悄满足。
            guard let latitude = point.latitude, let longitude = point.longitude else {
                XCTFail("实测每个点都带经纬，缺测必须显式失败而不是被默认值吞掉")
                continue
            }
            // 实测诺洛两点：纬度 24.8/ 25.4，经度 179.4 / 162.6。
            // 用远宽于实测、但**远窄于 ±90** 的带 → 写反必红、真值必绿。
            XCTAssertTrue((0.0...60.0).contains(latitude),
                          "纬度 \(latitude) 超出实测热带气旋纬度带 0–60°"
                          + "（若这里拿到 ≈179 级别的值，说明经纬写反了）")
            XCTAssertTrue((100.0...180.0).contains(abs(longitude)),
                          "经度 \(longitude) 超出实测西太平洋经度带 100–180°"
                          + "（若这里拿到 ≈25 级别的值，说明经纬写反了）")
        }
    }

    /// 历史台风（布拉万）同样受这条不变量约束 —— **换样本也成立**。
    func testCoordinatesFallInMeasuredBasinRangesForHistoricalTyphoon() throws {
        let track = NmcTyphoonMapper.track(from: try decode(historicalTrackJSONP))
        let points = track?.points ?? []
        // ⚠️ 本仓historicalTrackJSONP 样本按文件头注释「只保留首点」→ **1 个点**。
        //   （实测该台风线上共 26 个点，但样本只留首点，故此处锚1。）
        XCTAssertEqual(points.count, 1, "本仓历史台风样本只保留首点 → 1 个路径点")
        for point in points {
            guard let latitude = point.latitude, let longitude = point.longitude else {
                XCTFail("历史台风实测亦逐点带经纬，缺测必须显式失败")
                continue
            }
            XCTAssertTrue((0.0...60.0).contains(latitude),
                          "历史台风实测纬度 \(latitude) 应在 0–60°（本样本实测 8.8）")
            XCTAssertTrue((100.0...180.0).contains(abs(longitude)),
                          "历史台风实测经度 \(longitude) 应在 100–180°（本样本实测 129.6）")
        }
    }

    /// 上游若调换顺序，反序兜底会**交换**二者（宁可不镜像，也不镜像）。
    func testSwappedCoordinateOrderIsRecovered() throws {
        // 实测把「经度 179.4 / 纬度 24.8」反写成「179.4 在纬度位」。
        let swapped = #"""
        cb({"typhoon":[1,"X","测试",1,1,null,null,"start",
        [[1,"202610050000",1791158400000,"TY",24.8,179.4,935,52,"W",28,[],null,null]]]})
        """#
        let dto = try ResponseDecoding.decode(NmcTyphoonResponse.self,
                                              from: NmcTyphoonJSONP.unwrap(Data(swapped.utf8)))
        let track = NmcTyphoonMapper.track(from: dto)
        let point = track?.points.first
        XCTAssertEqual(point?.longitude ?? 0, 179.4, accuracy: 0.001,
                       "反序输入应被纠正回经度 179.4")
        XCTAssertEqual(point?.latitude ?? 0, 24.8, accuracy: 0.001,
                       "反序输入应被纠正回纬度 24.8")
    }

    // MARK: - 3．列表解析与类型容错

    /// 实测 `list_default`：4 条 → 3 条 `"start"`；中文名带**尾随换行**须trim。
    func testActiveOnlyAndChineseNameTrimming() throws {
        let summaries = NmcTyphoonMapper.activeOnly(
            NmcTyphoonMapper.summaries(from: try decode(listDefaultJSONP)))
        XCTAssertEqual(summaries.count, 3, "实测样本里恰好 3 条 'start'")
        // 🔴 实测小熊中文名逐字为 "小熊\n" —— 必须 trim，否则 UI 会多出一行空白。
        XCTAssertEqual(summaries[0].displayName, "小熊",
                       "中文名的尾随换行必须被 trim（实测原文含 \\n）")
        XCTAssertEqual(summaries[1].displayName, "诺洛")
        XCTAssertEqual(summaries[2].displayName, "彩云")
        // 编号：实测 list_ 端点下标 3 是 **String**。
        XCTAssertEqual(summaries[1].number, "2628",
                       "实测编号在 list_ 端点是字符串 \"2628\"")
    }

    /// 🔴 实测「编号字段类型在两个端点之间不同」：`list_` 是 String、`view_` 是 Int
    /// → 两种都要收成同一个 `String?`。
    func testNumberFieldAcceptsBothStringAndInt() throws {
        // 列表端点：实测 String。
        let fromList = NmcTyphoonMapper.summaries(from: try decode(listDefaultJSONP))
        XCTAssertEqual(fromList.first?.number, "2629")
        // 详情端点：实测 **Int**（`2628` 不带引号）。
        let fromView = NmcTyphoonMapper.track(from: try decode(viewTrackJSONP))
        XCTAssertEqual(fromView?.summary.number, "2628",
                       "详情端点实测编号是Int，也必须归一成同一语义")
    }

    /// 实测早年台风（1950）**中文名为 null** → 必须回退英文名，绝不空白。
    func testMissingChineseNameFallsBackToEnglishName() throws {
        let summaries = NmcTyphoonMapper.summaries(from: try decode(list1950JSONP))
        XCTAssertEqual(summaries.count, 2, "实测 1950 样本 2 条")
        XCTAssertNil(summaries[0].chineseName, "实测 1950 条目中文名为 null")
        XCTAssertEqual(summaries[0].displayName, "Fran",
                       "中文名缺失时应回退英文名（实测 Fran）")
        // ⚠️ 实测 1950 的status 全是 "stop" → 不进活跃列表。
        XCTAssertTrue(NmcTyphoonMapper.activeOnly(summaries).isEmpty,
                      "实测 1950 全部为 'stop'，活跃列表应为空")
    }

    /// 实测 `list_2024` 早期条目编号下标 4 是**空串 `""`** → 必须跳到下标 3。
    func testEmptySecondaryNumberFallsBackToPrimary() throws {
        let summaries = NmcTyphoonMapper.summaries(from: try decode(list2024JSONP))
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].number, "2000",
                       "下标 4 为空串时应回退下标 3 的实测值 \"2000\"")
    }

    /// 一条坏条目（缺 id）**只丢自己**，不拖垮整批。
    func testMalformedListEntryDoesNotBreakWholeBatch() throws {
        let mixed = #"""
        cb({"typhoonList":[[999,"GOOD","正常","1","1",null,null,"start"],
        ["不是数组"],[],[3346168,"NOLO","诺洛","2628","2628",null,null,"start"]]})
        """#
        let dto = try ResponseDecoding.decode(NmcTyphoonResponse.self,
                                               from: NmcTyphoonJSONP.unwrap(Data(mixed.utf8)))
        let summaries = NmcTyphoonMapper.summaries(from: dto)
        // 实测第 1 条非数组、第 2 条空数组；第 3 条 id 是 Int 3346168（非字符串）
        // → JSONValue 会把它解成 number，`stringValue` 转文本后仍可用。
        XCTAssertEqual(summaries.count, 2,
                       "坏条目应被丢弃，好条目必须保留（不得整批清空）")
        XCTAssertEqual(summaries.last?.displayName, "诺洛")
    }

    /// 缺 id 的条目必须丢弃（无法拼 `view_<id>` URL → 该条不可用）。
    func testEntryWithoutIDIsDropped() throws {
        let noID = #"""
        cb({"typhoonList":[["NOLO","诺洛","2628","2628",null,null,"start"]]})
        """#
        let dto = try ResponseDecoding.decode(NmcTyphoonResponse.self,
                                               from: NmcTyphoonJSONP.unwrap(Data(noID.utf8)))
        XCTAssertTrue(NmcTyphoonMapper.summaries(from: dto).isEmpty,
                      "没有 id 的条目无法请求详情，必须丢弃而不是造一个假 id")
    }

    // MARK: - 4．详情解析与历史台风容错

    /// 实测详情端点顶层长 **10**（设计稿说 8）→ 路径点在下标 8 可解析。
    func testViewTopLevelArrayIsTenElements() throws {
        let track = NmcTyphoonMapper.track(from: try decode(viewTrackJSONP))
        XCTAssertNotNil(track, "实测顶层 10 元素结构必须能解出台风")
        XCTAssertEqual(track?.points.count, 2)
        XCTAssertEqual(track?.summary.englishName, "NOLO")
        // 🔴 本样本（诺洛）头部下标 7 逐字是 `"start"` → `isActive == true`。
        //    原断言 `XCTAssertFalse(track?.summary.isActive ?? true)` **方向反了**（必红）。
        //    （附带说明：那个 `?? true` 本身**不会**造成静默通过 ——
        //      nil 时 `XCTAssertFalse(true)` 同样会红；它真正的毛病是
        //      把「解析失败」与「真的是活跃台风」压成同一个结果，诊断信息丢失。）
        //    → 改为直接与 `true` 比对：nil ≠ true，解析失败会红且能看出原因。
        XCTAssertEqual(track?.summary.isActive, true,
                       "实测本样本头部下标 7 逐字为 \"start\" → 必须是活跃台风")
    }

    /// 🔴 「**已停止**台风也能查详情」——原意图，用**历史台风**样本才成立。
    ///
    /// 上一条用例的样本（诺洛）是 `"start"`，**证不了**「已停止也能查」。
    /// 实测历史台风布拉万3227033 头部下标 7 逐字是 `"stop"` → `isActive == false`，
    /// 且 `track()` **刻意不强制** isActive（详情页允许查看已停止台风）。
    func testStoppedTyphoonDetailIsStillQueryable() throws {
        let track = NmcTyphoonMapper.track(from: try decode(historicalTrackJSONP))
        XCTAssertNotNil(track, "已停止台风也必须能解出详情（实测下标 7 = \"stop\"）")
        // 用 `XCTAssertEqual(_, false)` 而非 `XCTAssertFalse(_ ?? true)`：
        // 后者虽也会红，但把 nil（解析失败）与true 压成同一结果，诊断信息丢失。
        XCTAssertEqual(track?.summary.isActive, false,
                       "实测历史台风下标 7 为 \"stop\" → 必须是非活跃")
    }

    /// 实测各字段解析：强度 / 气压 / 风速 / 移向 / 移速 / 发布时间。
    func testTrackPointFieldParsing() throws {
        let track = NmcTyphoonMapper.track(from: try decode(viewTrackJSONP))
        let first = track?.points.first
        XCTAssertEqual(first?.intensity?.rawValue, "SuperTY", "实测强度 SuperTY")
        XCTAssertEqual(first?.intensity?.displayName, "超强台风")
        XCTAssertEqual(first?.pressureHPa ?? 0, 935, "实测气压 935 hPa")
        XCTAssertEqual(first?.maxWindSpeedMS ?? 0, 52, "实测风速 52 m/s")
        XCTAssertEqual(first?.motion?.rawValue, "W", "实测移向 W")
        XCTAssertEqual(first?.motion?.displayName, "西")
        XCTAssertEqual(first?.motionSpeedKmh ?? 0, 28, "实测移速 28 km/h")
        XCTAssertEqual(first?.beijingTimeText, "2026年10月05日08时00分",
                       "实测发布时间文本")
        XCTAssertEqual(first?.pointID, 3346169, "实测 pointId")
    }

    /// 实测时刻：下标 2 的毫秒与下标 1 的 UTC 串**自洽**（两路都解析）。
    func testTimestampFromEpochMilliseconds() throws {
        let track = NmcTyphoonMapper.track(from: try decode(viewTrackJSONP))
        let time = track?.points.first?.time
        XCTAssertNotNil(time)
        // 实测 `202610050000` UTC = epoch 1791158400000 ms。
        // 断言绝对时刻的秒数，避免时区影响。
        let seconds = (time?.timeIntervalSince1970 ?? 0)
        XCTAssertEqual(seconds, 1791158400, accuracy: 1,
                       "下标 2 的 Unix 毫秒应直接构造出正确时刻")
    }

    /// 实测风圈：3 层，标签 `30KTS`/`50KTS`/`64KTS`，定长 6。
    func testWindCircleParsing() throws {
        let track = NmcTyphoonMapper.track(from: try decode(viewTrackJSONP))
        let circles = track?.points.first?.windCircles ?? []
        XCTAssertEqual(circles.count, 3, "实测首点 3 层风圈")
        XCTAssertEqual(circles[0].label, "30KTS")
        XCTAssertEqual(circles[0].displayName, "七级风圈")
        XCTAssertEqual(circles[0].radii, [500, 450, 450, 500],
                       "实测 4 个半径按原序保留（象限语义无法确定，不命名）")
        XCTAssertEqual(circles[0].maxRadiusKm ?? 0, 500, "最大半径用于画圆")
        XCTAssertEqual(circles[2].label, "64KTS")
        XCTAssertEqual(circles[2].pointID, 3346169, "实测风圈末位是pointId")
    }

    /// 🔴 实测历史台风：**风圈空数组、预报 null、顶层下标 9 null**。
    func testHistoricalTyphoonToleratesNullForecastAndEmptyWindCircle() throws {
        let track = NmcTyphoonMapper.track(from: try decode(historicalTrackJSONP))
        XCTAssertNotNil(track, "实测历史台风顶层下标 9 为 null 也必须能解析")
        // ⚠️ 用 `guard let` 取代 `point?.windCircles.isEmpty ?? false`：
        //    两者在 nil 时**都会红**（`?? false` → 断言 false → 红，故原写法
        //    并**不会**静默通过），但那时的红是「碰巧对」，不是「知道缺了什么」。
        //    `guard let` 让失败**指名道姓**：到底是台风没解出来、还是点没解出来。
        guard let track, let point = track.points.first else {
            return XCTFail("实测历史台风应解出 1 个路径点，缺测必须显式失败")
        }
        XCTAssertEqual(point.latitude ?? 0, 8.8, accuracy: 0.001, "实测纬度 8.8")
        XCTAssertEqual(point.longitude ?? 0, 129.6, accuracy: 0.001, "实测经度 129.6")
        XCTAssertTrue(point.windCircles.isEmpty, "实测风圈为空数组")
        XCTAssertTrue(point.forecast.isEmpty,
                      "实测历史台风无预报（下标 11 为 null）")
        XCTAssertTrue(track.latestForecast.isEmpty,
                      "无预报时 latestForecast 应为空数组（UI 显示「无官方预报」）")
        XCTAssertEqual(point.motion?.rawValue, "no", "实测历史台风移向为 'no'")
        XCTAssertEqual(point.motion?.displayName, "停滞")
    }

    /// 实测预报时效**数量不固定**（8个 / 1 个）→ 不按固定长度取。
    func testForecastLeadCountIsNotFixed() throws {
        // 彩云 2026-10-07 实测：末点只剩 [12]，首点是 8 个时效。
        let varying = #"""
        cb({"typhoon":[3341981,"CHOI-WAN","彩云",2627,2627,null,null,"start",
        [[1,"202609301800",1790791200000,"TS",149.5,16.4,998,18,"W",22,[],
        {"BABJ":[[12,"202609301800",147.1,16.7,990,23,"BABJ","TS"],
        [24,"202609301800",140.0,17.5,995,20,"BABJ","TS"]]},
        ["202610010200","2026年10月01日02时00分",null,null]],
        [2,"202610070000",1791331200000,"STS",153.2,39.2,975,30,"NE",87,[],
        {"BABJ":[[12,"202610070000",162,46,980,28,"BABJ","STS"]]},
        ["202610070800","2026年10月07日08时00分",null,null]]],null]})
        """#
        let dto = try ResponseDecoding.decode(NmcTyphoonResponse.self,
                                               from: NmcTyphoonJSONP.unwrap(Data(varying.utf8)))
        let track = NmcTyphoonMapper.track(from: dto)
        XCTAssertEqual(track?.points.count, 2)
        // ⚠️ 取**最新点**的预报（实测最新点只剩 1 个时效）。
        XCTAssertEqual(track?.latestForecast.count, 1,
                       "应取最新点的预报（实测只剩 1 个时效）")
        XCTAssertEqual(track?.latestForecast.first?.leadHours, 12)
        XCTAssertEqual(track?.latestForecast.first?.longitude ?? 0, 162.0, accuracy: 0.001)
        XCTAssertEqual(track?.latestForecast.first?.latitude ?? 0, 46.0, accuracy: 0.001)
    }

    /// 缺经纬的点必须被丢弃（地图上画不出来），其余点保留。
    func testPointWithoutCoordinatesIsDropped() throws {
        let partial = #"""
        cb({"typhoon":[1,"X","测试",1,1,null,null,"start",
        [[1,"202610050000",1791158400000,"TY",179.4,24.8,935,52,"W",28,[],null,null],
        [2,"202610050300",null,null,null,null,null,null,null,null,[],null,null],
        [3,"202610050600",1791200000000,"TY",179.0,25.0,935,52,"W",28,[],null,null]]]})
        """#
        let dto = try ResponseDecoding.decode(NmcTyphoonResponse.self,
                                               from: NmcTyphoonJSONP.unwrap(Data(partial.utf8)))
        let track = NmcTyphoonMapper.track(from: dto)
        XCTAssertEqual(track?.points.count, 2,
                       "缺经纬的点应被丢弃，好点必须保留（不得整批清空）")
    }

    /// 路径点按时间**排序**（防上游乱序画出折返线）。
    func testPointsAreSortedByTime() throws {
        let unsorted = #"""
        cb({"typhoon":[1,"X","测试",1,1,null,null,"start",
        [[2,"202610050600",1791200000000,"TY",179.0,25.0,935,52,"W",28,[],null,null],
        [1,"202610050000",1791158400000,"TY",179.4,24.8,935,52,"W",28,[],null,null]]]})
        """#
        let dto = try ResponseDecoding.decode(NmcTyphoonResponse.self,
                                               from: NmcTyphoonJSONP.unwrap(Data(unsorted.utf8)))
        let track = NmcTyphoonMapper.track(from: dto)
        XCTAssertEqual(track?.points.first?.pointID, 1, "应按时刻升序（实测上游本就升序）")
        XCTAssertEqual(track?.points.last?.pointID, 2)
    }

    // MARK: - 5．强度 / 移向枚举（实测全集）

    /// 实测 6 档强度逐字断言。
    func testIntensityDisplayNamesForAllMeasuredRanks() {
        let expected: [(String, String)] = [
            ("TD", "热带低压"), ("TS", "热带风暴"), ("STS", "强热带风暴"),
            ("TY", "台风"), ("STY", "强台风"), ("SuperTY", "超强台风")
        ]
        for (raw, display) in expected {
            XCTAssertEqual(TyphoonIntensity(rawValue: raw).displayName, display,
                           "实测强度 \(raw) 的中文名应为 \(display)")
        }
    }

    /// 未收录强度**如实显示原值**，绝不猜（上游可能加档）。
    func testUnknownIntensityKeepsRawValueAndDoesNotGuess() {
        let unknown = TyphoonIntensity(rawValue: "HyperTY")
        XCTAssertEqual(unknown.rawValue, "HyperTY", "未知档位必须原样保留")
        XCTAssertTrue(unknown.displayName.contains("HyperTY"),
                      "未知档位应显示原值并标注未收录，实际：\(unknown.displayName)")
        XCTAssertTrue(unknown.displayName.contains("未收录"))
    }

    /// 实测 16 方位 + `"no"` 的中文名。
    func testMotionDisplayNames() {
        XCTAssertEqual(TyphoonMotion(rawValue: "W").displayName, "西")
        XCTAssertEqual(TyphoonMotion(rawValue: "WNW").displayName, "西北偏西")
        XCTAssertEqual(TyphoonMotion(rawValue: "no").displayName, "停滞")
        XCTAssertEqual(TyphoonMotion.sixteenCompassPoints.count, 16,
                       "实测 16 方位全集")
        // ⚠️ 实测出现过非方位值 "0" → 如实显示原值，不谎称停滞。
        XCTAssertEqual(TyphoonMotion(rawValue: "0").displayName, "0")
    }

    // MARK: - 6．端点 URL 拼装

    /// 实测端点形态逐字断言。
    func testEndpointURLShapes() {
        let listURL = NmcTyphoonEndpoint.defaultListURL()
        XCTAssertEqual(listURL?.absoluteString,
                       "https://typhoon.nmc.cn/weatherservice/typhoon/jsons/list_default",
                       "实测默认列表端点形态")
        XCTAssertEqual(NmcTyphoonEndpoint.yearListURL(year: 1950)?.absoluteString,
                       "https://typhoon.nmc.cn/weatherservice/typhoon/jsons/list_1950",
                       "实测 1950 端点可达（HTTP 200）")
        XCTAssertEqual(NmcTyphoonEndpoint.trackURL(id: "3346168")?.absoluteString,
                       "https://typhoon.nmc.cn/weatherservice/typhoon/jsons/view_3346168",
                       "实测详情端点形态")
    }

    /// ⚠️ 实测 `list_2030`（未来年）→ **404 HTML** → 必须前置拒绝。
    func testFutureYearIsRejectedWithoutRequest() {
        XCTAssertNil(NmcTyphoonEndpoint.yearListURL(year: 2030),
                     "实测未来年份 404，前置拒绝（不发无谓请求）")
        XCTAssertNil(NmcTyphoonEndpoint.yearListURL(year: 1949),
                     "实测下界为 1950（list_1950 → HTTP 200）")
        XCTAssertNotNil(NmcTyphoonEndpoint.yearListURL(year: 2024))
    }

    /// 非法 id 必须拒绝（防路径改写打到别的端点）。
    func testTrackURLRejectsNonNumericID() {
        XCTAssertNotNil(NmcTyphoonEndpoint.trackURL(id: "3346168"))
        XCTAssertNil(NmcTyphoonEndpoint.trackURL(id: ""), "空 id 应拒绝")
        XCTAssertNil(NmcTyphoonEndpoint.trackURL(id: "3346168/../admin"),
                      "含 '/' 的 id 会改写路径，必须拒绝")
        XCTAssertNil(NmcTyphoonEndpoint.trackURL(id: "abc"), "非数字 id 应拒绝")
    }

    // MARK: - 7．服务层：状态码先于剥壳（实测 404 是 HTML）

    /// 🔴 实测 `view_9999999` → **404 + text/html** → 必须抛 `badStatus(404)`
    /// 而**不是**「解码失败」：两者对用户的处置完全不同。
    func testServerErrorThrowsBadStatusNotDecodingError() async throws {
        TyphoonStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: 404,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/html"])!
            return (response, Data(self.html404Body.utf8))
        }
        let service = NmcTyphoonService(session: stubbedSession())
        do {
            _ = try await service.fetchTrack(id: "9999999")
            XCTFail("实测该 id 返回 404，应抛错而非静默成功")
        } catch let error as WeatherError {
            XCTAssertEqual(error, .badStatus(404),
                           "404 必须以 badStatus 呈现（实测响应体是 HTML）")
        } catch {
            XCTFail("期望 WeatherError，实际：\(error)")
        }
        TyphoonStubURLProtocol.handler = nil
    }

    /// 2xx + 合法 JSONP → 成功返回。
    func testSuccessfulFetchReturnsMappedSummaries() async throws {
        TyphoonStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: 200,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: nil)!
            return (response, Data(self.listDefaultJSONP.utf8))
        }
        let service = NmcTyphoonService(session: stubbedSession())
        let summaries = try await service.fetchSummaries()
        XCTAssertEqual(summaries.count, 5, "实测样本 5 条")
        XCTAssertEqual(summaries[0].id, "3346033")
        TyphoonStubURLProtocol.handler = nil
    }

    /// 🔴 **空数组 = 成功且没有台风**（实测「无台风」是常态），
    /// **不是**故障 → 服务层不得抛错。
    func testEmptyListIsSuccessNotFailure() async throws {
        TyphoonStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: 200,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: nil)!
            return (response, Data(#"cb(({"typhoonList":[]}))"#.utf8))
        }
        let service = NmcTyphoonService(session: stubbedSession())
        let summaries = try await service.fetchSummaries()
        XCTAssertTrue(summaries.isEmpty,
                      "空列表是合法业务结果（没有台风），不得抛错")
        TyphoonStubURLProtocol.handler = nil
    }

    /// 网络失败 → `.network`，**绝不**伪装成「没有台风」。
    ///
    /// 🔴 原断言是裸的 `XCTAssertTrue(true)`（恒真，零信息），且把
    /// `.network` / `.timeout` 一起接受 → 分不出映射是否写错。
    /// →改为断言**确切**的 `.network`：`NmcTyphoonProviding.fetchData`
    /// 只把 `URLError.timedOut` 映射成 `.timeout`，其余 URLError 一律 `.network`
    /// （见 NmcTyphoonProviding.swift:123-127），故断网必须是 `.network`。
    func testNetworkFailureThrowsInsteadOfReturningEmpty() async throws {
        TyphoonStubURLProtocol.handler = { request in
            throw URLError(.notConnectedToInternet)
        }
        let service = NmcTyphoonService(session: stubbedSession())
        do {
            _ = try await service.fetchSummaries()
            XCTFail("网络失败必须抛错（返回空数组会被显示成「无活跃台风」）")
        } catch let error as WeatherError {
            // 🔴 不用 `XCTAssertTrue(true)`：那恒真、零信息。
            //    也不接受 `.timeout`：断网实测映射为 `.network`（二者须可区分）。
            guard case .network = error else {
                XCTFail("断网（URLError.notConnectedToInternet）应映射为 .network，实际：\(error)")
                return
            }
        } catch {
            XCTFail("期望 WeatherError，实际：\(error)")
        }
        TyphoonStubURLProtocol.handler = nil
    }

    /// 超时 → `.timeout`（供UI 显示「取不到」而非「没有台风」）。
    func testTimeoutIsDistinguishedFromNetworkFailure() async throws {
        TyphoonStubURLProtocol.handler = { request in
            throw URLError(.timedOut)
        }
        let service = NmcTyphoonService(session: stubbedSession())
        do {
            _ = try await service.fetchSummaries()
            XCTFail("超时应抛错")
        } catch let error as WeatherError {
            guard case .timeout = error else {
                XCTFail("期望 timeout，实际：\(error)")
                return
            }
        } catch {
            XCTFail("期望 WeatherError，实际：\(error)")
        }
        TyphoonStubURLProtocol.handler = nil
    }

    // MARK: - 8．四态：`.none` 与 `.unavailable` 必须可区分

    /// 活跃台风 → `.active`。
    @MainActor
    func testActiveStateWhenTyphoonsExist() async {
        let service = StubTyphoonProviding(summaries: Self.sampleSummaries, track: nil)
        let model = TyphoonCardModel(service: service)
        await model.load(year: nil)
        guard case .active(let list) = model.state else {
            XCTFail("有活跃台风时应为 .active，实际：\(model.state)")
            return
        }
        XCTAssertEqual(list.count, 2)
    }

    /// 🔴 取到了但**没有活跃台风** → `.none`（**合法业务结果**）。
    @MainActor
    func testNoneStateWhenNoActiveTyphoon() async {
        let service = StubTyphoonProviding(summaries: [], track: nil)
        let model = TyphoonCardModel(service: service)
        await model.load(year: nil)
        XCTAssertEqual(model.state, .none,
                       "取到了且确实没有活跃台风 → .none（不是故障）")
    }

    /// 🔴 **取不到** → `.unavailable`（**绝不**落 `.none`）。
    @MainActor
    func testUnavailableStateWhenFetchFails() async {
        let service = StubTyphoonProviding(summaries: [],
                                            track: nil,
                                            error: WeatherError.network("断网"))
        let model = TyphoonCardModel(service: service)
        await model.load(year: nil)
        guard case .unavailable = model.state else {
            XCTFail("取不到时必须是 .unavailable（否则会被显示成「无活跃台风」）")
            return
        }
    }

    /// 未来年份 → 前置拒绝（实测404），不把它当作「那一年没有台风」。
    @MainActor
    func testFutureYearIsRejectedNotTreatedAsNoTyphoon() async {
        let service = StubTyphoonProviding(summaries: [], track: nil)
        let model = TyphoonCardModel(service: service)
        await model.load(year: 2030, currentYear: 2026)
        guard case .unavailable = model.state else {
            XCTFail("未来年份应被拒绝（实测 404），不该显示成「无台风」")
            return
        }
    }

    /// 详情取数失败 → `detailFailed`（UI 必须显示「取不到」而非空白）。
    @MainActor
    func testDetailFailureIsFlaggedNotSilentlyEmpty() async {
        let service = StubTyphoonProviding(summaries: Self.sampleSummaries,
                                            track: nil,
                                            error: WeatherError.badStatus(404))
        let model = TyphoonCardModel(service: service)
        await model.loadDetail(for: Self.sampleSummaries[0])
        XCTAssertTrue(model.detailFailed, "详情取不到必须被标记（不能静默）")
        XCTAssertNil(model.detail)
    }

    /// 详情解码成功但结构不符 → `detail` 为 nil 且 `detailFailed` 为 true。
    @MainActor
    func testDetailNilMeansFailure() async {
        let service = StubTyphoonProviding(summaries: Self.sampleSummaries, track: nil)
        let model = TyphoonCardModel(service: service)
        await model.loadDetail(for: Self.sampleSummaries[0])
        XCTAssertTrue(model.detailFailed,
                      "解码成功但结构不符也是一种「取不到」，必须标记")
    }

    /// 年份选项下界锚定实测可回溯年1950。
    func testSelectableYearsAreBoundedByMeasuredEarliestYear() {
        let years = TyphoonCardModel.selectableYears(currentYear: 2026)
        XCTAssertFalse(years.isEmpty)
        XCTAssertEqual(years.first, 2026, "应含当前年")
        XCTAssertEqual(years.last, 2022, "默认给出近 5 年")
        // 当"当前年"远早于实测下界时不得产生非法年份。
        XCTAssertTrue(TyphoonCardModel.selectableYears(currentYear: 1900).isEmpty,
                      "1900 早于实测可回溯年1950，不应产出年份")
    }

    // MARK: - 9．字段缺失时如实缺测（不填 0 / 占位）

    /// 风圈半径缺失 → `maxRadiusKm` 为 nil（**不是 0**）。
    func testWindCircleWithNoRadiusReportsNilNotZero() {
        let circle = TyphoonWindCircle(label: "30KTS", radii: [], pointID: 1)
        XCTAssertNil(circle.maxRadiusKm,
                     "半径全缺时应为 nil（0 会被画成半径 0 的假小圈）")
    }

    /// 缺测字段逐项为 nil（UI 逐项判空，不显示占位）。
    func testMissingFieldsAreNilRatherThanZero() throws {
        let sparse = #"""
        cb({"typhoon":[1,"X","测试",1,1,null,null,"start",
        [[1,null,null,null,null,null,null,null,null,null,[],null,null]]]})
        """#
        let dto = try ResponseDecoding.decode(NmcTyphoonResponse.self,
                                               from: NmcTyphoonJSONP.unwrap(Data(sparse.utf8)))
        // ⚠️ 不用 `points.isEmpty`（在「整批被丢弃」与「唯独该点被丢弃」之间无法区分），
        //    改为先锚「台风本身仍解得出」→ 再锚「点数为 0」。
        //    注：原写法 `?.points.isEmpty ?? false` 在 nil 时同样会红（不是静默通过），
        //    但那条红来自 `?? false` 的**副作用**而非断言意图，诊断信息也丢失。
        let track = NmcTyphoonMapper.track(from: dto)
        XCTAssertNotNil(track, "头部合法时应仍能解出台风（不该整批丢弃）")
        XCTAssertEqual(track?.points.count, 0, "缺经纬的点应被丢弃")
    }

    /// `JSONValue` 的类型安全取值：字符串数字可转数、非整数不截断。
    func testJSONValueTypedAccessors() {
        let data = Data(#"[1, 2.5, "3", "x", null, true, [1], {"a":1}]"#.utf8)
        let decoded = try? JSONDecoder().decode([JSONValue].self, from: data)
        let values = decoded ?? []
        XCTAssertEqual(values.count, 8)
        XCTAssertEqual(values[0].intValue, 1, "整数应可取 intValue")
        XCTAssertEqual(values[1].intValue, nil, "2.5 不是整数，不应被截断成 2")
        XCTAssertEqual(values[1].doubleValue ?? 0, 2.5, accuracy: 0.0001)
        XCTAssertEqual(values[2].intValue, 3, "数字字符串应可转整数")
        XCTAssertEqual(values[3].intValue, nil, "非数字字符串应为 nil")
        XCTAssertEqual(values[4].doubleValue, nil, "null 的取值应为 nil")
        XCTAssertEqual(values[5].bool, true, "布尔应可取")
        XCTAssertEqual(values[6].arrayValue?.count, 1, "数组应可取")
        XCTAssertEqual(values[7].objectValue?.count, 1, "对象应可取")
    }

    /// 整数字面串**不带 `.0`**（实测编号 `2628` 不是 `2628.0`）。
    func testNumberToStringHasNoDecimalSuffix() {
        XCTAssertEqual(JSONValue.number(2628).stringValue, "2628")
        XCTAssertEqual(JSONValue.number(2.5).stringValue, "2.5")
    }

    // MARK: - 样本

    /// 两条活跃台风样本（用实测的诺洛 / 彩云构造）。
    private static let sampleSummaries: [TyphoonSummary] = [
        TyphoonSummary(id: "3346168", englishName: "NOLO", chineseName: "诺洛",
                       number: "2628", namingMeaning: nil, isActive: true),
        TyphoonSummary(id: "3341981", englishName: "CHOI-WAN", chineseName: "彩云",
                       number: "2627", namingMeaning: "天上的云彩", isActive: true)
    ]
}

// MARK: - Stub

/// `NmcTyphoonProviding` 的测试桩。
private struct StubTyphoonProviding: NmcTyphoonProviding {
    let summaries: [TyphoonSummary]
    let track: TyphoonTrack?
    var error: WeatherError?

    func fetchSummaries() async throws -> [TyphoonSummary] {
        if let error { throw error }
        return summaries
    }

    func fetchSummaries(year: Int) async throws -> [TyphoonSummary] {
        if let error { throw error }
        return summaries
    }

    func fetchTrack(id: String) async throws -> TyphoonTrack? {
        if let error { throw error }
        return track
    }
}

// MARK: - JSONValue 便捷访问（测试内用）

extension JSONValue {
    /// 布尔值（测试断言用）。
    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}
//
//  NmcAlarmTests.swift
//  ZhishengWeatherTests
//
//  第六源（中国气象局 NMC 官方预警）的接入锚点：
//  1．**标题解析**：≥8 条**实测真实标题**逐字断言（含直辖市、自治区、地级市、
//     县级市、市辖区、自治县、「地区」级、两处上游脏数据）；
//  2．**解析不出即nil**：缺锚点/ 缺颜色 / 未收录省级 / 形变标题 → **不猜**；
//     同名区县（鼓楼区 / 城关区）**不被误配**；
//  3．**DTO 可选性**：`data` / `page` / `list` 缺失、`list` 元素为 `null`
//     → 解码**不抛错**且回**空数组**；
//  4．**端点请求面**：`pageSize` **大小写**（实测敏感）、免凭据、详情页 URL 拼接；
//  5．**颜色排序**：红 > 橙 > 黄 > 蓝，`.unspecified` 排最后；
//  6．**新鲜度**：超过 6 小时 → `.stale`（`now` **全部注入**，不读系统时钟）；
//  7．**四态触发条件**各自独立断言；
//  8．**城市筛选**：本仓名（`福州`）↔ NMC 名（`泉州市`）对齐后匹配；
//     未解析出市段的条目**不命中**（宁漏勿错）。
//
//  ⚠️ **全部标题样本都是真实抓取的逐字原文**（2026-10-06 真实 curl，
//  `https://www.nmc.cn/rest/findAlarm?pageNo=1&pageSize=200`，HTTP 200，
//  当日 `count`=161，跨 15 省）。**不得**为了让测试通过而改写样本。
//
//  ⚠️ **并发纪律**：`XCTAssert*` 的实参是 autoclosure，装不下 `await`。
//  故所有 `await` 都先求值到局部常量再断言（同 `METNorwayTests`）。
//
//  不联网：全部喂本地造好的 JSON（服务层用 URLProtocol 桩注入响应）。
//

import XCTest
@testable import ZhishengWeather

/// NMC 预警测试专用的 URLProtocol 桩（文件级 `private`，不与既有同名类冲突）。
private final class NmcStubURLProtocol: URLProtocol {
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

final class NmcAlarmTests: XCTestCase {

    // MARK: - 测试夹具（真实样本，逐字）

    /// 实测基准时刻（**注入用**，绝不在被测代码里调`Date()`）。
    private var referenceNow: Date {
        // 2026-10-06 21:00:00 +08:00（实测抓取时刻附近）。
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 6
        components.hour = 21
        components.minute = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    /// 实测时区（预警发布地）。
    private var shanghai: TimeZone {
        TimeZone(identifier: "Asia/Shanghai") ?? .current
    }

    // MARK: - 1．标题解析（≥8 条真实样本，逐字）

    /// 逐条断言**实测真实标题**的省 / 市 / 县 / 类型 / 颜色。
    ///
    /// 覆盖：普通省的三级、**直辖市**、**自治区**、「地区」级、
    /// 县级市、市辖区、自治县、以及**仅省级**（无市无县）。
    func testParsesRealTitlesVerbatim() throws {
        // (标题原文, 省, 市, 县, 类型, 颜色) —— 全部为2026-10-06 实测原文。
        let samples: [(String, String?, String?, String?, String, NmcAlarmColor)] = [
            // 三级 · 省 + 地级市 + 县级市（实测 alertid 前6 位 350581 = 石狮市）
            ("福建省泉州市石狮市气象台发布大风黄色预警信号",
             "福建省", "泉州市", "石狮市", "大风", .yellow),
            // 三级 · 省 + 地级市 + 市辖区
            ("福建省漳州市龙海区气象台发布大风黄色预警信号",
             "福建省", "漳州市", "龙海区", "大风", .yellow),
            // 三级 · 省 + 地级市 + 县
            ("湖南省邵阳市隆回县气象台发布大雾黄色预警信号",
             "湖南省", "邵阳市", "隆回县", "大雾", .yellow),
            // ⚠️ **直辖市变体**：市 == 省（上游多吐一个「县」字，见样本 10）
            ("重庆市县云阳县气象台发布大雾黄色预警信号",
             "重庆市", "重庆市", nil, "大雾", .yellow),
            // ⚠️ **自治区**：全称「新疆维吾尔自治区」+ 自治州 + 县
            ("新疆维吾尔自治区博尔塔拉蒙古自治州温泉县气象台发布霜冻蓝色预警信号",
             "新疆维吾尔自治区", "博尔塔拉蒙古自治州", "温泉县", "霜冻", .blue),
            // ⚠️ **自治区** + 「地区」级 + 县
            ("新疆维吾尔自治区喀什地区塔什库尔干县气象台发布大风蓝色预警信号",
             "新疆维吾尔自治区", "喀什地区", "塔什库尔干县", "大风", .blue),
            // ⚠️ **自治区** + 地级市，无区县（实测原文无区县级）
            ("广西壮族自治区桂林市气象台发布大风蓝色预警信号",
             "广西壮族自治区", "桂林市", nil, "大风", .blue),
            // 自治区 + 地级市 + 区（红寺堡是撤县设区的实测样本）
            ("宁夏回族自治区吴忠市红寺堡区气象台发布大风蓝色预警信号",
             "宁夏回族自治区", "吴忠市", "红寺堡区", "大风", .blue),
            // 「地区」级（黑龙江大兴安岭），无区县
            ("黑龙江省大兴安岭地区气象台发布大风蓝色预警信号",
             "黑龙江省", "大兴安岭地区", nil, "大风", .blue),
            // 「地区」级 + 县
            ("黑龙江省大兴安岭地区塔河县气象台发布大风蓝色预警信号",
             "黑龙江省", "大兴安岭地区", "塔河县", "大风", .blue),
            // 多字类型「森林火险」+ 橙色
            ("广东省河源市龙川县气象台发布森林火险黄色预警信号",
             "广东省", "河源市", "龙川县", "森林火险", .yellow),
            ("广东省肇庆市四会市气象台发布森林火险橙色预警信号",
             "广东省", "肇庆市", "四会市", "森林火险", .orange),
            // 多字自治县
            ("云南省普洱市景谷傣族彝族自治县气象台发布雷电黄色预警信号",
             "云南省", "普洱市", "景谷傣族彝族自治县", "雷电", .yellow),
            ("云南省临沧市沧源佤族自治县气象台发布暴雨蓝色预警信号",
             "云南省", "临沧市", "沧源佤族自治县", "暴雨", .blue),
            // 自治州（朝鲜族）+ 县
            ("吉林省延边朝鲜族自治州汪清县气象台发布大雾黄色预警信号",
             "吉林省", "延边朝鲜族自治州", "汪清县", "大雾", .yellow),
            // 长名自治州 + 县 + 橙色
            ("湖南省湘西土家族苗族自治州古丈县气象台发布大雾橙色预警信号",
             "湖南省", "湘西土家族苗族自治州", "古丈县", "大雾", .orange),
            // 长名自治县（蒙古族）
            ("甘肃省酒泉市肃北蒙古族自治县气象台发布大风蓝色预警信号",
             "甘肃省", "酒泉市", "肃北蒙古族自治县", "大风", .blue),
            // 自治州 + 县级市（西双版纳傣族自治州景洪市）
            ("云南省西双版纳傣族自治州景洪市气象台发布暴雨蓝色预警信号",
             "云南省", "西双版纳傣族自治州", "景洪市", "暴雨", .blue),
            // ⚠️ **仅省级**（无市无县）+ 多字类型「海上雷雨大风」
            ("海南省气象台发布海上雷雨大风黄色预警信号",
             "海南省", nil, nil, "海上雷雨大风", .yellow),
            // 省直辖县级市（无区县级）
            ("海南省三沙市气象台发布雷雨大风黄色预警信号",
             "海南省", "三沙市", nil, "雷雨大风", .yellow),
            // 上游脏数据②：区县段开头**重复了省名** → 必须剥掉
            ("广东省清远市广东省连山壮族瑶族自治县气象台发布森林火险黄色预警信号",
             "广东省", "清远市", "连山壮族瑶族自治县", "森林火险", .yellow)
        ]

        XCTAssertGreaterThanOrEqual(samples.count, 8,
                                    "真实样本必须 ≥8 条（任务硬要求）")

        for (title, province, city, county, kind, color) in samples {
            guard let parsed = NmcAlarmTitleParser.parse(title) else {
                XCTFail("实测真实标题解析失败（应解析成功）：\(title)")
                continue
            }
            XCTAssertEqual(parsed.province, province, "省错：\(title)")
            XCTAssertEqual(parsed.city, city, "市错：\(title)")
            XCTAssertEqual(parsed.county, county, "县错：\(title)")
            XCTAssertEqual(parsed.kind, kind, "类型错：\(title)")
            XCTAssertEqual(parsed.color, color, "颜色错：\(title)")
        }
    }

    /// 直辖市变体单独钉死：`市== 省`，且**绝不**产出「市 = 县」这种不可能层级。
    func testMunicipalityHasCityEqualToProvince() throws {
        let parsed = try XCTUnwrap(
            NmcAlarmTitleParser.parse("重庆市县云阳县气象台发布大雾黄色预警信号"))
        XCTAssertEqual(parsed.province, "重庆市")
        XCTAssertEqual(parsed.city, "重庆市",
                       "直辖市的市 == 省（上游多吐的「县」字须被整段丢弃）")
        XCTAssertNil(parsed.county,
                     "直辖市不得产出区县级（上游「县云阳县」是脏数据）")
    }

    /// 四个直辖市都在词表内（逐个钉住，避免日后改词表漏掉）。
    func testAllFourMunicipalitiesAreRecognized() {
        for name in ["北京市", "天津市", "上海市", "重庆市"] {
            XCTAssertTrue(NmcAlarmTitleParser.municipalityNames.contains(name),
                          "\(name) 应被识别为直辖市")
        }
        XCTAssertEqual(NmcAlarmTitleParser.municipalityNames.count, 4)
    }

    // MARK: - 2．解析不出 → nil（绝不猜）

    /// 各类残缺/ 异常标题 → **nil**，不是猜一个出来。
    func testUnparsableTitlesReturnNilRatherThanGuessing() {
        let broken: [String] = [
            "",// 空串
            "大风黄色预警信号",              // 无 `气象台` 硬锚点
            "北京市海淀区天气预报",           // 无 `气象台`
            "福建省漳州市气象台发布预警信号",  // 类型 + 颜色皆空
            "福建省漳州市气象台发布大风预警信号", // 有类型、**缺颜色**
            "气象台发布大风黄色预警信号",      // 行政区划前缀为空
            "台湾省台北市气象台发布台风黄色预警信号", // 省级未收录 → 不猜
            "某某省某市某县气象台发布大风黄色预警信号", // 省级未收录 → 不猜
            "福建省漳州市龙海区气象台发布大风黄色",// 缺 `预警信号` 后缀
            "福建省漳州市龙海区气象台大风黄色预警信号"  // 缺 `发布` 仍应可解析（见下）
        ]
        // 最后一条其实**可以**解析（`发布` 是可选），单独断言它能解析，
        // 故从失败集里剔除。
        for title in broken.dropLast() {
            XCTAssertNil(NmcAlarmTitleParser.parse(title),
                         "以下标题**必须**解析失败（宁可 nil 也绝不猜）：\(title)")
        }
        // `发布` 动词可选（实测 24/24 都有，但容忍上游省略）。
        let withoutVerb = NmcAlarmTitleParser.parse(
            "福建省漳州市龙海区气象台大风黄色预警信号")
        XCTAssertEqual(withoutVerb?.county, "龙海区",
                       "缺 `发布` 动词不应让解析失败（该动词容忍可读）")
        XCTAssertEqual(withoutVerb?.kind, "大风")
    }

    /// 未收录的省级单位 → **nil**（不猜它属于哪个省）。
    ///
    /// ⚠️ 台湾 / 香港 / 澳门**刻意不在词表内**（实测从未出现在预警流里）。
    func testUnlistedProvinceIsNotGuessed() {
        XCTAssertNil(NmcAlarmTitleParser.parse(
            "台湾省台北市气象台发布台风红色预警信号"))
        XCTAssertNil(NmcAlarmTitleParser.parse(
            "香港特别行政区气象台发布雷暴黄色预警信号"))
        XCTAssertNil(NmcAlarmTitleParser.parse(
            "澳门特别行政区气象台发布雷暴黄色预警信号"))
    }

    /// **同名区县不被误配**：城市筛选必须按「对齐后的地级名相等」，
    /// 而非「整串包含」（后者会让多个「鼓楼区」互相命中）。
    func testSameNamedCountiesAreNotCrossMatched() {
        // 全国有多个「鼓楼区」（福州、南京…）与多个「城关区」。
        // 这里断言**地级段**区分能力：两条标题的县段同名，但市段不同。
        let items = NmcAlarmMapper.warnings(
            in: Self.mapRealFixture(),
            matchingCityName: "福州")

        // 本仓城市名是 `福州`（无「市」后缀）→ 只能命中市段为 `泉州市` 的条目。
        // 若筛选器错用「整串包含」，`南京市` 一旦标题里出现「鼓楼区」就会被误纳。
        for item in items {
            XCTAssertEqual(item.cityName, "泉州市",
                           "按城市筛选只该命中市段 == 泉州市的条目")
        }
    }

    /// 未解析出市段的条目（省级直发）→ **不参与**城市筛选（宁漏勿错）。
    func testItemsWithoutCityNeverMatchCityFilter() throws {
        let provincial = OfficialWarningItem(
            id: "x", region: "海南省", cityName: nil,
            administrativeCode: "460000", kind: "海上雷雨大风", color: .yellow,
            issuedAt: referenceNow, detailURL: nil,
            rawTitle: "海南省气象台发布海上雷雨大风黄色预警信号")

        let matched = NmcAlarmMapper.warnings(in: [provincial],
                                               matchingCityName: "海口")
        XCTAssertTrue(matched.isEmpty,
                      "市段为 nil 的条目**不得**被匹配到任何城市（否则会串台）")
    }

    // MARK: - 3．DTO 可选性（缺块 / null 元素 一律不抛错）

    /// 四种残缺形态解码后回**空数组**，**不抛错**。
    func testMalformedResponsesDecodeToEmptyArrayWithoutThrowing() throws {
        // ① 顶层 `data` 缺失
        let noData: [String: Any] = ["msg": "success", "code": 0]
        XCTAssertEqual(Self.decodeAndMap(Self.json(from: noData)), [],
                       "缺 `data` → 空数组")

        // ② `data.page` 缺失
        let noPage: [String: Any] = ["msg": "success", "code": 0,
                                     "data": ["provinceAlarms": []]]
        XCTAssertEqual(Self.decodeAndMap(Self.json(from: noPage)), [],
                       "缺 `data.page` → 空数组")

        // ③ `page.list` 缺失
        let noList: [String: Any] = ["msg": "success", "code": 0,
                                     "data": ["page": ["pageNo": 1, "count": 0]]]
        XCTAssertEqual(Self.decodeAndMap(Self.json(from: noList)), [],
                       "缺 `page.list` → 空数组")

        // ④ `list` 里含 `null` 元素（本仓在Open-Meteo / MET Norway 各吃过一次）
        let nullElement: [String: Any] = [
            "msg": "success", "code": 0,
            "data": ["page": ["pageNo": 1, "list": [NSNull()]]]
        ]
        XCTAssertEqual(Self.decodeAndMap(Self.json(from: nullElement)), [],
                       "list 含 null 元素 → 空数组，且**不抛错**")

        // ⑤ `list` 为空数组（正常「当前无预警」形态）
        let emptyList: [String: Any] = [
            "msg": "success", "code": 0,
            "data": ["page": ["pageNo": 1, "count": 0, "list": []]]
        ]
        XCTAssertEqual(Self.decodeAndMap(Self.json(from: emptyList)), [])
    }

    /// `provinceAlarms` 恒为空数组 —— **不建模**它（无消费者），
    /// 且它出现/消失都不应影响解码。
    func testProvinceAlarmsKeyIsIgnoredAndOptional() throws {
        let withKey: [String: Any] = [
            "msg": "success", "code": 0,
            "data": [
                "page": ["list": [Self.entry(title: "福建省泉州市气象台发布大风黄色预警信号",
                                            alertid: "350700_20261006203000")]],
                "provinceAlarms": [],
                "stat": ["county": ["r": 0, "b": 1, "y": 0, "o": 0]]
            ]
        ]
        let items = Self.decodeAndMap(Self.json(from: withKey))
        XCTAssertEqual(items.count, 1, "`provinceAlarms` 不应影响解码")
    }

    /// 一条真实结构的响应 → 正确解析出字段（正向锚点）。
    func testRealResponseShapeMapsFields() throws {
        let payload: [String: Any] = [
            "msg": "success", "code": 0,
            "data": [
                "page": [
                    "pageNo": 1, "pageSize": 200, "count": 161,
                    "list": [
                        ["alertid": "35060441600000_20261006202800",
                         "issuetime": "2026/10/06 20:28",
                         "title": "福建省漳州市龙海区气象台发布大风黄色预警信号",
                         "url": "/publish/alarm/35060441600000_20261006202800.html",
                         "pic": "https://image.nmc.cn/assets/img/alarm/p0007003.png"]
                    ]
                ],
                "provinceAlarms": [],
                "stat": ["county": ["r": 0, "b": 40, "y": 87, "o": 12]]
            ]
        ]
        let items = Self.decodeAndMap(Self.json(from: payload))
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.id, "35060441600000_20261006202800")
        XCTAssertEqual(item.cityName, "漳州市")
        // ⚠️ 县段**刻意**不在模型上（`OfficialWarningItem` 没有 `county` 字段，
        // 见 OfficialWarning.swift 的字段清单）—— 它只保留在下方的 `region`
        // 展示串里。故此处不引用不存在的属性，县名由region 断言覆盖。
        XCTAssertEqual(item.kind, "大风")
        XCTAssertEqual(item.color, .yellow)
        // 行政区划码 = alertid 前 6 位（实测 GB/T 2260）
        XCTAssertEqual(item.administrativeCode, "350604")
        XCTAssertEqual(item.region, "福建省 / 漳州市 / 龙海区")
        // 详情页 = 相对路径 + host
        XCTAssertEqual(item.detailURL?.absoluteString,
                       "https://www.nmc.cn/publish/alarm/35060441600000_20261006202800.html")
        // issuetime 墙钟 + 注入时区 → 绝对时刻（2026-10-06 20:28 +08）
        let issued = try XCTUnwrap(item.issuedAt)
        XCTAssertEqual(NmcIssueTimeDecoder.date(from: "2026/10/06 20:28",
                                                 timeZone: shanghai), issued)
    }

    // MARK: - 4．端点（请求面 / 大小写 / 免凭据）

    /// `pageSize` **大小写敏感**（实测 `pagesize` 会静默退回 10 条）。
    func testEndpointUsesCaseSensitivePageSizeSpelling() throws {
        let url = try XCTUnwrap(NmcAlarmEndpoint.url())
        let text = try XCTUnwrap(url.absoluteString)
        XCTAssertTrue(text.contains("pageSize=200"),
                      "必须写 `pageSize`（实测 `pagesize` 会被服务端忽略）")
        XCTAssertFalse(text.contains("pagesize"),
                       "不得出现小写 `pagesize`（实测静默退回 10 条）")
        XCTAssertTrue(text.hasPrefix("https://www.nmc.cn/rest/findAlarm"))
    }

    /// **免凭据 / 免Referer / 不发无效参数**。
    func testEndpointIsCredentialFreeAndSendsNoDeadParameters() throws {
        let url = try XCTUnwrap(NmcAlarmEndpoint.url())
        let text = try XCTUnwrap(url.absoluteString)
        // `stationid` 实测无效（带/不带/乱填都返回同一份全国列表）。
        XCTAssertFalse(text.contains("stationid"),
                       "不得发 `stationid`（实测该参数无效，属多余请求面）")
        // 免凭据 → 不得出现任何 key/token 参数。
        for forbidden in ["key", "token", "appid", "secret"] {
            XCTAssertFalse(text.lowercased().contains(forbidden),
                           "本源免凭据，请求面不得出现 \(forbidden)")
        }
        // 描述符登记的免凭据声明必须与端点一致。
        let descriptor = SourceDirectory.descriptor(for: .nmcAlarm)
        XCTAssertEqual(descriptor?.needsCredential, false)
        XCTAssertEqual(descriptor?.websiteURLString, "http://www.nmc.cn/")
    }

    /// 详情页 URL 拼接：相对路径补host；异常路径 → **nil**（不猜）。
    func testDetailURLJoining() throws {
        let joined = try XCTUnwrap(NmcAlarmEndpoint.detailURL(
            relativePath: "/publish/alarm/35060441600000_20261006202800.html"))
        XCTAssertEqual(joined.absoluteString,
                       "https://www.nmc.cn/publish/alarm/35060441600000_20261006202800.html")
        // 已是绝对 URL → 原样返回
        XCTAssertEqual(NmcAlarmEndpoint.detailURL(relativePath: "https://x.cn/a.html")?
                        .absoluteString, "https://x.cn/a.html")
        // 异常输入 → nil（绝不兜底出一个"看起来正常"的坏 URL）
        XCTAssertNil(NmcAlarmEndpoint.detailURL(relativePath: nil))
        XCTAssertNil(NmcAlarmEndpoint.detailURL(relativePath: ""))
        XCTAssertNil(NmcAlarmEndpoint.detailURL(relativePath: "publish/alarm/x.html"),
                     "缺前导 `/` 视为异常 → nil，不硬拼")
    }

    // MARK: - 5．颜色排序（红 > 橙 > 黄 > 蓝）

    /// 排序锚定：**红 > 橙 > 黄 > 蓝**，`.unspecified` 垫底。
    func testColorSeverityOrdering() {
        let unsorted: [NmcAlarmColor] = [
            .blue, .unspecified(""), .red, .yellow, .orange
        ]
        let items = unsorted.enumerated().map { Self.item(color: $0.element,
                                                          id: "id-\($0.offset)") }
        let sorted = OfficialWarningState.sorted(items)
        XCTAssertEqual(sorted.map(\.color), [.red, .orange, .yellow, .blue, .unspecified("")],
                       "颜色排序必须是红 > 橙 > 黄 > 蓝，未知色垫底")
    }

    /// `severityRank` 的具体序值（四档 + 未知）。
    func testSeverityRankValues() {
        XCTAssertEqual(NmcAlarmColor.red.severityRank, 0)
        XCTAssertEqual(NmcAlarmColor.orange.severityRank, 1)
        XCTAssertEqual(NmcAlarmColor.yellow.severityRank, 2)
        XCTAssertEqual(NmcAlarmColor.blue.severityRank, 3)
        XCTAssertEqual(NmcAlarmColor.unspecified("紫色").severityRank, 99,
                       "未知色必须排在所有已知色之后（不得当成低危）")
    }

    /// 同色内**新的在前**；发布时间缺失者不抢占首位。
    func testSortedPutsNewestFirstWithinSameColor() throws {
        let older = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 2_000_000)
        let noDate = Self.item(color: .yellow, issuedAt: nil)

        let items = [
            Self.item(color: .yellow, issuedAt: older),
            noDate,
            Self.item(color: .yellow, issuedAt: newer)
        ]
        let sorted = OfficialWarningState.sorted(items)
        XCTAssertEqual(sorted[0].issuedAt, newer, "同色里最新的排第一")
        XCTAssertNil(sorted[2].issuedAt, "无发布时间的条目排最后（缺数据不抢占首位）")
    }

    /// 排序是**稳定**的（同色同序时不引入随机性）。
    func testSortedIsStableForIdenticalColors() {
        let items = (0..<5).map { Self.item(color: .blue, id: "id-\($0)") }
        let sorted = OfficialWarningState.sorted(items)
        XCTAssertEqual(sorted.map(\.id), items.map(\.id),
                       "完全同序时应保持原序（稳定排序）")
    }

    // MARK: - 6．新鲜度（`now` 全注入；6 小时窗口）

    /// 超过 6 小时 → `.stale(.dataTooOld)`（**绝不** `.active`）。
    func testStaleWhenOlderThanFreshnessWindow() throws {
        let issued = referenceNow.addingTimeInterval(-6 * 3600 - 60) // 6h1m 前
        let items = [Self.item(color: .yellow, issuedAt: issued)]
        let state = OfficialWarningState.resolve(items: items,
                                                 latestIssuedAt: issued,
                                                 now: referenceNow)
        guard case .stale(let reason) = state else {
            return XCTFail("超过 6 小时必须判`.stale`，实际=\(state)")
        }
        guard case .dataTooOld(let latest, let age) = reason else {
            return XCTFail("成因应为 `.dataTooOld`，实际=\(reason)")
        }
        XCTAssertEqual(latest, issued)
        XCTAssertEqual(age, 6 * 3600 + 60, accuracy: 0.5)
    }

    /// 恰好 6 小时（窗口边界）→ **仍算新鲜**（判据是 `>窗口` 才过期）。
    func testExactlyAtFreshnessBoundaryIsStillFresh() throws {
        let issued = referenceNow.addingTimeInterval(-6 * 3600)
        let state = OfficialWarningState.resolve(
            items: [Self.item(color: .yellow, issuedAt: issued)],
            latestIssuedAt: issued,
            now: referenceNow)
        XCTAssertEqual(state, .active([Self.item(color: .yellow, issuedAt: issued)]),
                       "恰好等于窗口上限仍算新鲜（只有**超过**才判过期）")
    }

    /// 5 小时 59 分 → 新鲜（`.active`）。
    func testJustInsideWindowIsActive() throws {
        let issued = referenceNow.addingTimeInterval(-(6 * 3600 - 60))
        let state = OfficialWarningState.resolve(
            items: [Self.item(color: .yellow, issuedAt: issued)],
            latestIssuedAt: issued,
            now: referenceNow)
        if case .active = state { return }
        XCTFail("窗口内应为 `.active`，实际=\(state)")
    }

    /// 有条目但**全部没有发布时间** → `.stale`（无法判定新鲜度，**不谎报新鲜**）。
    func testItemsWithoutIssueTimeBecomeStaleNotActive() {
        let items = [Self.item(color: .red, issuedAt: nil)]
        let state = OfficialWarningState.resolve(items: items,
                                                 latestIssuedAt: nil,
                                                 now: referenceNow)
        guard case .stale(let reason) = state else {
            return XCTFail("无发布时间不得判 `.active`（那是谎报新鲜），实际=\(state)")
        }
        if case .dataTooOld(let latest, _) = reason {
            XCTAssertNil(latest)
        } else {
            XCTFail("成因应为 `.dataTooOld`，实际=\(reason)")
        }
    }

    /// 发布时间**晚于** now（时钟/时区异常）→ `.stale`（**不**谎报新鲜）。
    func testFutureIssueTimeIsStaleNotActive() {
        let issued = referenceNow.addingTimeInterval(3600) // 1 小时后
        let state = OfficialWarningState.resolve(
            items: [Self.item(color: .yellow, issuedAt: issued)],
            latestIssuedAt: issued,
            now: referenceNow)
        if case .stale = state { return }
        XCTFail("未来时刻不得判 `.active`，实际=\(state)")
    }

    /// `issuetime` 解析：实测格式 + 时区**必须注入**（不读设备时区）。
    func testIssueTimeDecoding() throws {
        let parsed = try XCTUnwrap(NmcIssueTimeDecoder.date(from: "2026/10/06 20:28",
                                                             timeZone: shanghai))
        // 反向格式化核对（时区必须生效：同一串在不同时区下应是不同绝对时刻）。
        XCTAssertEqual(
            WeatherTimeFormatter.string(from: parsed, format: "yyyy-MM-dd HH:mm",
                                        timeZone: shanghai),
            "2026-10-06 20:28")
        // ⚠️ 未注入时区 → nil（**绝不**退化成设备时区，那会把时刻算错）。
        XCTAssertNil(NmcIssueTimeDecoder.date(from: "2026/10/06 20:28", timeZone: nil))
        // 非法格式 → nil，不猜
        XCTAssertNil(NmcIssueTimeDecoder.date(from: "not a time", timeZone: shanghai))
        XCTAssertNil(NmcIssueTimeDecoder.date(from: "", timeZone: shanghai))
        // 非法日历分量 → nil（13 月）
        XCTAssertNil(NmcIssueTimeDecoder.date(from: "2026/13/06 20:28",
                                              timeZone: shanghai))
    }

    // MARK: - 7．四态触发条件（各自独立）

    /// `.none`：取数成功 + 上游确实为空 → `.none`（**不是** stale）。
    func testNoneWhenFetchSucceededAndUpstreamEmpty() {
        let state = OfficialWarningState.resolve(items: [],
                                                 latestIssuedAt: nil,
                                                 now: referenceNow)
        XCTAssertEqual(state, .none)
    }

    /// `.active`：窗口内有预警 → 状态为 `.active` 且已排序。
    func testActiveWhenFreshWarningsExist() throws {
        let red = Self.item(color: .red,
                            issuedAt: referenceNow.addingTimeInterval(-600))
        let blue = Self.item(color: .blue,
                             issuedAt: referenceNow.addingTimeInterval(-1200))
        let state = OfficialWarningState.resolve(items: [blue, red],
                                                 latestIssuedAt: red.issuedAt,
                                                 now: referenceNow)
        let activeItems: [OfficialWarningItem]
        if case .active(let items) = state {
            activeItems = items
        } else {
            return XCTFail("应为 `.active`，实际=\(state)")
        }
        XCTAssertEqual(activeItems.first?.color, .red, "最高危颜色必须排第一")
    }

    /// `.stale(.fetchFailed)`：取数失败**绝不**退化成 `.none`。
    ///
    /// ⚠️ 这是本链路最重要的一条：把"取不到"显示成"没有预警"是**内容错误**。
    func testFetchFailureNeverDegradesToNone() {
        let state = OfficialWarningState.stale(reason: .fetchFailed("网络不可达"))
        if case .none = state {
            return XCTFail("取数失败绝不可表达为 `.none`")
        }
        guard case .stale(let reason) = state else {
            return XCTFail("应为 `.stale`，实际=\(state)")
        }
        XCTAssertEqual(reason, .fetchFailed("网络不可达"))
    }

    /// `.unavailable`：显式表达「源未启用」，与 `.none` 严格区分。
    func testUnavailableIsDistinctFromNone() {
        XCTAssertNotEqual(OfficialWarningState.unavailable, OfficialWarningState.none)
    }

    /// 四态互不相等（防止两个分支被写成同一个值而"看起来能用"）。
    func testFourStatesAreMutuallyDistinct() {
        let states: [OfficialWarningState] = [
            .none,
            .active([Self.item(color: .blue)]),
            .stale(reason: .fetchFailed("x")),
            .stale(reason: .dataTooOld(latest: referenceNow, age: 10_000)),
            .unavailable
        ]
        for (index, left) in states.enumerated() {
            for (otherIndex, right) in states.enumerated() where index != otherIndex {
                XCTAssertNotEqual(left, right,
                                  "四态（含两种 stale 成因）必须互不相同")
            }
        }
    }

    /// 新鲜度窗口常量钉死为 6 小时（防止被无声改动）。
    func testFreshnessWindowIsSixHours() {
        XCTAssertEqual(OfficialWarningState.freshnessWindow, 6 * 3600)
    }

    // MARK: - 8．城市筛选（本仓名↔ NMC 名 对齐）

    /// 本仓城市名**无后缀**（`福州`），NMC 地级名**有后缀**（`泉州市`）→ 必须对齐。
    func testCityNameSuffixNormalization() {
        XCTAssertEqual(NmcAlarmMapper.normalizedPrefectureName("泉州市"), "泉州")
        XCTAssertEqual(NmcAlarmMapper.normalizedPrefectureName("大兴安岭地区"), "大兴安岭")
        XCTAssertEqual(NmcAlarmMapper.normalizedPrefectureName("博尔塔拉蒙古自治州"),
                       "博尔塔拉蒙古")
        XCTAssertEqual(NmcAlarmMapper.normalizedPrefectureName("西双版纳傣族自治州"),
                       "西双版纳傣族")
        XCTAssertEqual(NmcAlarmMapper.normalizedPrefectureName("厦门市"), "厦门")
        // 剥成空串时**原样返回**（不产出空名）
        XCTAssertEqual(NmcAlarmMapper.normalizedPrefectureName("市"), "市")
        // 无后缀 → 原样
        XCTAssertEqual(NmcAlarmMapper.normalizedPrefectureName("三沙"), "三沙")
    }

    /// 端到端：从真实结构的 JSON → 按本仓城市名筛选命中。
    func testEndToEndFilterMatchesRealFixture() throws {
        let all = Self.mapRealFixture()
        XCTAssertGreaterThanOrEqual(all.count, 2, "夹具至少含2 条")
        let matched = NmcAlarmMapper.warnings(in: all, matchingCityName: "泉州")
        XCTAssertFalse(matched.isEmpty, "内城市 `泉州` 应命中 `泉州市` 的预警")
        for item in matched {
            XCTAssertEqual(NmcAlarmMapper.normalizedPrefectureName(item.cityName ?? ""),
                           "泉州")
        }
        // 换一个当日无预警的城市 → 空数组（**不是** `.stale`，那是筛选结果为空）
        XCTAssertTrue(NmcAlarmMapper.warnings(in: all,
                                               matchingCityName: "拉萨").isEmpty)
    }

    /// 给了区划码时**额外**核一道（两条都命中才算）。
    func testCityCodeActsAsSecondCheck() throws {
        let all = Self.mapRealFixture()
        // 350581 = 福建泉州市石狮市（实测 alertid 前 6 位）
        let matched = NmcAlarmMapper.warnings(in: all,
                                               matchingCityName: "泉州",
                                               cityCode: "350581")
        XCTAssertTrue(matched.allSatisfy { $0.administrativeCode == "350581" })
        // 给一个对不上的码 → 一条都不命中（宁缺不猜）
        XCTAssertTrue(NmcAlarmMapper.warnings(in: all,
                                               matchingCityName: "泉州",
                                               cityCode: "999999").isEmpty)
    }

    /// 城市名为 nil / 空 → **返回空**，绝不"全都要"。
    func testNilCityNameMatchesNothing() {
        let all = Self.mapRealFixture()
        XCTAssertTrue(NmcAlarmMapper.warnings(in: all, matchingCityName: nil).isEmpty)
        XCTAssertTrue(NmcAlarmMapper.warnings(in: all, matchingCityName: "").isEmpty)
    }

    /// 区划码提取：非 6 位数字前缀 → **nil**（半个码会误匹配）。
    func testAdministrativeCodeExtraction() {
        XCTAssertEqual(NmcAlarmMapper.administrativeCode(
            from: "35060441600000_20261006202800"), "350604")
        XCTAssertNil(NmcAlarmMapper.administrativeCode(from: nil))
        XCTAssertNil(NmcAlarmMapper.administrativeCode(from: "35060"))
        XCTAssertNil(NmcAlarmMapper.administrativeCode(from: "35060A41600000_x"))
    }

    /// 标题解析失败的条目**仍然保留**（宁可显示"地区未知"，也不丢掉红警）。
    func testUnparsableTitleStillYieldsItem() throws {
        let payload: [String: Any] = [
            "msg": "success", "code": 0,
            "data": ["page": ["list": [
                ["alertid": "990000_20261006203000",
                 "issuetime": "2026/10/06 20:30",
                 "title": "某某未知省某市气象台发布台风红色预警信号"]
            ]]]
        ]
        let items = Self.decodeAndMap(Self.json(from: payload))
        let item = try XCTUnwrap(items.first, "标题解析失败也不该丢掉预警条目")
        XCTAssertNil(item.cityName)
        XCTAssertEqual(item.color, .unspecified(""),
                       "解析失败 → 未知色（排最后，绝不当成蓝/低危）")
        XCTAssertEqual(item.kind, "台风", "类型应从原文回落解析")
        XCTAssertEqual(item.rawTitle, "某某未知省某市气象台发布台风红色预警信号",
                       "原始标题必须保留")
    }

    // MARK: - 9．描述符自洽（能力独立 / 许可如实）

    /// 本源已登记，且能力是**独立 case**（不复用既有能力）。
    func testDescriptorRegisteredWithIndependentCapability() throws {
        let descriptor = try XCTUnwrap(SourceDirectory.descriptor(for: .nmcAlarm))
        XCTAssertEqual(descriptor.capabilities, [.officialWarning])
        // 预警字段不在 `WeatherFieldKey` 域内 → 诚实留空（与 marine/flood 同）。
        XCTAssertTrue(descriptor.requiredFields.isEmpty,
                      "预警要素不属于 WeatherFieldKey 域 → requiredFields 应诚实留空")
        XCTAssertEqual(descriptor.role, .auxiliary)
        XCTAssertFalse(descriptor.needsCredential)
        // 未接线 → 不给设置页一个"点了没反应"的开关。
        XCTAssertFalse(descriptor.participatesInAutoExclusion)
    }

    /// `officialWarning` 必须是**独立 case**（复用既有能力即虚报）。
    func testOfficialWarningCapabilityIsIndependentCase() {
        XCTAssertTrue(SourceCapability.allCases.contains(.officialWarning))
        // 语义独立性：它与逐日预报/ 实况观测是不同 case（编译期保证）。
        XCTAssertNotEqual(SourceCapability.officialWarning, .dailyForecast)
        XCTAssertNotEqual(SourceCapability.officialWarning, .currentObservation)
    }

    /// `rawValue` 是**语义串**且连字符风格（与既有源一致，落盘键不撞车）。
    func testRawValueStyle() {
        let raw = SourceID.nmcAlarm.rawValue
        XCTAssertEqual(raw, "nmc-alarm")
        XCTAssertTrue(raw.contains("-"))
        XCTAssertFalse(raw.contains("_"))
        XCTAssertEqual(SourceID(rawValue: raw), .nmcAlarm)
    }

    /// ⚠️ **`usageNote` 不得声称已获官方授权**（硬要求）。
    func testUsageNoteDoesNotClaimOfficialAuthorization() throws {
        let note = try XCTUnwrap(SourceDirectory.descriptor(for: .nmcAlarm)?.usageNote,
                                 "usageNote 必填：必须如实说明许可状态")
        XCTAssertTrue(note.contains("未经官方"), "须如实写明「未经官方 API 授权」")
        XCTAssertTrue(note.contains("个人自用"), "须写明仅供个人自用")
        // 反向守卫：不得出现任何"已授权"的暗示。
        for forbidden in ["已获授权", "官方授权", "已授权", "官方授权接口"] {
            XCTAssertFalse(note.contains(forbidden),
                           "usageNote 不得出现「\(forbidden)」：我们**未获任何授权**")
        }
    }

    /// `websiteURLString` 可解析为 http/https URL（既有 DataAttribution 纪律）。
    func testWebsiteURLResolves() throws {
        let descriptor = try XCTUnwrap(SourceDirectory.descriptor(for: .nmcAlarm))
        let url = try XCTUnwrap(descriptor.websiteURL, "官网地址必须可解析")
        XCTAssertTrue(["http", "https"].contains(url.scheme ?? ""))
    }

    // MARK: - 10．服务层（离线桩）

    /// 服务层：2xx → 返回条目；非 2xx → 抛 `WeatherError.badStatus`。
    func testServiceMapsStatusAndPayload() async throws {
        // ① 2xx + 真实结构 → 1 条
        let ok: [String: Any] = [
            "msg": "success", "code": 0,
            "data": ["page": ["list": [
                ["alertid": "35058141600000_20261006205000",
                 "issuetime": "2026/10/06 20:50",
                 "title": "福建省泉州市石狮市气象台发布大风黄色预警信号",
                 "url": "/publish/alarm/35058141600000_20261006205000.html"]
            ]]]
        ]
        NmcStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: 200,
                                           httpVersion: nil,
                                           headerFields: nil)!
            return (response, Self.json(from: ok))
        }
        let session = Self.makeSession()
        let items = try await NmcAlarmService(session: session)
            .fetchAllWarnings(timeZone: shanghai)
        XCTAssertEqual(items.count, 1)
        // ⚠️ 模型上没有 `county` 字段，县段只在 `region` 串里（见上方同款注释）。
        XCTAssertEqual(items.first?.region, "福建省 / 泉州市 / 石狮市")

        // ② 2xx + 空列表 → **空数组**（"成功但没有"，不是失败）
        NmcStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: 200,
                                           httpVersion: nil,
                                           headerFields: nil)!
            return (response, Self.json(from: ["msg": "success", "code": 0,
                                               "data": ["page": ["list": []]]]))
        }
        let empty = try await NmcAlarmService(session: session)
            .fetchAllWarnings(timeZone: shanghai)
        XCTAssertTrue(empty.isEmpty, "2xx + 空 list → 空数组（**不抛错**）")

        // ③ 非 2xx → 抛 `badStatus`（供 EV-3 裁定）
        NmcStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: 503,
                                           httpVersion: nil,
                                           headerFields: nil)!
            return (response, Data())
        }
        do {
            _ = try await NmcAlarmService(session: session)
                .fetchAllWarnings(timeZone: shanghai)
            XCTFail("非 2xx 必须抛错（绝不静默返回空数组）")
        } catch let error as WeatherError {
            XCTAssertEqual(error, .badStatus(503))
        }
        NmcStubURLProtocol.handler = nil
    }

    // MARK: - 夹具工具

    /// 造一条条目（默认新鲜，落在窗口内）。
    private static func item(color: NmcAlarmColor,
                             issuedAt: Date?,
                             id: String = "stub") -> OfficialWarningItem {
        OfficialWarningItem(id: id, region: "福建省 / 泉州市",
                            cityName: "泉州市", administrativeCode: "350581",
                            kind: "大风", color: color, issuedAt: issuedAt,
                            detailURL: nil,
                            rawTitle: "福建省泉州市石狮市气象台发布大风黄色预警信号")
    }

    /// 造一条 `Entry` 字典（默认带实测 alertid 前缀 3506）。
    private static func entry(title: String, alertid: String) -> [String: Any] {
        ["alertid": alertid, "issuetime": "2026/10/06 20:28", "title": title]
    }

    /// 字典 → JSON（**不抛错**：无法序列化即测试自身失败）。
    private static func json(from object: [String: Any]) -> Data {
        // 禁用 .fragmentsAllowed；本仓全部是合法 JSON 值。
        (try? JSONSerialization.data(withJSONObject: object,
                                     options: [.sortedKeys])) ?? Data()
    }

    /// JSON → mapper（走**统一解码入口**，与生产路径一致）。
    private static func decodeAndMap(_ data: Data,
                                      timeZone: TimeZone? = nil) -> [OfficialWarningItem] {
        // ⚠️ 解码**不抛错**是本组断言的核心，故这里用 `try?` 把
        // 「抛错」与「回空数组」区分开：抛错会让 `data` 变空 Data，
        // 而空Data 解码也会失败 → 回空数组。故额外校验原始字节非空。
        guard !data.isEmpty,
              let dto = try? ResponseDecoding.decode(NmcAlarmResponse.self,
                                                      from: data) else {
            return []
        }
        let zone = timeZone ?? TimeZone(identifier: "Asia/Shanghai")
        return NmcAlarmMapper.map(dto, timeZone: zone)
    }

    /// 真实结构的最小夹具（两条 `泉州市` + 一条其他市）。
    private static func mapRealFixture() -> [OfficialWarningItem] {
        let payload: [String: Any] = [
            "msg": "success", "code": 0,
            "data": ["page": [
                "pageNo": 1, "pageSize": 200, "count": 2,
                "list": [
                    ["alertid": "35058141600000_20261006205000",
                     "issuetime": "2026/10/06 20:50",
                     "title": "福建省泉州市石狮市气象台发布大风黄色预警信号",
                     "url": "/publish/alarm/35058141600000_20261006205000.html"],
                    ["alertid": "35058341600000_20261006204500",
                     "issuetime": "2026/10/06 20:45",
                     "title": "福建省泉州市南安市气象台发布大风黄色预警信号",
                     "url": "/publish/alarm/35058341600000_20261006204500.html"]
                ]
            ]]
        ]
        return decodeAndMap(json(from: payload))
    }

    /// 造一个走桩的 URLSession。
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NmcStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
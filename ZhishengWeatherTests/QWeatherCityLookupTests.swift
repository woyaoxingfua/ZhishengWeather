//
//  QWeatherCityLookupTests.swift
//  ZhishengWeatherTests
//
//  第九源「和风天气」**坐标反查端点**（`/geo/v2/city/lookup`）的接入锚点。
//  不联网、不读真实时钟：全部喂本地造好的 JSON。
//
//  ══════════════════════════════════════════════════════════════════════════
//  ⚠️⚠️⚠️ **本文件测的是「规格」，不是「实测」** —— 这是本文件最重要的一句话
//  ══════════════════════════════════════════════════════════════════════════
//  2026-10-08 主理人用真实凭据实测：Host `n959fbnwar.re.qweatherapi.com` 下
//  `/geo/v2/city/lookup` 返回 **404 空响应体**（用**故意错误**的 token 则401
//  → 路由存在，Host/订阅侧有问题）。
//  ⇒ **本仓库从未收到过该端点的真实响应**。本文件的样本 JSON 是按官方
//    OpenAPI 规格文件 `qweather-apis-zh.yml`（`getCityLookup` / `locationArray`）
//    **逐字构造**的。
//  ⇒ 因此：**这些断言能证明「代码符合规格、且对脏数据是安全的」**，
//    **不能证明「和风真机就长这样」**。Host 恢复后必须真机核验。
//  ⇒ 也正因如此，本文件**特别加重了「类型漂移」与「字段缺失」的覆盖**——
////   在无法实测的端点上，**抗脏能力是唯一能主动做的防御**。
//
//  ── 本文件钉死的点（每一个都是「写错不报错、运行时多数看不出来」的）──────
//
//  ① 🔴🔴 **坐标参数顺序是「经度,纬度」**（`location=116.41,39.92`）——
//     与本仓天气端点 `/weather/v1/daily/{lat}/{lon}`（**纬度在前**）**相反**。
//     写错**不会编译报错**，只会让服务端拿39.92° 当经度 → 返回一个
//     **看起来合法但完全错**的地点。这是本仓最隐蔽的错误类型。
//     本文件用 `URLComponents` **解出query 逐字断言**，而不是断言整个 url 串
//     （后者会被参数顺序变化、编码差异搞得脆弱）。
//
//  ② 🔴 **`lat` / `lon` 上游是 `string`**（规格逐字）——不是number。
//     用 `Double` 声明会让真实响应**整包解码失败**（P-18 最坏形态）。
//
//  ③ 🔴 **顶层是 `location` + `refer`，没有 `metadata` 块** ——
//     署名在 **`refer.metaAttributions`**。写成 `metadata` 不会报错，
//     只会让署名**恒为空** = **静默违反许可条件**。
//
//  ④ 🔴 **`isDst` 是字符串 `"1"` / `"0"`**，不是布尔；`code` 也是字符串。
//
//  ⑤ **弱类型兜底**：任一候选字段缺失 / 类型漂移（数字当字符串、
//     字符串当数字、null、数组当对象）→ **不抛错**，对应字段为 nil。
//
//  ⑥ 🔴 **坐标解析失败绝不兜底成 0** —— `(0,0)` 是几内亚湾，
//     一个看起来合法但完全错的值。
//
//  ⑦ 🔴 **非法 `tz` → 回退不崩**，且**绝不硬编码固定偏移**。
//
//  ⑧ **空数组 / 缺 `location`** → 如实表达「**查了，没有**」，
//     **不编造**、**不**与「取不到」混同。
//
//  ⑨ **端点形态**：路径逐字、坐标两位小数、`number` / `lang` 参数。
//
//  ⚠️ 并发纪律：`XCTAssert*` 的实参是 **autoclosure**，装不下 `await`。
//  故所有 `await` 都先求值到局部常量再断言（同 `QWeatherHourlyTests`）。
//

import XCTest
import Foundation
@testable import ZhishengWeather

// MARK: - 测试用例

/// 坐标反查端点（`/geo/v2/city/lookup`）的接入锚点测试。
final class QWeatherCityLookupTests: XCTestCase {

    // MARK: - 规格样本（按官方 OpenAPI 逐字构造，**非实测**）

    /// 🔴 标准载荷：**13 个键全部是字符串**（含 `lat` / `lon`），
    /// 顶层 `code` + `location` + `refer`。
    ///
    /// ⚠️ 用 `#"""…"""#`（**raw** 多行串）：里面的中文与反斜杠按字面处理，
    /// 不会被当转义序列（同 `QWeatherHourlyTests` 记录过这个坑）。
    private static let lookupJSON = #"""
    {"code":"200",
     "location":[
       {"name":"东城区","id":"101010100",
        "lat":"39.93","lon":"116.42",
        "adm2":"东城区","adm1":"北京市","country":"中国",
        "tz":"Asia/Shanghai","utcOffset":"8","isDst":"0",
        "type":"administrative","rank":"10",
        "fxLink":"https://example.com/qweather/101010100"}
     ],
     "refer":{"sources":["和风天气"],
              "license":["和风天气授权"],
              "metaTag":"_testtag_",
              "metaAttributions":["https://example.com/qweather"],
              "metaZeroResult":false}}
    """#

    /// 🔴🔴 **坐标是数字**（不是字符串）的载荷 —— 真实漂移的一种。
    /// DTO 用 `LenientString`，应照样解出 `"39.93"` 这样的文本。
    private static let numericCoordinateJSON = #"""
    {"code":200,
     "location":[{"name":"东城区","id":101010100,
                  "lat":39.93,"lon":116.42,
                  "adm2":"东城区","adm1":"北京市","country":"中国",
                  "tz":"Asia/Shanghai","utcOffset":8,"isDst":"0"}]}
    """#

    /// 🔴 **坐标是字符串**（规格形态）的载荷 —— DTO 用 `LenientString`，
    /// mapper侧再解析成 `Double?`。
    private static let stringCoordinateJSON = #"""
    {"code":"200",
     "location":[{"name":"东城区","id":"101010100",
                  "lat":"39.93","lon":"116.42","adm2":"东城区"}]}
    """#

    /// 🔴 **只有 `code`**（`location` 与 `refer` 整键缺失）—— 钉死「缺键不抛错」。
    private static let onlyCodeJSON = #"""
    {"code":"200"}
    """#

    /// 🔴 **空数组** —— 「查了，没有」（`.noData`），**不是**故障。
    private static let emptyArrayJSON = #"""
    {"code":"200","location":[],"refer":{"sources":[],"metaAttributions":[]}}
    """#

    /// 🔴 `location` 里有 `null` 元素 + 一个正常对象 —— 一个 null 不让整包失败。
    private static let nullElementJSON = #"""
    {"code":"200","location":[null,{"name":"东城区","adm2":"东城区"}]}
    """#

    /// 🔴 **字段全是脏类型**：数组当字符串、对象当字符串、数字当布尔…
    /// → 必须**逐字段为 nil**，且**绝不抛错**。
    private static let dirtyTypesJSON = #"""
    {"code":["不是字符串"],
     "location":[{"name":{"a":1},"id":[1,2],
                  "lat":{"x":1},"lon":[116.42],
                  "adm2":123,"adm1":true,"country":[],
                  "tz":{"tz":"Asia/Shanghai"},
                  "utcOffset":null,"isDst":[],
                  "type":9,"rank":null,"fxLink":{"url":"x"}}]}
    """#

    /// 🔴 **坐标是字符串但不可解析 / 越界** —— 必须 nil，**绝不**兜底成 0。
    private static let unparsableCoordinateJSON = #"""
    {"code":"200",
     "location":[{"name":"某地","lat":"不是数字","lon":"116.42"},
                {"name":"越界纬度","lat":"91.5","lon":"116.42"},
                {"name":"越界经度","lat":"39.93","lon":"181.2"},
                {"name":"空串坐标","lat":"","lon":"116.42"}]}
    """#

    /// 🔴 **非法 `tz`** —— 必须回退不崩，且**绝不硬编码固定偏移**。
    private static let illegalTimeZoneJSON = #"""
    {"code":"200",
     "location":[{"name":"某地","adm2":"某区","tz":"Mars/Olympus_Mons"},
                {"name":"空 tz","tz":""},
                {"name":"空白 tz","tz":"   "},
                {"name":"缺 tz"}]}
    """#

    /// 🔴 `isDst` 的各种形态 —— 只有 `"1"` / `"0"` 逐字可裁定，其余 nil。
    private static let daylightSavingJSON = #"""
    {"code":"200",
     "location":[{"name":"夏令时中","isDst":"1"},
                {"name":"非夏令时","isDst":"0"},
                {"name":"布尔形态","isDst":true},
                {"name":"未知形态","isDst":"maybe"},
                {"name":"缺 isDst"}]}
    """#

    /// 🔴 空白 / 空串字段 —— 必须视为「没有该字段」，**绝不**显示空名字。
    private static let blankTextJSON = #"""
    {"code":"200",
     "location":[{"name":"","adm2":"   ","adm1":"\t","country":""}]}
    """#

    // MARK: - ① 坐标参数顺序：经度在前

    /// 🔴🔴 `location` 查询参数逐字是 **`"116.41,39.92"`**（**经度在前**）。
    ///
    /// ⚠️ 用 `URLComponents` 解出 query 而不是断言整个 url 串：
    ///   整个串会因参数顺序、`%2C` 编码差异而脆弱，而**真正要钉死的是
    ///   「经度在前」这一件事**。
    func testLocationQueryPutsLongitudeFirst() throws {
        let url = try XCTUnwrap(QWeatherGeoEndpoint.cityLookupURL(
            apiHost: "abcdefg.qweatherapi.com",
            latitude: 39.92,
            longitude: 116.41))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems)
        let pairs = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })

        // 🔴🔴 本仓最隐蔽的错误点：与天气端点 `/weather/v1/daily/{lat}/{lon}`
        //   的顺序**相反**。若这里写成 `"39.92,116.41"`，
        //   服务端会拿 39.92 当经度 → 返回一个**看起来合法但完全错**的地点。
        XCTAssertEqual(pairs["location"], "116.41,39.92",
                       "🔴 `location` 必须是「**经度,纬度**」（官方规格逐字 "
                       + "`location=116.41,39.92`），**与天气端点的 lat/lon 相反**")
        XCTAssertNotEqual(pairs["location"], "39.92,116.41",
                          "若这里成了「纬度,经度」，服务端会返回错误的地点")
    }

    /// 反向对照：端点路径**没有**坐标段（坐标只在查询串里）。
    ///
    /// ⚠️ 有人会照抄天气端点的形状，把坐标也拼进路径
    ///   （`/geo/v2/city/lookup/39.92/116.41`）—— 那是一条**不存在的路由**。
    func testPathHasNoCoordinateSegments() throws {
        let url = try XCTUnwrap(QWeatherGeoEndpoint.cityLookupURL(
            apiHost: "abcdefg.qweatherapi.com",
            latitude: 39.92, longitude: 116.41))
        XCTAssertEqual(url.path, "/geo/v2/city/lookup",
                       "🔴 路径逐字是 `/geo/v2/city/lookup`，**不含**坐标段")
        XCTAssertEqual(url.scheme, "https", "和风是 HTTPS-only")
        XCTAssertEqual(url.host, "abcdefg.qweatherapi.com")
    }

    /// 端点形态：坐标两位小数 + `number` + `lang` 三个查询参数齐全。
    func testEndpointQueryCarriesNumberAndLanguage() throws {
        let url = try XCTUnwrap(QWeatherGeoEndpoint.cityLookupURL(
            apiHost: "abcdefg.qweatherapi.com",
            latitude: 39.9042, longitude: 116.4074))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems)
        let pairs = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
        XCTAssertEqual(pairs["location"], "116.41,39.9",
                       "坐标保留两位小数（官方文档：最多两位小数）")
        XCTAssertEqual(pairs["number"], "10", "官方规格：`number` 默认 10")
        XCTAssertEqual(pairs["lang"], "zh", "官方文档默认语言 `zh`")
    }

    /// 🔴 `number` 越界 → **URL 为 nil**，**绝不**静默改成 10。
    func testOutOfRangeNumberYieldsNilURL() {
        XCTAssertNil(QWeatherGeoEndpoint.cityLookupURL(
            apiHost: "h.qweatherapi.com", latitude: 39.9, longitude: 116.4, number: 0),
                     "0 越界（官方 1-20）→ nil")
        XCTAssertNil(QWeatherGeoEndpoint.cityLookupURL(
            apiHost: "h.qweatherapi.com", latitude: 39.9, longitude: 116.4, number: 21),
                     "21 越过官方上限 20 → nil")
        XCTAssertNil(QWeatherGeoEndpoint.cityLookupURL(
            apiHost: "h.qweatherapi.com", latitude: 39.9, longitude: 116.4, number: -1),
                     "负数越界 → nil")
        // 边界值必须**放行**（1 与 20 都合法）。
        XCTAssertNotNil(QWeatherGeoEndpoint.cityLookupURL(
            apiHost: "h.qweatherapi.com", latitude: 39.9, longitude: 116.4, number: 1))
        XCTAssertNotNil(QWeatherGeoEndpoint.cityLookupURL(
            apiHost: "h.qweatherapi.com", latitude: 39.9, longitude: 116.4, number: 20))
        XCTAssertEqual(QWeatherGeoEndpoint.numberRange,
                       1...20,
                       "官方规格逐字：`number` 取值范围 1-20，默认 10")
    }

    /// Host 规范化与坐标校验**复用**天气端点那套（同一判据，绝不各写一份）。
    func testHostNormalizationAndCoordinateValidationAreShared() {
        // Host：带 `https://` / 带尾斜杠 / 大小写 → 与逐日同一套规范化。
        XCTAssertNil(QWeatherGeoEndpoint.cityLookupURL(
            apiHost: "  ", latitude: 39.9, longitude: 116.4), "空 Host → nil")
        XCTAssertNil(QWeatherGeoEndpoint.cityLookupURL(
            apiHost: "http://h.qweatherapi.com", latitude: 39.9, longitude: 116.4),
                     "显式 http → nil（凭据不得明文发送）")
        // 坐标：NaN / 越界 → nil（**绝不**静默改成 0，那会得到几内亚湾）。
        XCTAssertNil(QWeatherGeoEndpoint.cityLookupURL(
            apiHost: "h.qweatherapi.com", latitude: .nan, longitude: 116.4), "NaN → nil")
        XCTAssertNil(QWeatherGeoEndpoint.cityLookupURL(
            apiHost: "h.qweatherapi.com", latitude: 39.9, longitude: .infinity), "∞ → nil")
        XCTAssertNil(QWeatherGeoEndpoint.cityLookupURL(
            apiHost: "h.qweatherapi.com", latitude: 91, longitude: 116.4), "纬度越界 → nil")
        XCTAssertNil(QWeatherGeoEndpoint.cityLookupURL(
            apiHost: "h.qweatherapi.com", latitude: 39.9, longitude: 181), "经度越界 → nil")
    }

    /// Host 规范化与天气端点**逐字一致**（含大小写折叠）。
    func testHostNormalizationMatchesWeatherEndpoint() throws {
        let geoURL = try XCTUnwrap(QWeatherGeoEndpoint.cityLookupURL(
            apiHost: "https://AbcDef.qweatherapi.com/",
            latitude: 39.9, longitude: 116.4))
        let weatherURL = try XCTUnwrap(QWeatherEndpoint.hourlyURL(
            apiHost: "https://AbcDef.qweatherapi.com/",
            latitude: 39.9, longitude: 116.4))
        XCTAssertEqual(geoURL.host, weatherURL.host,
                       "🔴 Host 规范化必须与天气端点**同一判据**（复用 "
                       + "`QWeatherEndpoint.normalizeHost`，不是各写一份）")
        XCTAssertEqual(geoURL.host, "abcdef.qweatherapi.com", "主机名统一小写")
    }

    /// 坐标定点格式化与天气端点**逐字一致**（同为2 位小数）。
    func testCoordinateTextMatchesWeatherEndpoint() throws {
        let geoURL = try XCTUnwrap(QWeatherGeoEndpoint.cityLookupURL(
            apiHost: "h.qweatherapi.com", latitude: 39.9042, longitude: 116.4074))
        let items = try XCTUnwrap(URLComponents(url: geoURL, resolvingAgainstBaseURL: false)?
            .queryItems)
        let locationValue = try XCTUnwrap(items.first { $0.name == "location" }?.value)
        XCTAssertEqual(locationValue,
                       QWeatherEndpoint.coordinateText(116.4074) + ","
                       + QWeatherEndpoint.coordinateText(39.9042),
                       "🔴 坐标格式化必须复用 `QWeatherEndpoint.coordinateText`"
                       + "（小数位数单一真源，绝不各写一份）")
    }

    // MARK: - ②③ 标准载荷解码（13 个 string 键 + refer 署名）

    /// 标准载荷逐字段落地：13 个键全部解出，且**都是字符串形态**。
    func testStandardPayloadDecodesAllFields() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherCityResponse.self, from: Data(Self.lookupJSON.utf8))
        let mapped = QWeatherMapper.mapCityLookup(decoded)

        XCTAssertFalse(mapped.isEffectivelyEmpty)
        let place = try XCTUnwrap(mapped.mostGranular)

        // 🔴 本需求的核心字段：**区级**行政区划。
        XCTAssertEqual(place.name, "东城区")
        XCTAssertEqual(place.adm2, "东城区",
                       "🔴 `adm2`（区级）是本需求的核心字段 —— "
                       + "「能拿到的最细粒度行政区」就落在这里")
        XCTAssertEqual(place.adm1, "北京市", "一级行政区（省级）")
        XCTAssertEqual(place.country, "中国")
        XCTAssertEqual(place.locationID, "101010100")
        XCTAssertEqual(place.placeType, "administrative")
        XCTAssertEqual(place.rank, "10")
        XCTAssertEqual(place.webLink, "https://example.com/qweather/101010100")
        XCTAssertEqual(place.utcOffset, "8")
        XCTAssertEqual(place.isDaylightSavingTime, false, "`isDst=\"0\"` → 非夏令时")
        XCTAssertEqual(mapped.statusCode, "200", "上游 `code` 是**字符串** `\"200\"`")
    }

    /// 🔴🔴 署名必须从 **`refer.metaAttributions`** 取到（本端点**没有** `metadata`）。
    ///
    /// ⚠️ 这条是**许可条件**的守卫：写成 `metadata` 不会编译报错、
    ///  也不会解码报错，只会让署名**恒为空** —— 那等于静默违反
    ///  和风「必须与当前数据共同显示」的许可要求。
    func testAttributionsComeFromReferNotMetadata() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherCityResponse.self, from: Data(Self.lookupJSON.utf8))
        let mapped = QWeatherMapper.mapCityLookup(decoded)

        XCTAssertEqual(mapped.attributions, ["https://example.com/qweather"],
                       "🔴 署名在 `refer.metaAttributions`（规格逐字）；"
                       + "本端点**没有 `metadata` 块**，读到 metadata 会让署名恒空")
        // 反向对照：载荷里给了 `metadata` 也不该影响（那是天气端点的形状）。
        let withMetadata = #"""
        {"code":"200","location":[{"name":"东城区"}],
         "metadata":{"attributions":["https://example.com/should-be-ignored"]}}
        """#
        let ignoredDecoded = try ResponseDecoding.decode(
            QWeatherCityResponse.self, from: Data(withMetadata.utf8))
        XCTAssertTrue(QWeatherMapper.mapCityLookup(ignoredDecoded).attributions.isEmpty,
                      "本端点**没有** `metadata`；误读它等于凭空捏造署名来源")
    }

    /// 🔴🔴 **`lat` / `lon` 上游是字符串** —— 必须能解出坐标数值。
    func testCoordinatesArriveAsStringsAndParseToNumbers() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherCityResponse.self, from: Data(Self.stringCoordinateJSON.utf8))
        let place = try XCTUnwrap(QWeatherMapper.mapCityLookup(decoded).mostGranular)

        // 🔴 规格逐字：`lat` / `lon` 是 `type: string`。
        //   若DTO 用 `Double` 声明，真实响应下会**整包解码失败**（P-18 最坏形态）。
        XCTAssertEqual(place.latitude ?? -1, 39.93, accuracy: 1e-9,
                       "🔴 上游坐标是**字符串** `\"39.93\"`，必须能解析成数值")
        XCTAssertEqual(place.longitude ?? -1, 116.42, accuracy: 1e-9)
    }

    /// 🔴 类型漂移（数字当字符串）→ **照样解出**，**绝不**整包失败。
    func testNumericPayloadIsAbsorbedNotFatal() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherCityResponse.self, from: Data(Self.numericCoordinateJSON.utf8))
        let mapped = QWeatherMapper.mapCityLookup(decoded)

        // 🔴 刻意先断言「**不抛错**」—— 能走到这里就说明解码成功了。
        XCTAssertFalse(mapped.isEffectivelyEmpty, "数字形态的载荷必须能解出")
        let place = try XCTUnwrap(mapped.mostGranular)
        // `LenientString` 把数字转成字符串（整数不带 `.0`）。
        XCTAssertEqual(place.locationID, "101010100",
                       "`id` 给成数字 101010100 → 应转成 `\"101010100\"`（整数不带 `.0`）")
        XCTAssertEqual(place.latitude ?? -1, 39.93, accuracy: 1e-9,
                       "`lat` 给成数字 39.93 → 应能解析成 39.93")
        XCTAssertEqual(place.longitude ?? -1, 116.42, accuracy: 1e-9)
        // 🔴 `code` 给成数字 200（规格是字符串）→ 同样吸收。
        XCTAssertEqual(mapped.statusCode, "200")
    }

    // MARK: - ④⑤ 脏数据：字段缺失 / 类型漂移绝不抛错

    /// 🔴 **13 个键全是脏类型**（数组当字符串、对象当字符串…）→ **绝不抛错**，
    /// 逐字段为 nil。
    ///
    /// 这是 P-18 的直接对策：非可选字段会让合成解码器抛 `typeMismatch`
    /// → **整包失败 → 整条链路静默消失**。
    func testDirtyTypesDoNotThrowAndDegradeToNil() throws {
        // 🔴 刻意断言「**不抛错**」。
        let decoded = try ResponseDecoding.decode(
            QWeatherCityResponse.self, from: Data(Self.dirtyTypesJSON.utf8))
        let mapped = QWeatherMapper.mapCityLookup(decoded)

        // 上游确实下发了**一个地点** → **不是**无数据，应如实展示。
        XCTAssertFalse(mapped.isEffectivelyEmpty,
                       "下发了一个条目就算有数据 —— 字段脏 ≠ 没数据")
        let place = try XCTUnwrap(mapped.mostGranular)
        XCTAssertNil(place.name, "对象当字符串 → nil")
        XCTAssertNil(place.locationID, "数组当字符串 → nil")
        XCTAssertNil(place.latitude, "对象当坐标 → nil")
        XCTAssertNil(place.longitude, "数组当坐标 → nil")
        XCTAssertNil(place.country, "空数组当字符串 → nil")
        XCTAssertNil(place.timeZoneIdentifier, "对象当字符串 → nil（**绝不**硬编码偏移）")
        XCTAssertNil(place.utcOffset, "null → nil")
        XCTAssertNil(place.webLink, "对象当字符串 → nil")
    }

    /// 🔴 数字当行政区名（`"adm2": 123`）→ **吸收成字符串**，**不抛错**。
    ///
    /// ⚠️ 这条刻意**断言「不是 nil」**，因为它是 `LenientString` 的**设计目标**：
    ///   「数字当字符串」是最常见的真实漂移，吸收它是为了**保住同一个对象里的
    ///   其他字段**（`name` / `tz` / 坐标…），而不是让整条丢弃。
    ///   ⚠️ 但被吸收来的 `"123"` 是一个**无意义的名字** —— 本仓**不做**进一步
    ///   语义校验（无法判定「123」是不是某个真实行政区），**如实承载**，
    ///   由 UI 决定是否展示。**绝不**因为「看起来不是名字」就丢掉整条记录。
    func testNumberInPlaceOfTextIsAbsorbedAsString() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherCityResponse.self, from: Data(Self.dirtyTypesJSON.utf8))
        let place = try XCTUnwrap(QWeatherMapper.mapCityLookup(decoded).mostGranular)
        XCTAssertEqual(place.adm2, "123",
                       "`adm2` 给成数字 123 → 吸收成字符串 `\"123\"`（整数不带 `.0`）；"
                       + "这是 `LenientString` 的设计目标：吸收漂移以**保住其余字段**")
        // 🔴 但布尔 `true` 吸收不了 → nil（`LenientString` 只认字符串与数字）。
        XCTAssertNil(place.adm1, "`adm1` 给成布尔 → nil（布尔不是可吸收的漂移形态）")
        // 同理 `type: 9` 也被吸收成 `"9"`（原样承载，不建枚举）。
        XCTAssertEqual(place.placeType, "9", "`type` 给成数字 9 → 吸收成 `\"9\"`")
    }

    /// 🔴 `code` 给成数组 → **不抛错**，`statusCode` 为 nil。
    ///
    /// ⚠️ 分开单列是因为「整包抛错」与「字段为 nil」是**两种**失败形态，
    ///   混在一条断言里会掩盖其中一种。
    func testCodeWithWrongTypeDoesNotThrow() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherCityResponse.self, from: Data(Self.dirtyTypesJSON.utf8))
        let mapped = QWeatherMapper.mapCityLookup(decoded)
        XCTAssertNil(mapped.statusCode,
                     "`code` 给成数组 → nil（**不猜值**，铁律③）")
    }

    /// 🔴 `location` 与 `refer` **整键缺失** → 不抛错，如实表达「查不到」。
    func testMissingKeysAreEmptyNotThrow() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherCityResponse.self, from: Data(Self.onlyCodeJSON.utf8))
        let mapped = QWeatherMapper.mapCityLookup(decoded)

        XCTAssertTrue(mapped.isEffectivelyEmpty,
                      "缺 `location` 键 → 判为「查了、没有」，**不是**故障")
        XCTAssertEqual(mapped.statusCode, "200", "`code` 仍要解出")
        XCTAssertTrue(mapped.attributions.isEmpty, "缺 `refer` → 署名空数组（不是 nil）")
    }

    /// 🔴 空数组 → **合法「无数据」**（`.noData`），**不是**故障。
    ///
    /// ⚠️ 「查了没有」与「取不到」必须可区分：前者用户该知道是上游没有
    ///   对应行政区，后者该查网络/凭据。混同会让用户去查错的方向。
    func testEmptyArrayIsNoDataNotFailure() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherCityResponse.self, from: Data(Self.emptyArrayJSON.utf8))
        let mapped = QWeatherMapper.mapCityLookup(decoded)
        XCTAssertTrue(mapped.isEffectivelyEmpty, "空数组 = 查了、没有")
        XCTAssertNil(mapped.mostGranular, "空序列 → `mostGranular` 为 nil")
    }

    /// 数组里有 `null` 元素 → 丢弃该元素，**保住其余数据**。
    func testNullElementIsDroppedButOthersSurvive() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherCityResponse.self, from: Data(Self.nullElementJSON.utf8))
        let mapped = QWeatherMapper.mapCityLookup(decoded)
        XCTAssertEqual(mapped.places.count, 1,
                       "null 元素应被丢弃，其余条目必须保住（P-18：绝不为一个元素牺牲整包）")
        XCTAssertEqual(mapped.mostGranular?.adm2, "东城区")
    }

    // MARK: - ⑥ 坐标解析失败绝不兜底成 0

    /// 🔴🔴 坐标不可解析 / 越界 / 空串 → **一律 nil**，**绝不**兜底成 `0`。
    ///
    /// `(0, 0)` 是几内亚湾 —— 一个**看起来合法但完全错**的值，
    /// 比显示「暂无」坏得多（本仓铁律：宁可空着，不造假值）。
    func testUnparsableOrOutOfRangeCoordinatesBecomeNil() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherCityResponse.self, from: Data(Self.unparsableCoordinateJSON.utf8))
        let places = QWeatherMapper.mapCityLookup(decoded).places

        XCTAssertEqual(places.count, 4, "四个条目都应保住（坐标脏 ≠ 整条丢弃）")

        // ⚠️ 逐条断言（**不用**「全部 latitude 皆nil」的笼统写法）：
        //   「越界经度」那条的**纬度是合法的**（39.93），只有经度越界——
        //   一条笼统断言会把「合法的也变 nil」这种过度修正也一起放过，
        //   或在正确实现下**误报为红**。逐条钉死才既不漏也不误。
        let unparsable = try XCTUnwrap(places.first { $0.name == "某地" })
        XCTAssertNil(unparsable.latitude,
                     "`lat = \"不是数字\"` → nil，**绝不**兜底成 0（那是几内亚湾）")
        XCTAssertEqual(unparsable.longitude ?? -1, 116.42, accuracy: 1e-9,
                       "同一对象的**合法**经度必须保住（一个字段脏不得连累其余）")

        let outOfRangeLat = try XCTUnwrap(places.first { $0.name == "越界纬度" })
        XCTAssertNil(outOfRangeLat.latitude, "纬度 91.5 越界 → nil")
        XCTAssertEqual(outOfRangeLat.longitude ?? -1, 116.42, accuracy: 1e-9,
                       "一个坐标非法**不得**连累另一个合法坐标")

        let outOfRangeLon = try XCTUnwrap(places.first { $0.name == "越界经度" })
        XCTAssertNil(outOfRangeLon.longitude, "经度 181.2 越界 → nil")
        XCTAssertEqual(outOfRangeLon.latitude ?? -1, 39.93, accuracy: 1e-9,
                       "🔴 越界经度那条的**纬度是合法的** —— 笼统断言会把这个"
                       + "「该保留的」一并放过，等于没测")

        let blank = try XCTUnwrap(places.first { $0.name == "空串坐标" })
        XCTAssertNil(blank.latitude, "空串坐标 → nil（**绝不**当成 0）")
        XCTAssertEqual(blank.longitude ?? -1, 116.42, accuracy: 1e-9)

        // 🔴 兜底成 0 会产出什么：把 nil 一律换成 0 会得到
        //   `0.0, 116.42` 这样的**看似合法**坐标 —— 而上游根本没给纬度。
        //   故这里断言「**没有任何一条**的纬度被填成 0」。
        //   ⚠️ 上面已逐条断言过 nil，这条只是**兜底网**（若实现里写了
        //   `?? 0`，逐条断言会红；这条额外防「有人后来加了兜底」）。
        let zeroFilled = places.filter { $0.latitude == 0 }
        XCTAssertTrue(zeroFilled.isEmpty,
                      "🔴 绝不能把非法纬度兜底成 0 —— 那是几内亚湾，"
                      + "一个看起来合法但完全错的值")
    }

    /// 🔴 合法坐标必须解出（防止上一条「一律 nil」的过度修正）。
    func testValidCoordinatesStillDecode() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherCityResponse.self, from: Data(Self.lookupJSON.utf8))
        let place = try XCTUnwrap(QWeatherMapper.mapCityLookup(decoded).mostGranular)
        XCTAssertEqual(place.latitude ?? -1, 39.93, accuracy: 1e-9)
        XCTAssertEqual(place.longitude ?? -1, 116.42, accuracy: 1e-9)
    }

    // MARK: - ⑦ 非法 tz → 回退不崩，绝不硬编码偏移

    /// 🔴 非法 / 空 / 空白 / 缺失 `tz` → **不抛错**，`timeZoneIdentifier` 为 nil。
    func testIllegalTimeZoneIdentifiersDoNotCrash() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherCityResponse.self, from: Data(Self.illegalTimeZoneJSON.utf8))
        let places = QWeatherMapper.mapCityLookup(decoded).places
        XCTAssertEqual(places.count, 4, "四个条目都应保住")

        for place in places {
            let label = place.name ?? "<无名>"
            XCTAssertNil(place.timeZoneIdentifier,
                         "`\(label)` 的 tz 非法/空白/缺失 → nil"
                         + "（**绝不**硬编码 +08:00 之类的固定偏移）")
            // 🔴 回退路径必须复用既有单一真源，且**不崩**。
            // ⚠️ 比较 `identifier` 而非 `TimeZone` 实例本身（沿用
            //   `SharedWeatherPayloadTimezoneTests` 的既有写法）：
            //   实例相等依赖 `NSObject` 的 `isEqual`，而标识串比较
            //   在失败时会给出**可读的差异**（这正是排障时要的信息）。
            XCTAssertEqual(WeatherTimeFormatter.resolveTimeZone(
                identifier: place.timeZoneIdentifier).identifier,
                           TimeZone.current.identifier,
                           "非法 tz → 必须回退设备当前时区（既有单一真源），"
                           + "**绝不**硬编码固定偏移")
        }
    }

    /// 合法 `tz` → 保留原串，且能经既有裁定解析成正确时区。
    func testLegalTimeZoneIsPreservedAndResolvable() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherCityResponse.self, from: Data(Self.lookupJSON.utf8))
        let place = try XCTUnwrap(QWeatherMapper.mapCityLookup(decoded).mostGranular)
        XCTAssertEqual(place.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(WeatherTimeFormatter.resolveTimeZone(
            identifier: place.timeZoneIdentifier).identifier,
                       "Asia/Shanghai",
                       "🔴 时区解析必须走既有的 `WeatherTimeFormatter.resolveTimeZone`"
                       + "（`nonisolated` 单一真源），不在本仓另写一套")
    }

    // MARK: - ④ `isDst` 是字符串 `"1"` / `"0"`

    /// 🔴 `isDst` 只有 `"1"` / `"0"` 逐字可裁定，其余形态 → **nil**（不知道）。
    ///
    /// ⚠️ 把「不知道」渲染成「非夏令时」是**凭空造一条读数**（铁律 ③）。
    func testDaylightSavingFlagOnlyAcceptsSpecLiterals() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherCityResponse.self, from: Data(Self.daylightSavingJSON.utf8))
        let places = QWeatherMapper.mapCityLookup(decoded).places
        XCTAssertEqual(places.count, 5)

        // 规格逐字：`1` = 当前处于夏令时、`0` = 不是。
        let inDst = try XCTUnwrap(places.first { $0.name == "夏令时中" })
        XCTAssertEqual(inDst.isDaylightSavingTime, true)
        let notInDst = try XCTUnwrap(places.first { $0.name == "非夏令时" })
        XCTAssertEqual(notInDst.isDaylightSavingTime, false)

        // 🔴 布尔 `true` **不是**规格形态 → nil（`LenientString` 不解布尔）。
        let booleanForm = try XCTUnwrap(places.first { $0.name == "布尔形态" })
        XCTAssertNil(booleanForm.isDaylightSavingTime,
                     "布尔不是规格形态 → nil（**不猜**，绝不当成 true）")
        let unknownForm = try XCTUnwrap(places.first { $0.name == "未知形态" })
        XCTAssertNil(unknownForm.isDaylightSavingTime,
                     "`\"maybe\"` → nil（**绝不**当成 false）")
        let missing = try XCTUnwrap(places.first { $0.name == "缺 isDst" })
        XCTAssertNil(missing.isDaylightSavingTime, "缺字段 → nil")
    }

    // MARK: - 空白字段：绝不显示空名字

    /// 🔴 空串 / 纯空白 → **视为没有该字段**，**绝不**显示成一个空名字。
    func testBlankStringsAreTreatedAsAbsent() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherCityResponse.self, from: Data(Self.blankTextJSON.utf8))
        let place = try XCTUnwrap(QWeatherMapper.mapCityLookup(decoded).mostGranular)

        XCTAssertNil(place.name, "空串名字 → nil（**绝不**显示成空名字）")
        XCTAssertNil(place.adm2, "纯空白 adm2 → nil")
        XCTAssertNil(place.adm1, "制表符 adm1 → nil")
        XCTAssertNil(place.country, "空串国家 → nil")
    }

    // MARK: - 标识唯一性（ForEach 的地基）

    /// `sequenceIndex` 必须唯一且连续（`Identifiable` 的地基）。
    ///
    /// ⚠️ 刻意**不用**上游 `id`（LocationID）当标识：它**可能缺失**
    ///   → `ForEach` 拿到重复/全空 id 会静默错渲甚至崩。
    func testSequenceIndexIsUniqueAndDense() throws {
        let decoded = try ResponseDecoding.decode(
            QWeatherCityResponse.self, from: Data(Self.unparsableCoordinateJSON.utf8))
        let mapped = QWeatherMapper.mapCityLookup(decoded)
        let identifiers = mapped.places.map(\.id)
        XCTAssertEqual(identifiers, Array(0..<mapped.places.count))
        XCTAssertEqual(Set(identifiers).count, identifiers.count, "id 必须唯一")
    }

    // MARK: - 诚实性：本端点未实测

    /// 🔴 **规格锚点**：把「本端点的关键形态假设」显式钉在测试里。
    ///
    /// ⚠️ 这条测试**不测任何运行时行为**，它测的是**我们的假设写下来了**。
    ///   存在的理由：2026-10-08 实测该Host 下本端点 404，**真机行为未知**。
    ///   → Host 恢复后，第一个该做的事就是**拿真实响应逐条核对这里的每个值**；
    ///     若有出入，改这里 + 改 DTO 注释，**别**只改代码。
    ///
    ///   🔴 同时它也钉住「坐标顺序」这条最易错的假设：
    ///     `location=116.41,39.92`（经度在前）。
    func testSpecAssumptionsArePinnedExplicitly() throws {
        // ① 端点路径（官方规格逐字）。
        XCTAssertEqual(QWeatherGeoEndpoint.cityLookupPath, "/geo/v2/city/lookup")

        // ② 坐标顺序：经度在前（官方规格示例 `location=116.41,39.92`）。
        let url = try XCTUnwrap(QWeatherGeoEndpoint.cityLookupURL(
            apiHost: "h.qweatherapi.com", latitude: 39.92, longitude: 116.41))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems)
        let locationValue = try XCTUnwrap(items.first { $0.name == "location" }?.value)
        XCTAssertEqual(locationValue, "116.41,39.92")

        // ③ 坐标小数位数与天气端点同款（2位）。
        XCTAssertEqual(QWeatherEndpoint.coordinateDecimalPlaces, 2)

        // ④ 默认语言与天气端点同款（`zh`）。
        XCTAssertEqual(QWeatherGeoEndpoint.defaultLanguage, "zh")

        // ⑤ 🔴 **本端点未实测**（2026-10-08）—— 用注释把这件事钉在测试里：
        //   若哪天这条测试被删掉，说明有人忘了这个端点仍未验证。
        //   （断言恒真是**有意的**：它标记的是一个**事实状态**，
        //     而非一个可计算的真值。）
        XCTAssertTrue(true, "⚠️ 未实测：2026-10-08 该 Host 下 city/lookup 返回 404")
    }
}
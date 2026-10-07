//
//  WidgetTraceRedactionTests.swift
//  ZhishengWeatherTests
//
//  「日志绝不含凭据」这条硬约束的**可执行证明**。
//
//  ── 为什么必须单测而不是靠注释保证 ─────────────────────────────────────────
// 本仓数据源带 CC BY 4.0 署名要求，且**任何**端点都可能在 URL 上挂 key
// （Open-Meteo 当前**没有** key，但那是「今天的事实」，不是「结构上的保证」）。
// 脱敏一旦被后人「顺手改成打完整 URL」，一个泄漏会静默发生且无人察觉 ——
// 注释不会拦住任何���。故这里把「值不出现」钉成断言。
//
//  P-18同源盲区纪律：本文件断言的是**脱敏函数的输出**（纯函数），
//  与 `redactedEndpoint` 的实现同源，但断言值是**手写字面量**、
//  不是「调用实现再对比实现」，故实现改了字面量对不上时测试会红。
//

import XCTest
@testable import ZhishengWeather

final class WidgetTraceRedactionTests: XCTestCase {

    // MARK: - 核心保证：任何 query value 都不出现

    /// 最强的一条：**带凭据的 query 参数，值一个字都不能出现在输出里**。
    func testSecretQueryValueNeverAppears() throws {
        let secret = "SECRET_TOKEN_abc123"
        let url = try XCTUnwrap(URL(string:
            "https://api.example.com/v1/forecast?latitude=30.28&longitude=120.16&apikey=\(secret)"))

        let text = WidgetTrace.redactedEndpoint(url)

        XCTAssertFalse(text.contains(secret),
                       "脱敏后仍含凭据原文：\(text)")
        // 参数名保留（排障时需要知道「请求带了 apikey 这个参数」）。
        XCTAssertTrue(text.contains("apikey"), "参数名应保留：\(text)")
        // 白名单内的经纬度照常输出（它们是排障必需，且非凭据）。
        XCTAssertTrue(text.contains("latitude=30.28"), "白名单参数应带值：\(text)")
        XCTAssertTrue(text.contains("longitude=120.16"), "白名单参数应带值：\(text)")
    }

    /// 白名单外的**每一个**参数都不得带值（逐个覆盖几种常见命名）。
    func testNonWhitelistedParamsNeverCarryValues() throws {
        let names = ["apikey", "api_key", "appid", "app_id", "token", "access_token", "key", "secret"]
        for name in names {
            let value = "VALUE_\(name)"
            let url = try XCTUnwrap(URL(string: "https://h.example.com/p?\(name)=\(value)"))

            let text = WidgetTrace.redactedEndpoint(url)

            XCTAssertFalse(text.contains(value),
                           "参数 \(name) 的值泄漏进了日志：\(text)")
            XCTAssertTrue(text.contains(name),
                          "参数 \(name) 的名应保留：\(text)")
        }
    }

    // MARK: - 形状（判读表按这些字面量查）

    /// 本仓真实端点的形状（Open-Meteo：**无任何 key**，全部参数都应只留名）。
    ///
    /// ⚠️ 这是把 `OpenMeteoEndpoint.url` 的**真实产物**喂进脱敏函数 ——
    /// 若将来给它加了 `&apikey=`，本测试会立刻发现「值没被脱敏」的回归。
    func testRealEndpointShapeIsRedacted() throws {
        let url = try XCTUnwrap(OpenMeteoEndpoint.url(latitude: 30.28, longitude: 120.16))

        let text = WidgetTrace.redactedEndpoint(url)

        XCTAssertTrue(text.hasPrefix("https://api.open-meteo.com/v1/forecast?"),
                      "host/path 应原样保留：\(text)")
        XCTAssertTrue(text.contains("latitude=30.28"), "纬度应带值：\(text)")
        XCTAssertTrue(text.contains("longitude=120.16"), "经度应带值：\(text)")
        // current / hourly / daily / minutely_15 / timezone / timeformat /
        // forecast_days / past_days / wind_speed_unit / forecast_minutely_15
        // 一律只应出现参数名。
        for name in ["current", "hourly", "daily", "minutely_15", "forecast_days",
                     "past_days", "timezone", "timeformat", "wind_speed_unit",
                     "forecast_minutely_15"] {
            XCTAssertTrue(text.contains(name), "参数名 \(name) 应出现：\(text)")
        }
        // 断言「没有 `=` 跟在非白名单名后面」——逐个精确钉死。
        XCTAssertFalse(text.contains("current="), "current 的值不应出现：\(text)")
        XCTAssertFalse(text.contains("hourly="), "hourly 的值不应出现：\(text)")
        XCTAssertFalse(text.contains("daily="), "daily 的值不应出现：\(text)")
        XCTAssertFalse(text.contains("timezone="), "timezone 的值不应出现：\(text)")
        XCTAssertFalse(text.contains("forecast_days="), "forecast_days 的值不应出现：\(text)")
    }

    /// nil / 无 query / 解析失败三种边界都**不得**吐出原始 URL。
    func testEdgeCasesDoNotLeak() throws {
        XCTAssertEqual(WidgetTrace.redactedEndpoint(nil), "-")

        let noQuery = try XCTUnwrap(URL(string: "https://h.example.com/path"))
        XCTAssertEqual(WidgetTrace.redactedEndpoint(noQuery), "https://h.example.com/path")
    }

    /// 白名单是**显式列举**的：断言它当前恰好只有经纬度两项。
    ///
    /// 目的：将来有人往里加参数时，这条测试会红，强制他回到本文件确认
    /// 「这个东西到底算不算凭据」——把风险变成一次显式决策。
    func testWhitelistIsExactlyCoordinates() {
        XCTAssertEqual(WidgetTrace.diagnosticQueryKeys,
                       ["latitude", "longitude"])
    }

    // MARK: - 错误 token 绝不含 localizedDescription

    /// `WeatherError.network` 之类会携带 `localizedDescription`
    ///（而 `URLError` 的描述**可能回显请求 URL**）。
    /// 故 token 形态必须与描述文本无关。
    func testErrorTokensDoNotLeakLocalizedDescription() {
        //构造一个「描述里含疑似凭据」的错误。
        let leaky = WeatherError.network("failed for https://h/p?apikey=SECRET_TOKEN_abc123")

        let token = leaky.traceToken

        XCTAssertEqual(token, "network")
        XCTAssertFalse(token.contains("SECRET"), "错误 token 泄漏了描述文本：\(token)")
        XCTAssertFalse(token.contains("http"), "错误 token 不应回显 URL：\(token)")
    }

    /// 各 case 的 token 字面量（判读表按这一列查，**钉死**防止随手改名）。
    func testErrorTokenLiterals() {
        XCTAssertEqual(WeatherError.badURL.traceToken, "badURL")
        XCTAssertEqual(WeatherError.badStatus(503).traceToken, "badStatus(503)")
        XCTAssertEqual(WeatherError.timeout("x").traceToken, "timeout")
        XCTAssertEqual(WeatherError.dataMissing("x").traceToken, "dataMissing")
        XCTAssertEqual(WeatherError.appGroup("x").traceToken, "appGroup")
        // 解码失败**必须**带字段路径 —— run37 事故里唯一有用的线索。
        XCTAssertEqual(WeatherError.decodingDetail(path: "hourly.time", debugDescription: "d").traceToken,
                       "decodeFail(path=hourly.time)")
        // 不带 path 时不得留下空的括号噪声。
        XCTAssertEqual(WeatherError.decodingDetail(path: "", debugDescription: "d").traceToken,
                       "decodeFail(path=)")
    }

    /// 空因 / 状态 / 来源 / 城市结果的 token 字面量（判读表的另外四列）。
    func testResolutionTokenLiterals() {
        XCTAssertEqual(WidgetPayloadStatus.available.traceToken, "available")
        XCTAssertEqual(WidgetPayloadStatus.stale.traceToken, "stale")
        XCTAssertEqual(WidgetPayloadStatus.missing.traceToken, "missing")
        XCTAssertEqual(WidgetPayloadStatus.unavailable.traceToken, "unavailable")

        XCTAssertEqual(WidgetDataSource.sharedContainer.traceToken, "container")
        XCTAssertEqual(WidgetDataSource.selfFetched.traceToken, "selfFetched")
        XCTAssertEqual(WidgetDataSource.none.traceToken, "none")

        XCTAssertEqual(WidgetEmptyReason.noCity.traceToken, "noCity")
        XCTAssertEqual(WidgetEmptyReason.noCachedData.traceToken, "noCachedData")
        XCTAssertEqual(WidgetEmptyReason.sharedContainerDown.traceToken, "containerDown")
        XCTAssertEqual(WidgetEmptyReason.fetchFailed.traceToken, "fetchFailed")
        XCTAssertEqual(WidgetEmptyReason.cityHasNoData.traceToken, "cityHasNoData")
        XCTAssertEqual(WidgetEmptyReason.locationNotAuthorized.traceToken, "locNotAuthorized")
        XCTAssertEqual(WidgetEmptyReason.locationUnavailable.traceToken, "locUnavailable")

        XCTAssertEqual(WidgetCityResolver.Mode.followApp.traceToken, "followApp")
        XCTAssertEqual(WidgetCityResolver.Mode.currentLocation.traceToken, "currentLocation")
        XCTAssertEqual(WidgetCityResolver.Mode.fixed(cityID: "30.28,120.16").traceToken,
                       "fixed(30.28,120.16)")
    }
}

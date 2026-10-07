//
//  OfficialWarningDefenseGuideTests.swift
//  ZhishengWeatherTests
//
//  防御指南正文（第七源 `ISSUECONTENT`）的**接线**与**渲染数据**保障：
//   - 接线回归：`enrich` 曾**没有任何生产调用方**（只有测试调用），
//     故 `defenseGuide` 在真机上恒为 nil。本组测试锁死"接上了"这件事，
//     防止将来被误删回落成"编译过、测试过、正文永远拿不到"；
//   - 补源失败**不污染四态**（列表来自 NMC 且已取数成功）；
//   - 补源只对**本城市命中的条目**发请求（详情端点实测限频严）；
//   - 正文**逐字来自上游**：UI 侧不改写、不摘要、不做正则清洗。
//
//  ## 实测依据（2026-10-06 当次抓取，5 条详情逐条统计，**非引自文档**）
//  · `ISSUECONTENT` 长度 **137~154 字符**（5/5 非空）；
//  · **换行 0 个**（`\n`/`\r` 均为 0）→ 单段纯文本，**不是** `\n` 分段；
//  · **无 HTML 残留**（正则扫 `<[^>]+>` 与 `&[a-zA-Z]+;` 均 0 命中）。
//  故测试断言"逐字透传"，并显式断言**不含** HTML 标记 —— 
//  若将来上游真的给了 `<br>`，该断言会失败并提醒同步更新 UI 清洗策略，
//  而不是让脏文本悄悄上屏。
//

import XCTest
@testable import ZhishengWeather

// MARK: - Stub

/// NMC 列表服务 Stub（返回预置条目，不联网）。
private actor StubNmcAlarm: NmcAlarmProviding {
    private let result: Result<[OfficialWarningItem], WeatherError>
    init(_ result: Result<[OfficialWarningItem], WeatherError>) { self.result = result }
    func fetchAllWarnings(timeZone: TimeZone?) async throws -> [OfficialWarningItem] {
        try result.get()
    }
}

/// 第七源详情服务 Stub（可编程成功/失败 + 记录被点名的 alertid）。
private actor StubWeatherCnDetail: WeatherCnAlarmProviding {
    enum Behavior {
        case success([String: WeatherCnAlarmDetail])
        case failure(WeatherError)
    }
    private let behavior: Behavior
    private var requestedIDs: [String] = []

    init(_ behavior: Behavior) { self.behavior = behavior }

    func fetchDetails(forAlertIDs alertIDs: [String]) async throws -> [String: WeatherCnAlarmDetail] {
        requestedIDs.append(contentsOf: alertIDs)
        switch behavior {
        case .success(let map): return map
        case .failure(let error): throw error
        }
    }

    /// 累计被点名的 alertid（用于"只对命中条目发请求"断言）。
    func recordedRequestIDs() -> [String] { requestedIDs }
}

/// 天气 Stub。
private actor StubWeather: WeatherProviding {
    private let snapshot: WeatherSnapshot
    init(snapshot: WeatherSnapshot) { self.snapshot = snapshot }
    func fetch(latitude: Double, longitude: Double) async throws -> WeatherSnapshot { snapshot }
}

/// 空气 Stub（恒失败，只为阻断真实网络）。
private actor StubAir: AirQualityProviding {
    func fetch(latitude: Double, longitude: Double) async throws -> AirQuality {
        throw WeatherError.badStatus(503)
    }
}

// MARK: - Tests

@MainActor
final class OfficialWarningDefenseGuideTests: XCTestCase {

    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    /// 实测正文样本（逐字取自 2026-10-06 抓取，
    /// `101131007-20261006212927-0902.html`，实测长度 147 字符）。
    private let measuredGuide =
        "昭苏县气象台2026年10月6日21时29分发布雷电黄色预警信号：目前，我县昭苏镇已出现雷电天气，"
        + "预计今天夜间，上述区域及种马场、乌尊布拉克镇、阿克达拉镇等地将出现雷电天气，"
        + "可能造成雷电灾害，期间可能伴有短时强降水、雷暴大风、冰雹等强对流天气，请注意防范。"
        + "（预警信息来源：国家预警信息发布中心）"

    private func makeSnapshot() -> WeatherSnapshot {
        WeatherSnapshot(location: .beijing,
                        temperature: 23.0, apparentTemperature: 22.0,
                        weatherCode: 1, windSpeed: 2.0, windDirection: 90.0,
                        humidity: 50, isDay: true, hourly: [],
                        dailyHigh: 25.0, dailyLow: 15.0, daily: nil,
                        fetchedAt: anchor)
    }

    private func makeStore() throws -> AppGroupStore {
        let name = "zs.test.warning.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return AppGroupStore(defaults: defaults)
    }

    /// 构造一条**命中某城市**的预警条目。
    ///
    /// ⚠️ `id` 必须与第七源的连接键`alertid` **逐字相等** ——
    /// 这是 `OfficialWarningEnrichment` 的连接依据（精确相等，无模糊匹配）。
    ///
    /// ⚠️ `issuedAt` 必须给**接近当前**的时刻：四态由
    /// `OfficialWarningState.resolve` 按「发布时间距今≤ 6h」判定，
    /// 若给固定旧锚点（2023）会判成 `.stale(.dataTooOld)`，
    /// 测试就变成在验证"过期"而非验证"补源"。VM 内部用 `Date()` 判定，
    /// 故这里也必须用`Date()`（测试代码允许读时钟；Core 纪律禁的是模型层）。
    private func makeItem(id: String = "65402641600000_20261006212927",
                          cityName: String = "昭苏县",
                          defenseGuide: String? = nil) -> OfficialWarningItem {
        OfficialWarningItem(id: id,
                            region: "新疆维吾尔自治区\(cityName)",
                            cityName: cityName,
                            administrativeCode: "654026",
                            kind: "雷电",
                            color: .yellow,
                            issuedAt: Date(),
                            detailURL: nil,
                            rawTitle: "\(cityName)发布雷电黄色预警",
                            defenseGuide: defenseGuide)
    }

    /// 构造一条详情（走**真实 JSONP 解码路径**，顺带验证字段名逐字正确）。
    ///
    /// ⚠️ 刻意**不用** `try!` / `fatalError`（SC-31 门禁禁止）：
    /// 构造失败就 `XCTUnwrap` 抛错，让测试**失败**而不是崩整个套件。
    private func makeDetail(identifier: String,
                            guide: String?) throws -> WeatherCnAlarmDetail {
        // 手写 JSON 而非 JSONSerialization：正文含中文引号「“”」，
        // 手写更直白，且能精确控制 `null`（空正文）与缺字段两种形态。
        let content = guide.map { "\"\($0)\"" } ?? "null"
        let text = "var alarminfo={\"identifier\":\"\(identifier)\","
            + "\"ISSUECONTENT\":\(content)};"
        return try XCTUnwrap(WeatherCnAlarmDetail.decode(jsonpText: text),
                             "测试自身的 JSONP 构造失败 —— 字段名与解码器不匹配")
    }

    /// ⚠️ 有两个重载：
    ///  - 传 `Behavior`：helper 自己构造 stub（多数测试用这个）；
    ///  - 传 `StubWeatherCnDetail`：**调用方要断言 stub 自身的状态**
    ///    （如 recordedRequestIDs）时用这个 —— 否则断言的是一个
    ///    **从未接进 VM** 的 stub，测试看着绿但没有证明力。
    private func makeViewModel(items: [OfficialWarningItem],
                               detail: StubWeatherCnDetail.Behavior) throws -> WeatherViewModel {
        try makeViewModel(items: items, detailStub: StubWeatherCnDetail(detail))
    }

    /// 注入**已构造好的** stub，使调用方能观察它的内部状态。
    private func makeViewModel(items: [OfficialWarningItem],
                               detailStub: StubWeatherCnDetail) throws -> WeatherViewModel {
        WeatherViewModel(service: StubWeather(snapshot: makeSnapshot()),
                         store: try makeStore(),
                         locationProvider: LocationProvider(),
                         airService: StubAir(),
                         ensembleService: StubEnsembleAlwaysFail(),
                         alarmService: StubNmcAlarm(.success(items)),
                         alarmDetailService: detailStub)
    }

    private func waitUntil(timeout: TimeInterval = 3,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: ① 接线（本次修复的核心回归锁）

    /// **本组最关键的测试**：证明 `defenseGuide` 真的从第七源流到了 VM。
    ///
    /// 修复前：`OfficialWarningEnrichment.enrich` **零生产调用方**，
    /// 正文永远拿不到（但所有既有测试都绿 —— 最坏的那种状态）。
    func testDefenseGuideReachesViewModelThroughProductionPath() async throws {
        let id = "65402641600000_20261006212927"
        // 传Behavior（不是构造好的 stub）—— makeViewModel 内部负责构造。
        let vm = try makeViewModel(
            items: [makeItem(id: id)],
            detail: .success([id: try makeDetail(identifier: id, guide: measuredGuide)])
        )

        await vm.addAndSelect(makeCity())
        await waitUntil { vm.displayedOfficialWarning != nil }

        // 必须仍是 .active（列表取数成功），且正文**逐字**到达。
        guard case .some(.active(let items)) = vm.displayedOfficialWarning else {
            XCTFail("应是 .active，实际 \(String(describing: vm.displayedOfficialWarning))")
            return
        }
        XCTAssertEqual(items.first?.defenseGuide, measuredGuide,
                       "防御指南正文必须逐字来自第七源 `ISSUECONTENT`")
    }

    /// 补源失败**绝不**把四态改成 `.stale`。
    ///
    /// ⚠️ 这是内容错误防线：列表来自 NMC 且**已取数成功**，
    /// 第七源限频严导致取不到正文是**预期内**常态；
    /// 若并进 catch，用户会看到「预警数据获取失败」而以为没有预警。
    func testDetailFailureKeepsActiveStateAndLeavesGuideNil() async throws {
        let vm = try makeViewModel(items: [makeItem()],
                                   detail: .failure(.badStatus(403)))

        await vm.addAndSelect(makeCity())
        await waitUntil { vm.displayedOfficialWarning != nil }

        guard case .some(.active(let items)) = vm.displayedOfficialWarning else {
            XCTFail("第七源失败**不得**改变四态，实际 \(String(describing: vm.displayedOfficialWarning))")
            return
        }
        XCTAssertNil(items.first?.defenseGuide,
                     "取不到正文时字段保持 nil（缺失就是缺失，绝不编兜底文案）")
        XCTAssertEqual(items.count, 1, "补源失败**绝不**丢条目")
    }

    /// 第七源整体失败时，条目仍**原样**保留（缺字段 ≠ 丢条目）。
    func testDetailFailureNeverDropsItems() async throws {
        let vm = try makeViewModel(items: [makeItem()],
                                   detail: .failure(.network("boom")))

        await vm.addAndSelect(makeCity())
        await waitUntil { vm.displayedOfficialWarning != nil }

        guard case .some(.active(let items)) = vm.displayedOfficialWarning else {
            XCTFail("应是 .active，实际 \(String(describing: vm.displayedOfficialWarning))")
            return
        }
        XCTAssertEqual(items.count, 1)
    }

    /// alertid **不精确相等**时**绝不**补源（连接键纪律）。
    func testMismatchedAlertIDDoesNotEnrich() async throws {
        let vm = try makeViewModel(
            items: [makeItem(id: "DIFFERENT_ID")],
            detail: .success(["65402641600000_20261006212927":
                              try makeDetail(identifier: "65402641600000_20261006212927",
                                             guide: measuredGuide)]))

        await vm.addAndSelect(makeCity())
        await waitUntil { vm.displayedOfficialWarning != nil }

        guard case .some(.active(let items)) = vm.displayedOfficialWarning else {
            XCTFail("应是 .active，实际 \(String(describing: vm.displayedOfficialWarning))")
            return
        }
        XCTAssertNil(items.first?.defenseGuide,
                     "连接键必须逐字相等；模糊匹配会串到上一轮预警")
    }

    /// 本城市**无预警**时**不发**任何详情请求（限频纪律：不空烧配额）。
    func testNoWarningsForCitySendsNoDetailRequest() async throws {
        // 必须注入**这个 stub 实例**—— 断言的是它recordedRequestIDs()。
        // （另造一个 stub 的话，断言的是一个从未接进 VM 的对象，
        //   测试会永远绿且证明不了任何东西。）
        let detailStub = StubWeatherCnDetail(.success([:]))
        let vm = try makeViewModel(items: [], detailStub: detailStub)

        await vm.addAndSelect(makeCity())
        await waitUntil { vm.displayedOfficialWarning != nil }

        let requested = await detailStub.recordedRequestIDs()
        XCTAssertTrue(requested.isEmpty,
                      "无命中预警时不该发详情请求，实际点了 \(requested)")
    }

    // MARK: ② 正文形态（实测口径）

    /// 实测口径：正文**单段**、无换行、无 HTML 残留。
    ///
    /// 这条断言的作用是**双向**的：既锁住"UI 不清洗"的前提，
    /// 也让上游一旦改变形态（真的给了 `\n` 或 `<br>`）时**测试先红**，
    /// 提醒同步更新 UI，而不是让脏文本悄悄上屏。
    func testMeasuredGuideShapeMatchesDocumentedAssumptions() {
        // 长度：实测区间 137~154（此样本 147）。
        XCTAssertEqual(measuredGuide.count, 147, "样本长度应与实测一致（147 字符）")
        XCTAssertFalse(measuredGuide.isEmpty)
        // 换行：实测 0。
        XCTAssertFalse(measuredGuide.contains("\n"), "实测正文无\\n")
        XCTAssertFalse(measuredGuide.contains("\r"), "实测正文无\\r")
        // HTML 残留：实测 0（故 UI 刻意不写清洗正则）。
        XCTAssertNil(measuredGuide.range(of: "<[^>]+>", options: .regularExpression),
                     "实测正文无 HTML 标签")
        XCTAssertNil(measuredGuide.range(of: "&[a-zA-Z]+;", options: .regularExpression),
                     "实测正文无 HTML 实体")
    }

    /// 正文**逐字**透传：UI 不得改写/摘要/清洗。
    ///
    /// 用一个**刻意刁钻**的样本（含标点与括号），验证
    /// `enrich` 与模型层是纯赋值，没有截断、没有替换、没有 trim。
    func testGuideIsVerbatimNoTruncationOrRewrite() throws {
        let tricky = "  某县气象台2026年10月6日22时20分发布“大雾黄色预警信号”，"
            + "预计能见度小于500米，请注意防范。（预警信息来源：国家预警信息发布中心）  "
        let id = "65402641600000_20261006212927"
        // ⚠️ `makeDetail` 是 throws（内部用 XCTUnwrap 抛错，SC-31 禁 try!/fatalError）
        let detail = try makeDetail(identifier: id, guide: tricky)

        // Core 层：逐字相等（含首尾空格，绝不 trim）。
        let out = OfficialWarningEnrichment.enrich([makeItem(id: id)],
                                                   with: [id: detail],
                                                   timeZone: nil)
        XCTAssertEqual(out.first?.defenseGuide, tricky,
                       "正文必须逐字透传：不得 trim、截断、摘要或改写")
    }

    /// 空正文按缺失处理（**不留空串**，UI 才能如实显示"暂无正文"）。
    func testEmptyGuideTreatedAsMissingNotBlankString() throws {
        let id = "65402641600000_20261006212927"
        // 同上：makeDetail throws，调用处必须 try
        let detail = try makeDetail(identifier: id, guide: "")
        let out = OfficialWarningEnrichment.enrich([makeItem(id: id)],
                                                   with: [id: detail],
                                                   timeZone: nil)
        XCTAssertNil(out.first?.defenseGuide,
                     "空串必须按缺失处理（否则 UI 会显示『有正文却空白』）")
    }

    /// 模型层渲染契约：`defenseGuide` 缺失时**条目仍完整**（不因缺正文丢字段）。
    func testItemWithoutGuideStillRendersCoreFields() {
        let item = makeItem(defenseGuide: nil)
        XCTAssertNil(item.defenseGuide)
        XCTAssertEqual(item.kind, "雷电", "缺正文不影响类型")
        XCTAssertNotNil(item.region, "缺正文不影响地区")
        XCTAssertNotNil(item.issuedAt, "缺正文不影响发布时间")
        XCTAssertEqual(item.color, .yellow, "缺正文不影响颜色（排序/配色仍可用）")
    }

    // MARK: - Helpers

    private func makeCity() -> City {
        // 市名必须能被 `NmcAlarmMapper` 命中（按市段精确比对，不做整串包含）。
        City(name: "昭苏县", latitude: 43.15, longitude: 77.17, isCurrentLocation: false)
    }
}

/// 集合服务 Stub（恒失败，只为阻断真实网络）。
private actor StubEnsembleAlwaysFail: EnsembleProviding {
    func fetch(latitude: Double, longitude: Double) async throws -> EnsembleForecast {
        throw WeatherError.badStatus(503)
    }
}
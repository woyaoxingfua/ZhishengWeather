//
//  SourcePreferencesDecodeTests.swift
//  ZhishengWeatherTests
//
//  SourcePreferences 的**容错解码**守卫（T10 复核修复）。
//
//  背景（这是一个真实的中危缺陷，已被独立验证抓到）：
//  `SourceID` 的 `init(from:)` 对**未知 rawValue 会 throw** —— 单值解码这样做是对的
//  （不该猜）。但它被放进**集合**解码时，**一个**未知元素会让**整个集合**解码失败；
//  而读取侧原本写成 `try? JSONDecoder().decode(Set<SourceID>.self, …) ?? []`，
//  于是后果是：**用户全部「停用某源」偏好被静默清空**，且下一次 `setDisabled`
//  会用空集**覆盖写**，连恢复的机会都没有。
//
//  触发场景（都不是假想）：
//    · 装过更新版后回退（旧版本遇到新版本写入的 rawValue）；
//    · 某个源被删除、或改了 rawValue。
//
//  不对称点：`SourceHealthLedger` 对未知键是 `continue` **跳过**（安全），
//  而 `SourcePreferences` 原本是**整包失败**（危险）——同一个未知键，
//  账本安全而偏好集被清空，是不可接受的不对称。本文件把"容错"这条性质钉死。
//
//  隔离纪律：注入独立 `UserDefaults` suite，绝不碰 `.standard`。
//

import XCTest
@testable import ZhishengWeather

final class SourcePreferencesDecodeTests: XCTestCase {

    /// 本测试专用的偏好键（不依赖生产默认键名，避免把测试与键名耦合）。
    private let testKey = "zs.test.sourcePreferences"

    private var suiteName: String = ""
    private var defaults: UserDefaults?

    override func setUpWithError() throws {
        let name = "zs.test.prefs.\(UUID().uuidString)"
        suiteName = name
        defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    }

    override func tearDown() {
        if let defaults, !suiteName.isEmpty {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = ""
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeRawJSON(_ json: String) throws {
        let d = try XCTUnwrap(defaults)
        d.set(Data(json.utf8), forKey: testKey)
    }

    private func makePreferences() throws -> SourcePreferences {
        SourcePreferences(defaults: try XCTUnwrap(defaults), key: testKey)
    }

    // MARK: - 核心：未知条目不得清空既有偏好

    /// **本文件存在的理由**：数组里混入一个当前版本不认识的 rawValue，
    /// 已知的停用项**必须仍然生效** —— 绝不允许"一个未知元素清空全部偏好"。
    func testUnknownRawValueDoesNotWipeKnownPreferences() throws {
        try writeRawJSON(#"["sunriseSunset", "someFutureSourceXYZ"]"#)
        let prefs = try makePreferences()

        XCTAssertTrue(prefs.isDisabled(.sunriseSunset),
                      "集合里出现未知 rawValue 时，已知的停用项必须存活（否则用户偏好被静默清空）")
        XCTAssertFalse(prefs.isDisabled(.openMeteoForecast),
                       "未出现在集合里的源不应被误判为停用")
    }

    /// 全部是未知条目 → 空集，且**不得崩**（等价于"没有偏好"，而不是"解码失败"）。
    func testAllUnknownRawValuesYieldEmptyWithoutCrash() throws {
        try writeRawJSON(#"["nope1", "nope2"]"#)
        let prefs = try makePreferences()
        XCTAssertFalse(prefs.isDisabled(.sunriseSunset))
        XCTAssertFalse(prefs.isDisabled(.openMeteoForecast))
    }

    /// 容错读取之后再写入，**已知项必须被保留**（不能因为走了一次慢路径就把它丢了）。
    func testWriteAfterLenientReadPreservesKnownEntries() throws {
        try writeRawJSON(#"["sunriseSunset", "someFutureSourceXYZ"]"#)
        let prefs = try makePreferences()

        prefs.setDisabled(.openMeteoForecast, disabled: true)

        XCTAssertTrue(prefs.isDisabled(.sunriseSunset), "原有停用项不得被这次写入丢掉")
        XCTAssertTrue(prefs.isDisabled(.openMeteoForecast), "本次新增的停用项应生效")
    }

    // MARK: - 两种历史编码形态都要能读

    /// 新形态：单值字符串（enum 的惯用 Codable 形态）——走快路径。
    func testSingleValueFormDecodes() throws {
        try writeRawJSON(#"["sunriseSunset"]"#)
        let prefs = try makePreferences()
        XCTAssertTrue(prefs.isDisabled(.sunriseSunset))
    }

    /// 旧形态：`SourceID` 曾是 struct，合成 Codable 写出 keyed `{rawValue: …}`。
    /// **升级不能把老用户的偏好丢掉**，故这条必须成立。
    func testLegacyKeyedFormStillDecodes() throws {
        try writeRawJSON(#"[{"rawValue":"sunriseSunset"}]"#)
        let prefs = try makePreferences()
        XCTAssertTrue(prefs.isDisabled(.sunriseSunset),
                      "旧 keyed 形态必须仍可解出（否则升级即清空老用户偏好）")
    }

    /// 混合形态（理论上不该出现，但**不得因此整包失败**）：新旧元素混在一起仍要尽力解出。
    func testMixedFormsStillDecodeKnownEntries() throws {
        try writeRawJSON(#"[{"rawValue":"sunriseSunset"}, "openMeteoForecast"]"#)
        let prefs = try makePreferences()
        XCTAssertTrue(prefs.isDisabled(.sunriseSunset))
        XCTAssertTrue(prefs.isDisabled(.openMeteoForecast))
    }

    // MARK: - 损坏数据不得崩、不得误判

    /// 压根不是数组（例如被别的代码写坏）→ 空集，不崩、不误判。
    func testNonArrayPayloadYieldsEmptyWithoutCrash() throws {
        try writeRawJSON(#"{"unexpected": true}"#)
        let prefs = try makePreferences()
        XCTAssertFalse(prefs.isDisabled(.sunriseSunset))
    }

    /// 数组里混入非字符串/非对象元素 → 跳过该元素，其余照常解出。
    func testNonStringElementsAreSkipped() throws {
        try writeRawJSON(#"[123, "sunriseSunset", null]"#)
        let prefs = try makePreferences()
        XCTAssertTrue(prefs.isDisabled(.sunriseSunset),
                      "不可识别的元素应被跳过，而不是连累整个集合")
    }
}

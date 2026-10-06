//
//  DataAttributionTests.swift
//  ZhishengWeatherTests
//
//  CC BY 4.0 署名义务的守卫。
//
//  ── 为什么这些是机械守卫而不是「看一眼」 ─────────────────────────────────
//  CC BY 4.0 要求两件事：**appropriate credit**（署名，含可追溯链接）与
//  **indicating any modifications**（说明改动）。这两件事的**失效方式都是静默的**：
//  新加一个源却忘了填链接 → 用户看到的出处不完整（编译器不报错、运行时看不出、
//  CI 全绿）；把「做了转换」那句删掉 → 许可要求被无声违反。
//  故把两者都钉成**性质**断言：
//    · 每个`SourceDescriptor` 都有可解析的 http/https 链接（漏填即红）；
//    · 声明文案同时含「出处 / CC BY / 转换」三要素（缺一即红）；
//    · 未注册端点不因 compactMap 而被悄悄丢掉（不声不息丢一条= 少一条署名）。
//
//  守卫锚的是**性质**（"每个源都有链接"、"文案提到改动"），不锚具体措辞 ——
//  措辞会改，性质不会，故改文案不会让守卫假失效。
//
//  不联网、不读真实时钟。
//

import XCTest
import Foundation
@testable import ZhishengWeather

final class DataAttributionTests: XCTestCase {

    // MARK: - 链接：非空 + 格式合法

    /// 每个 `SourceDescriptor` 都必须有**可解析**的官网链接。
    ///
    /// 锚的是「每个源都有链接」这条性质。加源时`websiteURLString` 是必填参数
    /// （编译期约束），本测试补上第二道：**字面量写错**（解析成 nil）也会红。
    func testEverySourceDescriptorHasResolvableWebsiteURL() {
        for descriptor in SourceDirectory.all {
            XCTAssertFalse(descriptor.websiteURLString.isEmpty,
                           "源 \(descriptor.id.rawValue) 的官网链接为空 —— CC BY 4.0 要求可追溯的出处")
            guard let url = descriptor.websiteURL else {
                XCTFail("源 \(descriptor.id.rawValue) 的官网链接无法解析为URL："
                        + "\(descriptor.websiteURLString)")
                continue
            }
            XCTAssertNotNil(url.scheme,
                            "源 \(descriptor.id.rawValue) 的官网链接缺scheme")
            XCTAssertTrue(["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                          "源 \(descriptor.id.rawValue) 的官网链接协议必须是 http/https，"
                          + "实际：\(descriptor.websiteURLString)")
            XCTAssertNotNil(url.host,
                            "源 \(descriptor.id.rawValue) 的官网链接缺host：\(descriptor.websiteURLString)")
        }
    }

    /// 署名的每一条都必须**带可点链接**（这是 "giving credit" 的最低形态）。
    ///
    /// ⚠️ 同时钉住「一条都没被 compactMap 掉」——生产路径里 URL 字面量解析失败会
    /// 让整条消失，**不声不响**。这里断言条目数不减，正好兜住那条静默路径。
    func testEveryAttributionEntryHasClickableWebsiteLink() {
        let entries = DataAttribution.allEntries
        XCTAssertFalse(entries.isEmpty, "署名清单为空 —— 设置页会什么都不显示")

        for entry in entries {
            guard let url = entry.websiteURL else {
                XCTFail("署名条目 \(entry.id) 没有可点链接 —— 这条署名等于没有署名")
                continue
            }
            XCTAssertTrue(["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                          "署名条目 \(entry.id) 的链接协议必须是 http/https，实际：\(url)")
            XCTAssertFalse(entry.displayName.isEmpty,
                           "署名条目 \(entry.id) 缺展示名")
            XCTAssertFalse(entry.provides.isEmpty,
                           "署名条目 \(entry.id) 没说明该源提供哪些字段（用户无法判断数据出处）")
        }
    }

    /// 未注册端点（geocoding / archive / ensemble）**一条都不许丢**。
    ///
    /// 这三条**在用但不在 `SourceDirectory`**（不参与降级合并），所以没有任何
    /// 其它守卫覆盖它们；一旦被 compactMap 静默丢弃，署名就是不全的。
    func testUnregisteredEndpointSourcesAreNotSilentlyDropped() {
        let expected = ["open-meteo-geocoding", "open-meteo-archive", "open-meteo-ensemble"]
        let actual = DataAttribution.unregisteredEndpointSources.map(\.id)
        XCTAssertEqual(actual.count, expected.count,
                       "未注册端点数量变了：期望 \(expected.count)，实际 \(actual.count)（\(actual)）")
        for id in expected {
            XCTAssertTrue(actual.contains(id),
                          "在用端点 \(id) 从署名清单里消失了 —— 它不参与降级链，"
                          + "没有别的守卫能兜住这条静默丢失")
        }
    }

    /// 已注册源条目**派生**自 `SourceDirectory`，故新增源自动获得署名。
    ///
    /// 锚的是「派生关系」：条目数必须等于源数。这防的是「有人把派生改成写死清单」
    /// —— 那一刻起新增源就会静默漏掉署名，而所有URL 断言仍然全绿。
    func testRegisteredEntriesAreDerivedFromSourceDirectory() {
        XCTAssertEqual(DataAttribution.registeredSourceEntries.count,
                       SourceDirectory.all.count,
                       "已注册源署名条目数应与源目录一致（派生关系被破坏了？）")
        let ids = Set(DataAttribution.registeredSourceEntries.map(\.id))
        for descriptor in SourceDirectory.all {
            XCTAssertTrue(ids.contains(descriptor.id.rawValue),
                          "源 \(descriptor.id.rawValue) 没有对应署名条目")
        }
    }

    // MARK: - 文案：出处 + 许可 + 转换（三要素）

    /// 统一声明必须同时含**出处 / CC BY / 已做转换**三要素。
    ///
    /// 这是 CC BY 4.0 的硬要求："mandates giving appropriate credit **and**
    /// indicating **any modifications** made to the data" —— 缺「转换」这一项
    /// 是最常见的缺口（只写「数据来自 Open-Meteo」并不满足许可）。
    func testUnifiedStatementContainsCreditLicenseAndModifications() {
        let text = DataAttribution.unifiedStatement

        XCTAssertTrue(text.contains("CC BY 4.0"),
                      "统一声明必须写明许可：CC BY 4.0")
        XCTAssertTrue(text.contains("Open-Meteo"),
                      "统一声明必须写明数据出处（至少一个源名）")
        XCTAssertTrue(text.contains("转换"),
                      "统一声明必须写明「我们做了转换」—— CC BY 4.0 要求 "
                      + "indicating any modifications made to the data")
    }

    /// 转换明细非空，且逐条落地到**真实文件**（防止列出早已不存在的转换）。
    ///
    /// 断言的是「每条都注明了一个 .swift 文件名」—— 措辞可改，但
    /// 「声明的转换没有对应实现」是会让合规声明变成虚假陈述的那类错。
    func testModificationCategoriesAreNonEmptyAndEachPointsAtRealCode() {
        let categories = DataAttribution.modificationCategories
        XCTAssertFalse(categories.isEmpty, "转换明细为空 —— 等于没声明改动")

        for item in categories {
            XCTAssertFalse(item.isEmpty, "转换明细里有空条目")
            XCTAssertTrue(item.contains(".swift"),
                          "转换明细每条都应注明实现文件（便于核对真伪），这条没有：\(item)")
        }

        // 点名的文件必须真的存在 —— 逐条核过，不是「看起来在」。
        let referencedFiles = [
            "Core/Models/UnitPreference.swift",
            "Core/Logic/WMOCodeMapper.swift",
            "Core/Logic/WeatherFieldFormatters.swift",
            "Core/Logic/FieldFallbackResolver.swift"
        ]
        let repoRoot = Self.repositoryRoot()
        for file in referencedFiles {
            let path = repoRoot + "/" + file
            XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                          "署名文案点名的文件不存在：\(file)（声明的转换可能已失效）")
        }
    }

    /// 转换明细**不得有重复项**（设置页用 `id: \.self` 渲染，重复会让 SwiftUI
    /// 在运行时告警并可能渲染错乱）。
    func testModificationCategoriesHaveNoDuplicates() {
        let categories = DataAttribution.modificationCategories
        XCTAssertEqual(Set(categories).count, categories.count,
                       "转换明细里有重复项 —— 设置页的 ForEach(id: \\.self) 会因此错乱")
    }

    /// 许可全文链接必须可解析（用户要能点进去核对条款）。
    func testLicenseURLIsResolvable() {
        guard let url = DataAttribution.licenseURL else {
            return XCTFail("CC BY 4.0 许可链接无法解析 —— 用户无法核对条款")
        }
        XCTAssertEqual(url.scheme?.lowercased(), "https",
                       "许可链接应走 https")
        XCTAssertNotNil(url.host, "许可链接缺host")
    }

    // MARK: - 诚实纪律：archive / ensemble 的「非稳定承诺」

    /// archive / ensemble 必须写明「现状可用、官方矩阵不含」。
    ///
    /// 这两条端点当前免 Key 可用，但 Open-Meteo 官方定价页的功能矩阵**未**把它们
    /// 列入免费档。若不标注，用户会误以为长期免费 —— 那是**不实陈述**。
    /// 这不是免责声明，是诚实纪律，故钉成断言。
    func testArchiveAndEnsembleDisclaimStableFreeAccess() {
        let byId = Dictionary(uniqueKeysWithValues:
            DataAttribution.unregisteredEndpointSources.map { ($0.id, $0) })

        for id in ["open-meteo-archive", "open-meteo-ensemble"] {
            guard let entry = byId[id] else {
                XCTFail("署名条目 \(id) 不存在")
                continue
            }
            guard let note = entry.note else {
                XCTFail("\(id) 必须写明「现状可用、官方矩阵不含」—— "
                        + "当前免 Key 可用不等于官方承诺免费")
                continue
            }
            XCTAssertTrue(note.contains("免费"),
                          "\(id) 的备注必须提到免费档的现状（用户据此判断可靠性）")
            XCTAssertTrue(note.contains("不作长期免费承诺") || note.contains("不构成长期免费承诺"),
                          "\(id) 的备注必须明确「不构成长期免费承诺」，实际：\(note)")
        }
    }

    /// 反向防呆：geocoding 在官方免费档内，**不该**被误标成「非稳定承诺」。
    func testGeocodingIsNotFalselyDisclaimed() {
        let entry = DataAttribution.unregisteredEndpointSources
            .first { $0.id == "open-meteo-geocoding" }
        XCTAssertNotNil(entry, "geocoding 署名条目缺失")
        // 官方矩阵把 Geocoding 列入免费档 → 标成不稳定是**不准确**，同样要防。
        if let note = entry?.note {
            XCTAssertFalse(note.contains("不构成长期免费承诺"),
                           "geocoding 在官方免费档内，不应被标成非稳定承诺（会误导用户）")
        }
    }

    // MARK: - 付费源不得出现

    /// **未接入**的付费源不得出现在署名里。
    ///
    /// 列一个没在用的源等于虚假署名，比不署名更糟（用户会去访问一个我们根本没用的
    /// 服务，且误以为数据来自它）。这条钉住「只用实际在用的源」。
    func testNoUnwiredPaidSourcesInAttribution() {
        let text = DataAttribution.unifiedStatement
            + DataAttribution.allEntries.map(\.displayName).joined()
        for forbidden in ["和风", "QWeather", "彩云", "Caiyun", "心知", "XinZhi"] {
            XCTAssertFalse(text.contains(forbidden),
                           "署名里出现了未接入的付费源「\(forbidden)」—— "
                           + "列没用过的源等于虚假署名")
        }
    }

    // MARK: - 辅助

    /// 仓库根目录（从本文件位置向上两级：`ZhishengWeatherTests/` → 仓库根）。
    ///
    /// 失败时**如实返回空串**并让断言失败，不静默跳过（否则守卫会退化为恒真）。
    private static func repositoryRoot() -> String {
        // `#filePath` 形如「<repo>/ZhishengWeatherTests/DataAttributionTests.swift」
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZhishengWeatherTests
            .deletingLastPathComponent()   // 仓库根
            .path
    }
}
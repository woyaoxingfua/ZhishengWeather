//
//  NmcAlarmTitleParser.swift
//  Core / Logic  [App + Widget 共用]
//
//  第六源（中国气象局 NMC 官方预警）**标题 → 结构化字段**解析（纯逻辑、零 IO）。
//
//  ═══════════════════════════════════════════════════════════════════════
//  实测样本（2026-10-06 21:0x 真实 curl，经代理，
//  `https://www.nmc.cn/rest/findAlarm?pageNo=1&pageSize=200`，HTTP 200，
//  当日 `count`=161，逐字原文；随后用 Python 逐条复刻本算法验证 **161/161 全解析成功**）
//  ═══════════════════════════════════════════════════════════════════════
//  福建省泉州市石狮市气象台发布大风黄色预警信号
//  福建省泉州市气象台发布大风黄色预警信号              ← 无区县级
//  福建省漳州市龙海区气象台发布大风黄色预警信号          ← 市辖区
//  福建省漳州市漳浦县气象台发布大风黄色预警信号          ← 县
//  黑龙江省大兴安岭地区气象台发布大风蓝色预警信号        ← 「地区」级，无区县
//  黑龙江省大兴安岭地区塔河县气象台发布大风蓝色预警信号← 「地区」级 + 县
//  新疆维吾尔自治区博尔塔拉蒙古自治州温泉县气象台发布霜冻蓝色预警信号
//  新疆维吾尔自治区喀什地区塔什库尔干县气象台发布大风蓝色预警信号
//  新疆维吾尔自治区阿勒泰地区阿勒泰市气象台发布道路结冰黄色预警信号
//  广西壮族自治区桂林市气象台发布大风蓝色预警信号        ← 自治区 + 地级市，无区县
//  广西壮族自治区桂林市临桂区气象台发布大风蓝色预警信号← 自治区 + 市 + 区
//  宁夏回族自治区吴忠市青铜峡市气象台发布大风蓝色预警信号← 自治区 + 市 + 县级市
//  宁夏回族自治区吴忠市红寺堡区气象台发布大风蓝色预警信号← 自治区 + 市 + 区
//  云南省普洱市景谷傣族彝族自治县气象台发布雷电黄色预警信号← 自治县
//  云南省临沧市沧源佤族自治县气象台发布暴雨蓝色预警信号← 佤族自治县
//  吉林省延边朝鲜族自治州汪清县气象台发布大雾黄色预警信号← 自治州 + 县
//  湖南省湘西土家族苗族自治州古丈县气象台发布大雾橙色预警信号← 自治州 + 县 + 橙
//  辽宁省朝阳市喀喇沁左翼蒙古族自治县气象台发布大风蓝色预警信号
//  辽宁省沈阳市辽中区气象台发布大雾橙色预警信号
//  广东省河源市龙川县气象台发布森林火险黄色预警信号← 多字类型「森林火险」
//  广东省肇庆市四会市气象台发布森林火险橙色预警信号      ← 县级市 + 橙
//  海南省气象台发布海上雷雨大风黄色预警信号            ← 仅省级 + 多字类型
//  海南省三沙市气象台发布雷雨大风黄色预警信号          ← 省直辖县级市，无区县
//  贵州省遵义市正安县气象台发布大雾黄色预警信号
//  甘肃省酒泉市肃北蒙古族自治县气象台发布大风蓝色预警信号← 蒙古族自治县
//
//  ── ⚠️ 上游两处脏数据（实测逐字，必须专门处理）────────────────────────
//  ① `重庆市县云阳县气象台发布大雾黄色预警信号`
//     直辖市名下多吐了一个「县」字（`重庆` + `市` + `县` + `云阳县`）。
//     规则：**直辖市前缀自身即完整地级信息**，故 `city` = 省名、
//     其后残余串**整段丢弃** —— 宁可少报一级，也绝不产出「市 = 县」这种
//     不可能的层级。
//  ② `广东省清远市广东省连山壮族瑶族自治县气象台发布森林火险橙色预警信号`
//     区县段开头**重复了省名**（真·连山在清远市，与重复无关）。
//     规则：区县段若以省级名开头，**剥掉那一份**（实测全161 条里仅此 1 例）。
//
//  ── 标题文法（由上述 24 条样本归纳，非猜测）──────────────────────────────
//  `行政区划前缀` + `气象台` + [`发布`] + `预警类型` + `颜色` + `预警信号`
//  「行政区划前缀」段数**可变**：省(+市)(+区/县)，最少 1 段、最多 3 段。
//
//  ── 为什么解析器宁可返回 nil，也不兜底猜区县 ────────────────────────────
//  本仓纪律：**宁可nil 也绝不猜错**。全国有多个「鼓楼区」「城关区」「朝阳县」，
//  段数判断不清时若硬凑一个区县，UI 会把**别处的预警**挂到本城市头上 ——
//  那是**内容错误**（用户会以为本地有红色预警），比缺测严重得多。
//  故：省级名不在词表 / 地级形态判不出/ 颜色词缺失 → 整个结果 nil。
//
//  ── alertid 前 6 位作为**交叉验证**（实测 8/8 命中）────────────────────
//  `350581`=福建泉州市石狮市、`430582`=湖南邵阳市邵东市、
//  `640381`=宁夏吴忠市青铜峡市、`441284`=广东肇庆市四会市……
//  → 行政区划码与标题解析结果**互为印证**。这是本文件规则可信度的外部证据；
//  ⚠️ 但**筛选仍以标题为准**（码仅用于按城市过滤，见 `NmcAlarmMapper`）。
//
//  Core 纪律：仅 import Foundation；纯函数；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// NMC 预警**颜色等级**。
///
/// ⚠️ **四档不是全集** —— 实测样本里出现过 `橙色`（大雾橙/ 森林火险橙 /
/// 雷雨大风橙，全量 161 条实测颜色分布：黄 102 / 蓝 46 / 橙 13）。
/// 故本enum 显式承认第五档 `.orange`，并为**将来可能出现的其他颜色**
/// 留 `.unspecified(原文)` 兜底 —— **绝不**把不认识的颜色悄悄降级成`.blue`
/// （那会让一个未知等级被显示成最低档，属内容错误）。
// ⚠️ **不要加 `String` raw type** —— 本 enum 有 `case unspecified(String)`
// 关联值 case，Swift 明确规定「有raw type 的 enum 不能有带参数的 case」
// （error: enum with raw type cannot have cases with arguments），
// 且 RawRepresentable / CaseIterable 合成会连带失败。
// 颜色原文走 `rawText` 计算属性取，不靠 rawValue。
enum NmcAlarmColor: Equatable, Sendable {

    /// 红色（最高；实测 `data.stat` 里 `r` 计数位，当前为 0）。
    case red
    /// 橙色（实测存在：大雾橙 / 森林火险橙）。
    case orange
    /// 黄色（实测占比最高）。
    case yellow
    /// 蓝色（最低）。
    case blue
    /// 上游出现了本enum 未收录的颜色 → **如实保留原文**，不降级。
    case unspecified(String)

    /// 四个已知色的**穷举**（供测试遍历 / 颜色分布统计用）。
    ///
    /// ⚠️ 刻意**不含** `.unspecified` —— 它带原文，不是稳定枚举成员，
    /// 遍历时无法给出可比对的值。
    static let knownColors: [NmcAlarmColor] = [.red, .orange, .yellow, .blue]

    /// **展示 / 排序用的规范序**（红 > 橙 > 黄 > 蓝）。
    ///
    /// ⚠️ `.unspecified` 排在**所有已知色之后**（序值 99）——
    /// 语义是"等级未知，不得被当成低危而排到前面"。
    /// 这是本仓「宁缺不猜」纪律在排序上的直接落点。
    var severityRank: Int {
        switch self {
        case .red: return 0
        case .orange: return 1
        case .yellow: return 2
        case .blue: return 3
        case .unspecified: return 99
        }
    }

    /// 中文展示名（`.unspecified` 透传原文，不编造名称）。
    var displayName: String {
        switch self {
        case .red: return "红色"
        case .orange: return "橙色"
        case .yellow: return "黄色"
        case .blue: return "蓝色"
        case .unspecified(let raw): return raw
        }
    }
}

/// 解析出的 NMC 预警标题（**全部环节成功才产出**，任一环节不明确 → 整体 nil）。
///
/// ⚠️ `province` / `city` / `county` **可以合法为 nil**：那是**如实反映**
/// 「上游本次发布就没带这一级」（实测 `福建省泉州市气象台…` 无区县级、
/// `海南省气象台…` 只有省一级）。**nil = 上游没给**，绝不等于「解析失败」——
/// 解析失败时是**整个 `NmcAlarmTitle` 为 nil**。
struct NmcAlarmTitle: Equatable, Sendable {

    /// 省 / 自治区 / 直辖市（如 `福建省`、`新疆维吾尔自治区`、`重庆市`）。
    var province: String?
    /// 地级市 / 自治州 / 地区（如 `泉州市`、`大兴安岭地区`、`博尔塔拉蒙古自治州`）。
    /// **直辖市时== 省级名**（实测 `重庆市` 的 city 为 `重庆市`，与省同名）。
    var city: String?
    /// 区 / 县 / 县级市 / 市辖区（如 `龙海区`、`石狮市`、`利通区`）。
    var county: String?
    /// 预警类型（如 `大风`、`大雾`、`森林火险`、`地质灾害`、`海上雷雨大风`）。
    var kind: String
    /// 颜色等级（**非可选**：颜色词缺失即解析失败，见类型注释）。
    var color: NmcAlarmColor

    /// 供 UI 直接展示的行政区划串（`省 / 市 / 区`，缺级自动跳过、无多余分隔符）。
    var displayRegion: String {
        var parts: [String] = []
        if let province { parts.append(province) }
        if let city { parts.append(city) }
        if let county { parts.append(county) }
        return parts.joined(separator: " / ")
    }
}

/// NMC 预警标题解析器（**纯函数、可离线单测**）。
enum NmcAlarmTitleParser {

    // MARK: - 词表（由实测样本归纳，见文件头样本清单）

    /// 省级行政区名 → 是否**直辖市**。
    ///
    /// ⚠️ 直辖市是本解析器**唯一**需要特殊处理的形态：它没有「市」这一级，
    /// 故 `省级名` 自身即完整地级信息。
    /// ⚠️ **台湾 / 香港 / 澳门不在表内** —— 实测它们从未出现在预警流里
    /// （GB/T 2260 亦未对其统一编码），故解析时直接判失败（返回 nil），
    /// 而**不是**猜一个。
    static let provinceTable: [(name: String, isMunicipality: Bool)] = [
        // 直辖市（4）
        ("北京市", true), ("天津市", true), ("上海市", true), ("重庆市", true),
        // 省
        ("河北省", false), ("山西省", false), ("辽宁省", false),
        ("吉林省", false), ("黑龙江省", false), ("江苏省", false),
        ("浙江省", false), ("安徽省", false), ("福建省", false),
        ("江西省", false), ("山东省", false), ("河南省", false),
        ("湖北省", false), ("湖南省", false), ("广东省", false),
        ("海南省", false), ("四川省", false), ("贵州省", false),
        ("云南省", false), ("陕西省", false), ("甘肃省", false),
        ("青海省", false),
        // 自治区（5）
        ("内蒙古自治区", false), ("广西壮族自治区", false),
        ("西藏自治区", false), ("宁夏回族自治区", false),
        ("新疆维吾尔自治区", false)
    ]

    /// 直辖市名集合（供 `isMunicipality` 快速查询）。
    static var municipalityNames: Set<String> {
        Set(provinceTable.filter(\.isMunicipality).map(\.name))
    }

    /// 已知颜色词 → 颜色。
    ///
    /// ⚠️ 每个颜色词恒为 **2 个汉字**，故 `kind` 一律等于
    /// `middle` 去掉末尾 2 字（这一点由实测全161 条验证：0 例外）。
    static let colorWords: [(word: String, color: NmcAlarmColor)] = [
        ("红色", .red), ("橙色", .orange), ("黄色", .yellow), ("蓝色", .blue)
    ]

    /// 地级单位**后缀**词表（**长词在前**：必须先判`自治州` 再判 `市`，
    /// 否则 `延边朝鲜族自治州` 会被切成 `延边朝鲜族` + `自治州`）。
    ///
    /// 实测覆盖：`泉州市` / `大兴安岭地区` / `博尔塔拉蒙古自治州` /
    /// `延边朝鲜族自治州` / `湘西土家族苗族自治州` / `西双版纳傣族自治州` /
    /// `伊春市`（省直辖）/ `五大连池市`。
    static let prefectureSuffixes = ["自治州", "自治盟", "地区", "盟", "市", "林区"]

    /// 区县单位**后缀**词表（**长词在前**，理由同上：
    /// `景谷傣族彝族自治县` 必须先判 `自治县`，否则会被切成 `…傣族彝族` + `县`）。
    ///
    /// 实测覆盖：`县` / `市`（县级市：`石狮市`/`四会市`/`嫩江市`/`青铜峡市`）/
    /// `区`（`龙海区`/`临桂区`/`辽中区`/`红寺堡区`）/ `自治县` /
    /// `自治旗` / `旗` / `特区` / `林区`。
    static let countySuffixes = ["自治县", "自治旗", "特区", "林区", "县", "市", "区", "旗"]

    /// 中缀常量：`气象台`。
    ///
    /// ⚠️ **实测样本里 `气象台` 从不缺失**（24/24 条都有），
    /// 故它是**硬锚点**：缺它 → 解析失败（不做模糊匹配）。
    static let bureauSuffix = "气象台"

    /// 后缀常量：`预警信号`。
    static let signalSuffix = "预警信号"

    /// 发布动词：`发布`（实测 24/24 条都有，但按可选处理，见 `parse`）。
    static let verb = "发布"

    /// 解析失败时的对外文案（供 UI 诊断位使用）。
    static let unparsedDisplayName = "标题未能解析"

    // MARK: - 公开入口

    /// 解析一条 NMC 预警标题。
    ///
    /// - Parameter title: 原始标题（逐字，如
    ///   `福建省漳州市龙海区气象台发布大风黄色预警信号`）。
    /// - Returns: 解析结果；**任一环节不明确即返回 nil**（绝不半猜、绝不兜底）。
    ///
    /// ⚠️ **返回 nil 的合法原因**（不是 bug）：
    /// · 缺 `气象台` 硬锚点；
    /// · `气象台` 与 `预警信号` 之间为空、或顺序颠倒；
    /// · 颜色词缺失（无法归属四档颜色）；
    /// · 类型段为空（只有颜色没有类型，用户无从知道「什么预警」）；
    /// · 省级名不在词表内（含未收录的省级单位）。
    static func parse(_ title: String) -> NmcAlarmTitle? {
        // ① 硬锚点：`气象台`。缺 → 失败（不做模糊猜测）。
        guard let bureauRange = title.range(of: bureauSuffix) else { return nil }

        // ② `气象台` 之前 = 行政区划前缀（可为空；实测不会出现空的情形，
        //    但空则无从解析 → 失败）。
        let regionText = String(title[title.startIndex..<bureauRange.lowerBound])
        guard !regionText.isEmpty else { return nil }

        // ③ 必须以 `预警信号` 结尾，且 `气象台` 之后确有内容。
        guard title.hasSuffix(signalSuffix) else { return nil }
        let afterBureau = bureauRange.upperBound
        let signalStart = title.index(title.endIndex, offsetBy: -signalSuffix.count)
        guard signalStart >= afterBureau else { return nil }
        var middle = String(title[afterBureau..<signalStart])
        // ④ 去掉可选的发布动词 `发布`。
        if middle.hasPrefix(verb) {
            middle.removeFirst(verb.count)
        }
        guard !middle.isEmpty else { return nil }

        // ⑤ 颜色词：取**紧邻 `预警信号`**（即 `middle` 尾部）的颜色词。
        //    实测全161 条：颜色恒为末尾 2 字，0 例外。
        guard let color = trailingColor(of: middle) else { return nil }
        // ⑥ 类型 = 去掉末尾 2 字（颜色词恒 2 字，见 colorWords 注释）。
        let kind = String(middle.dropLast(2))
        guard !kind.isEmpty else { return nil }

        // ⑦ 行政区划：先切省级，再按剩余段数切市 / 区县。
        guard let region = parseRegion(regionText) else { return nil }

        return NmcAlarmTitle(province: region.province,
                             city: region.city,
                             county: region.county,
                             kind: kind,
                             color: color)
    }

    // MARK: - Private

    /// 从 `middle`（形如 `大风黄色`）尾部取颜色词。
    ///
    /// 判据 = **以某颜色词结尾**。
    /// ⚠️ 为什么不用「最靠后命中」而是「必须收尾」：`middle` 尾部**就是**
    /// 颜色词的位置（实测文法 `<类型><颜色>`，颜色紧邻 `预警信号`）。
    /// 用「收尾」这一强约束顺带排除了类型名里含颜色样字的情形 ——
    /// 那类标题本就不该被猜，宁可返回 nil。
    private static func trailingColor(of middle: String) -> NmcAlarmColor? {
        guard middle.count > 2 else { return nil }
        let tail = String(middle.suffix(2))
        for entry in colorWords where entry.word == tail {
            return entry.color
        }
        return nil
    }

    /// 行政区划切分结果（内部用）。
    private struct Region {
        var province: String
        var city: String?
        var county: String?
    }

    /// 切分行政区划前缀：`省(+市)(+区/县)`。
    ///
    /// ⚠️ **直辖市特殊处理**：直辖市没有「市」级，故 `city` 直接等于省级名；
    /// 其后残余串**整段丢弃**（实测上游会给直辖市多吐一个「县」字，
    /// 见文件头脏数据 ①）—— 宁可少报一级，绝不产出「市 = 县」。
    private static func parseRegion(_ text: String) -> Region? {
        // 省级：取**最长匹配**（`新疆维吾尔自治区` 须优先于任何更短的假设前缀）。
        var provinceName: String?
        for entry in provinceTable where text.hasPrefix(entry.name) {
            if provinceName == nil || entry.name.count > provinceName!.count {
                provinceName = entry.name
            }
        }
        guard let province = provinceName else { return nil }
        let rest = String(text.dropFirst(province.count))

        // 残余为空 → 只有省级。
        guard !rest.isEmpty else {
            return Region(province: province, city: nil, county: nil)
        }

        if municipalityNames.contains(province) {
            return Region(province: province, city: province, county: nil)
        }

        // 非直辖市：在残余里找**最早**出现的地级后缀，取到该后缀末尾为市，
        // 其后为区县。（实测 161/161 正确 —— 「最早」而非「最后」是关键：
        // `泉州市石狮市` 有两个「市」，取最早才得到市=`泉州市`、区=`石狮市`。）
        guard let cityEnd = earliestSuffixEnd(in: rest, suffixes: prefectureSuffixes),
              cityEnd > 0 else { return nil }
        let city = String(rest[rest.startIndex..<cityEnd])
        var county = String(rest[rest.index(rest.startIndex, offsetBy: cityEnd)...])

        // 脏数据 ②：区县段以重复的省名开头 → 剥掉那一份。
        county = strippingDuplicatedProvinceName(county)

        if county.isEmpty {
            return Region(province: province, city: city, county: nil)
        }
        // 区县段必须以已知**区县级后缀**收尾，否则判失败（宁缺不猜：
        // 把一段形态不对的残余硬当区县，会造出「市 = XX」的假层级）。
        guard hasKnownSuffix(county, suffixes: countySuffixes) else { return nil }
        return Region(province: province, city: city, county: county)
    }

    /// 在 `text` 中找**最早**出现的后缀，返回该后缀**结束**后的索引（nil = 无命中）。
    ///
    /// - Parameter suffixes: 后缀词表，**长词在前**（调用方保证）。
    ///   之所以必须长词在前：`自治州` 与 `市` 同理，若先判 `市`，
    ///   `延边朝鲜族自治州` 会被切成 `延边朝鲜族自治` + `州`（错的）。
    private static func earliestSuffixEnd(in text: String,
                                          suffixes: [String]) -> String.Index? {
        var best: String.Index?
        for suffix in suffixes {
            guard let range = text.range(of: suffix) else { continue }
            if best == nil || range.upperBound < best! {
                best = range.upperBound
            }
        }
        return best
    }

    /// `text` 是否以 `suffixes` 中任一后缀结尾。
    private static func hasKnownSuffix(_ text: String, suffixes: [String]) -> Bool {
        suffixes.contains { text.hasSuffix($0) }
    }

    /// 剥掉区县段开头**重复的省级名**（实测脏数据 ②：
    /// `清远市` + `广东省` + `连山壮族瑶族自治县` → 应为 `连山壮族瑶族自治县`）。
    ///
    /// ⚠️ 只剥**一份**（用 `if` 而非 `while`）：实测全161 条里仅此 1 例，
    /// 若哪天出现 `XX市YY省ZZ省县`，第二份 `YY省` 是真实行政区名的一部分
    /// —— 继续剥会把真地名剥掉。
    private static func strippingDuplicatedProvinceName(_ county: String) -> String {
        // 最长优先：`新疆维吾尔自治区` 须先于任何更短前缀命中。
        var matched: String?
        for entry in provinceTable where county.hasPrefix(entry.name) {
            if matched == nil || entry.name.count > matched!.count {
                matched = entry.name
            }
        }
        guard let matched else { return county }
        let stripped = String(county.dropFirst(matched.count))
        //剥完不得为空，且仍须以区县级后缀收尾，否则说明这不是「重复省名」，
        // 而是一个恰好以省名开头、但本身就是区县级别的名称 —— 原样返回。
        guard !stripped.isEmpty,
              hasKnownSuffix(stripped, suffixes: countySuffixes) else { return county }
        return stripped
    }
}
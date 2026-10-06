//
//  NmcAlarmMapper.swift
//  Core / Networking  [App + Widget 共用]
//
//  第六源 DTO → 领域模型映射（纯函数）。
//
//  ── 缺失容忍：缺块 / 空数组 / null 元素 一律 → **空数组**，不抛错 ────────
//  `data.page` 缺失、`page.list` 缺失、`list` 为 `[]`、`list` 里含 `null`
//  —— 四种形态**全部**回`[]`（`map` 的返回值非可选，见下）。
//  这与本仓库既有纪律一致（见 `METNorwayResponse` 文件头「解码成功但实质
//  无数据」的处理）：**解码成功 ≠ 有数据**，两者必须能被区分 ——
//  「没有预警」是 `.none`，「取不到预警」是 `.stale`，由调用方决定走哪条。
//
//  ── 标题解析失败**不丢条目** ──────────────────────────────────────────
//  解析不出标题（`NmcAlarmTitleParser.parse` 返回 nil）时，
//  本 mapper **仍然产出条目**，只是 `region` 为 nil、`kind` 落回**原文**、
//  `color` 落 `.unspecified`。理由：一条红橙预警如果因为地名解析不了就被丢掉，
//  用户会**错过真正的灾害预警** —— 那比显示一条"地区未知"的预警危险得多。
//  ⚠️ 但这**绝不允许**发生在「按城市筛选」上（见 `warnings(matching:)`）——
//    那里解析失败一律**不匹配**（宁可漏报，不可错报）。
//
//  ── 为什么按标题筛、而不是按 `alertid` 前 6 位筛 ────────────────────────
//  实测 `alertid` 前 6 位确为 GB/T 2260 区划码（8/8 交叉验证命中），
//  但本仓`City` 只有 `admin1: String?`（省名），**没有区划码字段** ——
//  用码筛就得新增一份「城市 → 6 位码」映射表（要随行政区划调整维护），
//  而标题里已经**逐字写着**市名与县名。故本 mapper 用**标题文本**匹配，
//  区划码仅作为**可选的精确优先通道**保留（`warnings(matchingCityName:cityCode:)`）。
//
//  ── 时间：时区由调用方注入 ─────────────────────────────────────────────
//  `issuetime` 是**发布地墙钟**且无时区（实测 `2026/10/06 20:28`）。
//  按设备时区解释会让境外设备把新预警算成 8 小时前的旧数据 → 误判 `.stale`。
//  故 `timeZone` **必须注入**；未注入则 `issuedAt` 为 nil（**如实缺测**），
//  且由此产出的状态会归 `.stale`（无法判定新鲜度）—— 绝不谎报新鲜。
//
//  Core 纪律：仅 import Foundation；纯函数；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 第六源 DTO → 官方预警领域模型映射器（纯函数）。
enum NmcAlarmMapper {

    /// 把整包响应映射为预警条目数组（**不做城市筛选**）。
    ///
    /// - Parameters:
    ///   - response: 解码后的 DTO（`data` / `page` / `list` 任一可为 nil）。
    ///   - timeZone: 发布地时区（**必须由调用方注入**；nil → `issuedAt` 全为 nil）。
    /// - Returns: 条目数组（保持上游顺序；空数组 = 「取到了，但没有预警」）。
    static func map(_ response: NmcAlarmResponse,
                    timeZone: TimeZone?) -> [OfficialWarningItem] {
        // 三处可选链缺任一 → 空数组（**不抛错**：解码成功但实质无数据）。
        guard let list = response.data?.page?.list else { return [] }
        return list.compactMap { entry in
            // ⚠️ 数组元素本身可为 nil（上游塞 null）→ compactMap 自动跳过。
            mapEntry(entry, timeZone: timeZone)
        }
    }

    /// 按城市筛选（**按对齐后的地级名逐字相等**，见下）。
    ///
    /// ⚠️ **本仓城市名不带行政后缀**（实测 `福州` / `石家庄` / `上海`），
    /// 而 NMC 标题里的地级名**带后缀**（实测 `泉州市` / `大兴安岭地区`）。
    /// 故比对前经 `normalizedPrefectureName(_:)` 对齐 —— 否则**永远匹配不上**。
    ///
    /// - Parameters:
    ///   - items: 已映射的条目。
    ///   - cityName: 本仓城市名（如 `福州`）。
    ///   - cityCode: 可选的 6 位行政区划码。给定时会**额外**用
    ///     `alertid` 前 6 位做精确比对（实测 8/8 与标题一致，两者互为印证）。
    /// - Returns: 命中该城市的条目（**解析不出的条目一律不命中**，宁缺不猜）。
    static func warnings(in items: [OfficialWarningItem],
                         matchingCityName cityName: String?,
                         cityCode: String? = nil) -> [OfficialWarningItem] {
        // 城市名为空 → 无从判断，**返回空**（绝不"全都要"）。
        guard let cityName, !cityName.isEmpty else { return [] }
        return items.filter { item in
            // ⚠️ 条目的市段为 nil（标题没解析出市，如省级直发）→ 不命中。
            guard let itemCity = item.cityName,
                  normalizedPrefectureName(itemCity) == cityName else { return false }
            // 给了码就再核一道：两条都命中才算（宁缺不猜）。
            if let cityCode, !cityCode.isEmpty {
                return item.administrativeCode == cityCode
            }
            return true
        }
    }

    // MARK: - Private

    /// 单条 `Entry` → 领域模型。**任何字段缺失都不抛错**，缺失即 nil。
    private static func mapEntry(_ entry: NmcAlarmResponse.Entry,
                                 timeZone: TimeZone?) -> OfficialWarningItem? {
        let title = entry.title ?? ""
        let parsed = NmcAlarmTitleParser.parse(title)

        // id：优先 `alertid`；缺失时合成一个**确定性**串（同样输入→同样 id，
        // 避免 SwiftUI 每次刷新都把所有行认成新行）。
        let id = entry.alertid
            ?? "nmc-unknown-\(title.hashValue)"

        return OfficialWarningItem(
            id: id,
            region: parsed?.displayRegion,
            cityName: parsed?.city,
            administrativeCode: Self.administrativeCode(from: entry.alertid),
            kind: parsed?.kind ?? kindFallback(from: title),
            color: parsed?.color ?? .unspecified(""),
            issuedAt: NmcIssueTimeDecoder.date(from: entry.issuetime ?? "",
                                               timeZone: timeZone),
            detailURL: NmcAlarmEndpoint.detailURL(relativePath: entry.url),
            rawTitle: title)
    }

    /// `alertid` → **前 6 位行政区划码**（GB/T 2260）。
    ///
    /// 实测形态：`35060441600000_20261006202800` → `350604` = 福建漳州市龙海区。
    /// 已用 8 个已知码交叉校验（`350581`石狮市 / `430582` 邵东市 /
    /// `640381` 青铜峡市 / `441284` 四会市 …）**8/8 命中**。
    ///
    /// - Returns: 6 位数字串；`alertid` 缺失 / 长度不足 / 前 6 位非数字 → nil
    ///   （**不截断一个不完整的码**，半个码拿去比对会误匹配到别的城市）。
    static func administrativeCode(from alertid: String?) -> String? {
        guard let alertid, alertid.count >= 6 else { return nil }
        let head = String(alertid.prefix(6))
        guard head.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return head
    }

    /// 标题解析失败时，从原文里尽力取「类型」段（用于卡片上那句 `XX预警`）。
    ///
    /// 做法：取 `气象台` 与 `预警信号` 之间的中段（实测该段恒为
    /// `发布<类型><颜色>`），再去掉尾 2 字颜色位。
    /// ⚠️ **失败回 `unknownKind`** —— **绝不**回落到空串或整个标题
    /// （整个标题当类型会让卡片显示成一句 20 字长句）。
    static func kindFallback(from title: String) -> String {
        guard let bureauRange = title.range(of: NmcAlarmTitleParser.bureauSuffix),
              title.hasSuffix(NmcAlarmTitleParser.signalSuffix) else {
            return unknownKind
        }
        var middle = String(title[bureauRange.upperBound..
                                    title.index(title.endIndex,
                                                offsetBy: -NmcAlarmTitleParser.signalSuffix.count)])
        if middle.hasPrefix(NmcAlarmTitleParser.verb) {
            middle.removeFirst(NmcAlarmTitleParser.verb.count)
        }
        guard middle.count > 2 else { return unknownKind }
        return String(middle.dropLast(2))
    }

    /// 预警类型的回落占位（供 UI 直接展示；**非空**）。
    static let unknownKind = "气象预警"

    /// 把本仓的城市名（`福州`）与 NMC 的地级名（`泉州市`）**对齐**后再比对。
    ///
    /// ⚠️ **为什么必须做这一步（本仓实测口径）**：`WidgetBuiltInCities` /
    /// `CityDirectory` 里的城市名**不带行政后缀**（实测逐字为
    /// `福州` / `石家庄` / `呼和浩特` / `上海`），而 NMC 标题里的地级名**带后缀**
    /// （实测逐字为 `泉州市` / `大兴安岭地区` / `博尔塔拉蒙古自治州`）。
    /// 直接 `==` 比对的结果是**永远匹配不上** —— 那会让整张预警卡
    /// 永远停在 `.none`（看起来"没有预警"，实际是筛选器失效）。
    ///
    /// 对齐规则（**两侧都只剥一次**）：把 NMC 侧的 `市` / `地区` / `自治州` /
    /// `自治盟` / `盟` / `林区` 后缀剥掉，再与本仓城市名**逐字相等**。
    /// ⚠️ 本仓侧**不剥**：若某城市本名就叫「乌兰察布」（无后缀），
    /// 剥了反而对不上（实测内置城市名全部无后缀，剥只会引入偏差）。
    ///
    /// ⚠️ **为什么是「相等」而不是「包含」**：全国有多个同名区县
    /// （多个「鼓楼区」「城关区」「朝阳区」）。用包含匹配会让
    /// `鼓楼区` 同时命中 `福州市鼓楼区` 与 `南京市鼓楼区` ——
    /// 那会把**别处的预警**挂到本城市头上（内容错误）。
    /// 故只在**已对齐的地级名**上做逐字相等。
    static func normalizedPrefectureName(_ nmcCityName: String) -> String {
        // 长后缀在前（`自治州` 必须先于 `市` 判，否则 `延边朝鲜族自治州`
        // 会被剥成 `延边朝鲜族自治`）。
        let suffixes = ["自治州", "自治盟", "地区", "林区", "盟", "市"]
        for suffix in suffixes where nmcCityName.hasSuffix(suffix) {
            // 剥完不得为空（`市` 单独出现 → 原样返回，不产出空串）。
            let stripped = String(nmcCityName.dropLast(suffix.count))
            return stripped.isEmpty ? nmcCityName : stripped
        }
        return nmcCityName
    }
}
//
//  NmcAlarmEndpoint.swift
//  Core / Networking  [App + Widget 共用]
//
//  第六源：中国气象局（NMC）官方预警信号请求 URL 拼装。
//  选它的理由：这是**中国气象局官网自有的预警发布渠道**——
//  与前面五个源的根本区别是它是**官方预警本身**（其余五家都是数值预报/要素站）。
//  **免 Key、无需 Referer**（实测 2026-10-06 有效）。
//
//  ═══════════════════════════════════════════════════════════════════════
//  实测结论（2026-10-06 21:0x 真实 curl，经代理）
//  ═══════════════════════════════════════════════════════════════════════
//  · 端点：`https://www.nmc.cn/rest/findAlarm?pageNo=1&pageSize=200`
//    → **HTTP 200**，`content-type: application/json;charset=UTF-8`
//  · ⚠️ **`pageSize` 大小写敏感**（实测逐字对照）：
//    `pageSize=200` → `page.pageSize` 回 200、`count`=161（**全量**）；
//    `pagesize=200` → 退回 10。故此处**必须**写 `pageSize`。
//  · ⚠️ **`stationid` 参数无效**：带 / 不带 / 乱填（如 `110000`）返回的是
//    **同一份全国列表** → 它**不是**按站查询的接口，而是**全国流水**。
//    → 故本端点**不发** `stationid`；按城市筛选在`NmcAlarmMapper` 里做
//      （依据标题解析出的市/ 县名与行政区划码）。
//  · ✅ **`province` 参数有效，但只接受中文省名**（实测 37 个省名逐个探测）：
//    `province=福建省` → 14 条、`province=黑龙江省` → 15 条、
//    `province=重庆市` → 1 条、`province=北京市` → **0 条**（当日北京无预警，
//    **这是真实业务结果、不是请求失败**）；
//    `province=110000` → **HTTP 417**、`province=beijing` → **HTTP 417**
//    （故它只收中文名，不收区划码与拼音）。
//    → 本端点**不传** `province`：一次拉全国列表即可（当日 161 条 ≈ 45 KB），
//      避免"为每个城市各发一次请求"。分省能力在此记录，供将来按需使用。
//  · ✅ **活性实证**：同一 URL 隔几分钟连抓两次，`count` 162 → **163**、
//    某条 `issuetime` 20:28 → **20:35**（本worker 亦实测到
//    161 → 不同时刻不同count，见 `NmcAlarmResponse` 文件头）。
//  · ✅ 站点可打开：`http://www.nmc.cn/` → **HTTP 200**（`SourceDirectory`
//    的 `websiteURLString` 据此填该值）。
//
//  ──⚠️ 许可状态（必须如实，不得美化）────────────────────────────────
//  我们调用的是**公开网页接口**，**未获中国气象局任何形式的 API 授权 /
//  许可协议签署**。故 `SourceDescriptor.usageNote` 里如实写明这一点，
//  仅供个人自用。**不要**写「官方授权」或任何暗示已获授权的字样。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 中国气象局（NMC）官方预警信号请求拼装器（免 Key、无需 Referer）。
enum NmcAlarmEndpoint {

    /// 站点根地址（**不带尾斜杠**；拼详情页 URL 时需要它做前缀）。
    ///
    /// 实测 `http://www.nmc.cn/`（http）与 `https://www.nmc.cn/`（https）
    /// **均返回 200**，故详情页统一用 https。
    static let siteRootURLString = "https://www.nmc.cn"

    /// `SourceDirectory` 登记用的官网地址（实测 **HTTP 200**）。
    ///
    /// ⚠️ 与 `siteRootURLString` **刻意不同**：前者是给用户看的官网入口
    /// （带尾斜杠更像地址），后者是拼 URL 的机器值（不带尾斜杠避免 `//`）。
    static let websiteURLString = "http://www.nmc.cn/"

    /// 预警列表端点。
    static let listPath = "/rest/findAlarm"

    /// 一次请求的条数上限（实测 `count`=161 时一页取尽）。
    ///
    /// ⚠️ **键名大小写敏感**：必须是 `pageSize`（见文件头实测）。
    static let pageSize = 200

    /// 拼装「全国预警列表」请求 URL。
    ///
    /// - Parameter pageNo: 页码，从 1 开始（实测 `pageNo=2/3` 亦返回 200）。
    /// - Returns: 失败返回 nil（由调用方收敛为 `WeatherError.badURL`）。
    static func url(pageNo: Int = 1) -> URL? {
        var components = URLComponents(string: siteRootURLString + listPath)
        components?.queryItems = [
            URLQueryItem(name: "pageNo", value: String(pageNo)),
            // ⚠️ 大小写敏感：写 `pagesize` 会静默退回 10 条（实测）。
            URLQueryItem(name: "pageSize", value: String(pageSize))
        ]
        return components?.url
    }

    /// 把条目里的**相对路径**（实测形如
    /// `/publish/alarm/35060441600000_20261006202800.html`）拼成绝对 URL。
    ///
    /// - Parameter relativePath: `Entry.url` 原样。
    /// - Returns: 空串 / 非绝对路径 / 无法构造 → nil（**不猜、不兜底**）。
    ///
    /// ⚠️ 为什么不给它兜底到 `listPath`：拼错域名会得到一个**看起来正常**
    /// 的URL，用户点进去却是404 —— 如实返回 nil 让调用方显示「详情不可用」。
    static func detailURL(relativePath: String?) -> URL? {
        guard let relativePath, !relativePath.isEmpty else { return nil }
        // 已是绝对 URL（以 http 开头）→ 原样返回（兼容上游未来改成绝对路径）。
        if relativePath.hasPrefix("http://") || relativePath.hasPrefix("https://") {
            return URL(string: relativePath)
        }
        // 上游实测给的是以 `/` 开头的绝对路径；缺 `/` 视为异常 → nil。
        guard relativePath.hasPrefix("/") else { return nil }
        return URL(string: siteRootURLString + relativePath)
    }
}
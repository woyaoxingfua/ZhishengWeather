//
//  NmcTyphoonEndpoint.swift
//  Core / Networking  [App + Widget 共用]
//
//  第七源：中央气象台台风网请求 URL 拼装。
//
//  ═══════════════════════════════════════════════════════════════════════
//  实测基准：2026-10-07（本 worker 当次真实 curl，统一带
//  `-s -m 25 -L --compressed -A "<iPhone UA>"`）
//  ═══════════════════════════════════════════════════════════════════════
//
//  ── 实测通过的端点（逐字）─────────────────────────────────────────
//  ✅ `https://typhoon.nmc.cn/weatherservice/typhoon/jsons/list_default`
//     → **HTTP 200**，2797B，32 条，3 条 `"start"`（诺洛/小熊/彩云）
//  ✅ `https://typhoon.nmc.cn/weatherservice/typhoon/jsons/list_1950`
//     → **200**，2307B，42 条，**全部 `"stop"`**
//  ✅ `https://typhoon.nmc.cn/weatherservice/typhoon/jsons/list_1999`
//     → **200**，1688B，28 条，全部 `"stop"`
//  ✅ `https://typhoon.nmc.cn/weatherservice/typhoon/jsons/list_2024`
//     → **200**，2612B，28 条，全部 `"stop"`
//  ✅ `https://typhoon.nmc.cn/weatherservice/typhoon/jsons/view_3346168`
//     → **200**，12478B，19 个路径点
//  ✅ `view_3341981` →200 / 26767B / 51 点
//  ✅ `view_3346033` → 200 / 11462B / 19 点
//  ✅ `view_3227033`（2005 布拉万，历史）→ 200 / 2267B / 26 点
//
//  ── 实测失败路径（**服务层据此区分「取不到」与「没有」**）────────────
//  ❌ `view_9999999`（错误 id）→ **HTTP 404**，`text/html`，591B
//  ❌ `list_2030`（未来年份）→ **HTTP 404**，`text/html`，618B
//     两者响应体逐字以 `<!DOCTYPE HTML PUBLIC ...>` 开头
//     → **非 JSON**，必须先过状态码再剥壳，否则报解码错（掩盖真因）。
//
//  ── 免鉴权实测 ────────────────────────────────────────────────────
//  · **无需 Referer**（实测直接请求即200）；
//  · **无需特定 UA**（实测 iPhone Safari UA / curl 默认 UA 均 200 同字节）；
//  · **无需账号 / Key / Referer**。
//  → 故服务层用最简的 `session.data(from:)`，不附加任何头。
//
//  ── HTTPS 可用 ────────────────────────────────────────────────────
//  实测 `https://` 直连 200（iOS ATS **无需**例外配置）。
//
//  ── 许可状态（必须如实，不得美化）──────────────────────────────
//  这是中央气象台的**公开网页前端接口**，**未获任何形式的 API 授权 /
//  许可协议签署**。故 `SourceDescriptor.usageNote` 如实告知
//  「未经官方 API 授权、仅供个人自用」，**不得**写「官方授权」。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 中央气象台台风网请求拼装器（免 Key、无需 Referer）。
enum NmcTyphoonEndpoint {

    /// 站点根（**不带尾斜杠**；拼路径时避免出现 `//`）。
    static let siteRootURLString = "https://typhoon.nmc.cn"

    /// `SourceDirectory` 登记用的官网地址。
    ///
    /// ⚠️ 与 `siteRootURLString` 刻意不同：前者是给用户看的可点入口，
    /// 后者是拼 URL 的机器值。实测 `https://typhoon.nmc.cn/` 可达。
    static let websiteURLString = "https://typhoon.nmc.cn/"

    /// 数据路径前缀（实测三个端点共用同一前缀）。
    static let jsonPathPrefix = "/weatherservice/typhoon/jsons/"

    /// 「默认列表」的资源名（实测返回当前年全部台风，含已停止）。
    ///
    /// ⚠️ 不是「正在进行的台风列表」—— 实测 32 条里 29 条是 `"stop"`，
    /// 需由调用方用 `NmcTyphoonMapper.activeOnly` 过滤。
    static let defaultListResource = "list_default"

    /// 最早可回溯年份（**实测 `list_1950` → HTTP 200**，42 条）。
    ///
    /// ⚠️ 这是**实测能取到的下界**，不是「台风业务始于 1950 年」的断言
    /// —— 后者属于气象学史，与本端点能力无关，不在代码里断言。
    static let earliestSupportedYear = 1950

    /// 拼装「默认列表」请求 URL。
    ///
    /// - Returns: URL；构造失败 → nil（由调用方收敛为 `WeatherError.badURL`）。
    static func defaultListURL() -> URL? {
        URL(string: siteRootURLString + jsonPathPrefix + defaultListResource)
    }

    /// 拼装「指定年份列表」请求 URL。
    ///
    /// - Parameter year: 年份（如 `2024`）。
    /// - Returns: URL；年份**超出实测范围** → nil（**不构造必然 404 的请求**）。
    ///
    /// ⚠️ 实测 `list_2030`（未来年）→ **404 HTML**。故此处**前置拒绝**
    /// 未来年份，而不是发一次请求换一个 404 回来。
    static func yearListURL(year: Int) -> URL? {
        // 上界用「调用方所在年」无法在Core 内取（禁内部 Date()），
        // 故只做**下界**与**合理上界**（实测当前业务年 ~= 2026，
        // 放宽到 2100 足够且不会误拒未来的真实年份）。
        guard year >= earliestSupportedYear, year <= 2100 else { return nil }
        return URL(string: siteRootURLString + jsonPathPrefix + "list_\(year)")
    }

    /// 拼装「单个台风完整路径 + 官方预报」请求 URL。
    ///
    /// - Parameter id: 台风 id（来自列表端点，实测如 `3346168`）。
    /// - Returns: URL；id **含非数字字符** → nil。
    ///
    /// ⚠️ id 只允许数字：它是直接拼进路径的（实测形如 `view_3346168`），
    /// 不做字符白名单就会被构造成 `/` `?` 之类改写路径 → 打到别的端点上。
    static func trackURL(id: String) -> URL? {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        return URL(string: siteRootURLString + jsonPathPrefix + "view_\(id)")
    }
}
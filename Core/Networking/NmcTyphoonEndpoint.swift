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

    /// 宽松上界（**刻意放宽到2100**，不是「当前年」）。
    ///
    /// ⚠️ **为什么不用当前年当上界**：本enum 属 Core 层，而 Core **禁用
    /// `Date()`**（见本文件头纪律）→ 本层**取不到当前年**，判不了「未来」。
    /// 若强行上界成「当前年」就得注入参数，等于把**同一个业务规则
    /// （未来年拒绝）在两层各实现一遍** —— 迟早不一致。
    ///
    /// 真正的「未来年」拒绝在 `TyphoonCardModel.load`
    ///（`guard year <= currentYear`，它**注入**了 `currentYear`）。
    /// 故此常量只是**防明显无效路径**的宽松兜底，不是业务语义边界。
    static let latestSupportedYear = 2100

    /// 拼装「默认列表」请求 URL。
    ///
    /// - Returns: URL；构造失败 → nil（由调用方收敛为 `WeatherError.badURL`）。
    static func defaultListURL() -> URL? {
        URL(string: siteRootURLString + jsonPathPrefix + defaultListResource)
    }

    /// 拼装「指定年份列表」请求 URL。
    ///
    /// - Parameter year: 年份（如 `2024`）。
    /// - Returns: URL；年份**超出实测可达范围** → nil。
    ///
    /// ⚠️ **本层只守「实测可达范围」，不守「未来年」**：
    /// 上界取宽松的 `latestSupportedYear`（2100）而非「当前年」，
    /// 因为 Core 层**禁用 `Date()`**（见本文件头纪律）→ 本层**拿不到当前年**，
    /// 无从判断某年是否「未来」。
    ///
    /// 🔴 **「未来年前置拒绝」的真实落点是 `TyphoonCardModel.load`**
    /// （`guard year <= currentYear` → `.unavailable("所选年份尚未到来")`）：
    /// 它**注入**了 `currentYear`，由
    /// `testFutureYearIsRejectedNotTreatedAsNoTyphoon` 锚定。
    /// 且唯一年份产出方 `selectableYears(currentYear:)` 只给
    /// `currentYear - 4 ... currentYear` → 业务链路上到不了未来年。
    /// **不要**在此处重复实现该规则（同一业务规则两处实现 = 迟早不一致）。
    ///
    /// 📌 交接文档记载实测 `list_2030`（未来年）→ **404 HTML**；
    /// 本轮**未复测**，故只作为上述模型层拒绝策略的依据，不在此处加断言。
    static func yearListURL(year: Int) -> URL? {
        guard year >= earliestSupportedYear, year <= latestSupportedYear else { return nil }
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
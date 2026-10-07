//
//  SatelliteImageEndpoint.swift
//  Core / Networking  [App + Widget 共用]
//
//  第八源：中央气象台风云四号真彩卫星云图 —— **URL 拼装 + 时次推导**（纯逻辑，零 IO）。
//
//  ═══════════════════════════════════════════════════════════════════════
// 实测基准：2026-10-07（本worker 当次真实 curl，统一带
// `-s -m 25 -L --compressed -A "<浏览器 UA>"`；图片类用 `-o` 存盘后用
// Pillow 逐像素统计）
// ═══════════════════════════════════════════════════════════════════════
//
// ── 索引页（时次真源）─────────────────────────────────────────────────
// ✅ `http://www.nmc.cn/publish/satellite/fy4b-visible.htm`
//    → **HTTP 200**，`text/html`，**14 907 / 14 909 B**（两次实测差 2 B，
//      页面含时间戳等动态内容，故**字节数本就不稳定**——
//      旧文档的单一值 14 908 B 不能当契约用）
//    页面内 `data-original` / `src` 逐字含 48 个产品 URL（本轮实测去重后
//    恰好 48 个），形如：
//    `https://image.nmc.cn/product/2026/10/07/WXBL/medium/
//      SEVP_NSMC_WXBL_FY4B_ETCC_ACHN_LNO_PY_20261007140000000.JPG?v=…`
//
// ── 产品名逐字拆解（实测，不是推测）──────────────────────────────────
// `SEVP_NSMC_WXBL_FY4B_ETCC_ACHN_LNO_PY_<17 位时戳>.JPG`
//   `SEVP_`   业务前缀
//   `NSMC_`   国家卫星气象中心
//   `WXBL`    **卫星云图**分类（实测：雷击是 `WEAP`、海浪是 `NWPR`）
//   `FY4B`    风云四号 B 星（画面角标实测逐字 `FY-4B AGRI`）
//   `ETCC`    真彩色（Enhanced True Colour Cloud）
//   `ACHN`    亚洲 / 中国区域
//   `LNO`     经度（Longitude）——**与纬度产品分码**，故本产品是经纬网裁切
//   `PY`      白天可见光
//
// ── 🔴 时戳是 **UTC**，不是北京时间（本轮实测更正）────────────────────
// 产品名时戳 `20261007101500000` 对应画面左上角角标逐字：
//   `2026-10-07 10:15 (UTC)` 与 `2026-10-07 18:15 (BJT)`
// → **同一时刻**，BJT = UTC + 8。即文件路径里的时戳是 **UTC**。
// ⚠️ 若当成 BJT 去拼 URL，会整整偏 8 小时（落到8 小时前的帧），
//    而服务端**照样 200**（保留窗口内），故**不会报错、只会静默给旧图**。
//    这是本文件存在的头号理由。
//
// ── 🔴 更新粒度实测是 **15 分钟**，不是设计稿写的 10 分钟 ─────────────
// 页面 48 个 URL 的时戳逐个核对，实测间隔恒为 **15 分钟**：
//   …2330 / 2345 / 0000 / 0015 / 0030 / 0045 / 0100 / 0115 …
// 且 `data-time` 角标与之逐字一致（`10/07 07:30`、`07:45`、`08:00`…）。
// → 故 `frameStepSeconds = 900`。**设计稿的「10 分钟级」与实测不符**，
//    UI 文案必须写 15 分钟，否则是编造。
//
// ── 🔴 保留窗口实测约 **12 小时 / 48 帧** ────────────────────────────
// 逐小时探测 2026-10-06 一天：
//   00/06/10/12 UTC → 404   ；12/15 UTC → 200 ；**16 UTC → 404** ；
//   22/23 UTC → 200 ；次日 04/06/08/10 UTC → 200 ；**12 UTC → 404**
// → 呈现「日内有洞、洞外有值」的锯齿，**不是**整段截断。
//   ⚠️ 因此**不能**只请求「当前时刻」，必须**向前回溯若干帧**去命中真实存在的帧。
//   实测 48 帧恰好覆盖 12 小时，故 `retentionFrameCount = 48`。
//
// ── 尺寸档位：只有 `medium` ─────────────────────────────────────────
// 本轮实测 `WXBL/high` / `WXBL/large` → **HTTP 404，响应体 552 B**，
//   4 次探测（high / large / 越界日期 / 经代理）**恒为 552 B**，
//   逐字含 `<center>openresty</center>`。
//（404 响应体是 openresty 的 HTML 错误页，**不是**图片 ——
//  故取回后必须校验内容，详见 `SatelliteFrameValidator`。）
//
// ── ✅ 只拼 HTTPS（**理由已按本轮实测更正，保留痕迹**）────────────────
// ❌ **旧文档写「`http://` 被拒 → HTTP 403（size=0）」—— 本轮实测不成立。**
//    实测 `http://image.nmc.cn/…JPG`（不带 `-L`，即不跟随跳转）→
//    **HTTP 200 / 134 751 B**，且**无 `Location` 头**（不是 3xx 跳转）；
//    带 `-L` 同样是 200 / 134 751 B，与 `https://` 的字节数**完全一致**。
//    → 故「http 被服务器拒绝」这个说法是错的。
// ✅ **但结论「只用 HTTPS」依然成立**，理由换成真正的那个：
//    iOS **ATS（App Transport Security）默认禁止明文 HTTP**，
//    要用 `http://` 就得在 Info.plist 开 `NSAllowsArbitraryLoads` 豁免，
//    而那会**削弱整个 App 的传输安全**（不只是这一个源）。
//    同一资源 HTTPS 可用 → 没有任何理由去开这个豁免。
//    → 这是**平台约束**下的取舍，不是「服务器只给 HTTPS」。
//
// ── 免鉴权实测（与台风源同款结论）──────────────────────────────────
// · **无需Referer**（实测不带 Referer 直接 200）；
// · **无需特定 UA**（实测 curl 默认 UA 亦 200 且字节数相同）；
// · **无需 Key / 账号**。
//
// ── 许可状态（必须如实，不得美化）────────────────────────────────────
// 中央气象台**公开网页**产品，**未获任何 API 授权 / 许可协议签署**。
// 故来源标注须写「公开网页产品 · 未经官方 API 授权 · 个人自用」。
//
// Core 纪律：仅 import Foundation；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 风云四号真彩卫星云图的 URL 拼装与时次推导（纯逻辑，零 IO、零 `Date()`）。
enum SatelliteImageEndpoint {

    // MARK: - 站点

    /// 站点根（**不带尾斜杠**；拼路径时避免出现 `//`）。
    static let siteRootURLString = "https://image.nmc.cn"

    /// 索引页（时次真源；**HTTP** 可达，本索引页不参与图片取数）。
    static let indexPagePath = "/publish/satellite/fy4b-visible.htm"

    /// 图片根路径模板首段（`{YYYY}/{MM}/{DD}` 由时戳推导）。
    static let productPathPrefix = "/product/"

    /// 产品分类目录（实测：卫星云图 = `WXBL`）。
    static let categoryDirectory = "WXBL"

    /// 尺寸档位。**实测仅 `medium` 存在**，`high` / `large` 均 404。
    static let sizeSegment = "medium"

    /// 产品名固定前缀（时戳之前的全部常量部分，逐字实测）。
    static let productNamePrefix = "SEVP_NSMC_WXBL_FY4B_ETCC_ACHN_LNO_PY_"

    /// 产品名固定后缀。
    static let productNameSuffix = ".JPG"

    /// 来源标注用的官网地址（与 `siteRootURLString` 不同：给人看的入口）。
    static let attributionURLString = "http://www.nmc.cn/publish/satellite/fy4b-visible.htm"

    // MARK: - 时次（实测常量）

    /// 帧间隔（**实测 15 分钟**，非设计稿所写 10 分钟）。
    static let frameStepSeconds: TimeInterval = 900

    /// 保留窗口帧数（**实测 48 帧 ≈ 12 小时**）。
    static let retentionFrameCount = 48

    /// 回溯探测的最大帧数。
    ///
    /// ⚠️ 取 48（= 整个保留窗口）而非更小的值：实测保留窗口是
    /// **锯齿状**（日内有 404 洞），少探测几帧就可能整帧落空 →
    /// 用户看到「云图加载失败」，而其实只要再往前 2 帧就有图。
    /// 代价是最坏 48 次 HEAD 级的存在性探测，故实际实现里
    /// **串行且带退避**（见 `SatelliteImageService`），不并发轰炸。
    static let maxProbeFrames = retentionFrameCount

    /// 产品名里时戳的位数（`20261007113000000` = 17 位）。
    ///
    /// 逐位实测含义：`YYYYMMDDHHMMSS` + `000`（毫秒占位，实测恒为 `000`）。
    static let stampDigits = 17

    // MARK: - 时戳 ↔ URL

    /// 把 `Date` 折成产品名里的 17 位 UTC 时戳。
    ///
    /// ⚠️ **必须按 UTC 取分量**（本文件头头号理由：BJT 会偏 8 小时且服务端不报错）。
    /// - Parameter date: 目标时刻。
    /// - Returns: 形如 `20261007113000000`。
    static func stamp(forUTCDate date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let y = c.year ?? 1970
        let mo = c.month ?? 1
        let d = c.day ?? 1
        let h = c.hour ?? 0
        let mi = c.minute ?? 0
        let s = c.second ?? 0
        return pad4(y) + pad2(mo) + pad2(d) + pad2(h) + pad2(mi) + pad2(s) + "000"
    }

    /// 由产品 URL 反解出时戳（供「更新时间」标注用，避免二次格式化偏差）。
    ///
    /// - Parameter urlString: 完整产品 URL 字符串。
    /// - Returns: 17 位时戳；解析不出 → nil。
    static func stamp(fromProductURLString urlString: String) -> String? {
        // ⚠️ **不能加 `.anchored`**：产品名前缀位于路径**中段**
        // （`/product/<Y>/<M>/<D>/WXBL/medium/` 之后），
        // 锚定到串首会永远匹配不到 → 时次解析恒为 nil。
        guard let range = urlString.range(of: productNamePrefix) else { return nil }
        let afterPrefix = urlString[range.upperBound...]
        guard afterPrefix.count >= stampDigits else { return nil }
        let digits = String(afterPrefix.prefix(stampDigits))
        guard digits.allSatisfy({ $0.isNumber }) else { return nil }
        return digits
    }

    /// 由产品 URL 反解出观测时刻（**UTC**）。
    ///
    /// ⚠️ 返回的是 **UTC 时刻**；展示时由 UI 层按城市时区渲染
    /// （与本仓「Core 不碰 DateFormatter、时刻由 UI 时区化」的纪律一致）。
    ///
    /// - Parameters:
    ///   - urlString: 完整产品 URL 字符串。
    ///   - calendar: 注入的日历（单测可固定；缺省 UTC 公历）。
    /// - Returns: 观测时刻；解析失败 → nil。
    static func observationDate(fromProductURLString urlString: String,
                                calendar: Calendar = SatelliteImageEndpoint.utcGregorian) -> Date? {
        guard let stamp = stamp(fromProductURLString: urlString),
              stamp.count == stampDigits else { return nil }
        let chars = Array(stamp)
        func num(_ range: Range<Int>) -> Int? {
            let s = String(chars[range])
            guard s.allSatisfy({ $0.isNumber }) else { return nil }
            return Int(s)
        }
        guard let y = num(0..<4), let mo = num(4..<6), let d = num(6..<8),
              let h = num(8..<10), let mi = num(10..<12), let sec = num(12..<14) else {
            return nil
        }
        var comps = DateComponents()
        comps.year = y
        comps.month = mo
        comps.day = d
        comps.hour = h
        comps.minute = mi
        comps.second = sec
        return calendar.date(from: comps)
    }

    /// UTC 公历（单一真源；`nil` 时区已由上面兜底赋值故不会为 nil）。
    static let utcGregorian: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? c.timeZone
        return c
    }()

    /// 把时刻对齐到**最近一个已过去的帧边界**（15 分钟栅格）。
    ///
    /// - Parameter date: 目标时刻。
    /// - Returns: 向下取整到 15 分钟栅格的时刻。
    static func alignedToFrame(now date: Date) -> Date {
        let step = frameStepSeconds
        let t = date.timeIntervalSince1970
        let floored = (t / step).rounded(.down) * step
        return Date(timeIntervalSince1970: floored)
    }

    /// 构造某一时次的**完整产品 URL**。
    ///
    /// - Parameters:
    ///   - stamp: 17 位 UTC 时戳。
    ///   - date: 用于推导 `{YYYY}/{MM}/{DD}` 的时刻（**须与 `stamp` 同源**）。
    /// - Returns: 完整 URL；时戳长度不对 → nil。
    static func productURL(stamp: String, date: Date,
                           calendar: Calendar = utcGregorian) -> URL? {
        guard stamp.count == stampDigits else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let mo = c.month, let d = c.day else { return nil }
        let path = productPathPrefix
            + pad4(y) + "/" + pad2(mo) + "/" + pad2(d) + "/"
            + categoryDirectory + "/"
            + sizeSegment + "/"
            + productNamePrefix + stamp + productNameSuffix
        return URL(string: siteRootURLString + path)
    }

    /// 构造某一时次的**完整产品 URL**（便捷重载：内部自算时戳）。
    static func productURL(forUTCDate date: Date) -> URL? {
        let aligned = alignedToFrame(now: date)
        let stamp = stamp(forUTCDate: aligned)
        return productURL(stamp: stamp, date: aligned)
    }

    /// 列出**回溯探测序列**的时戳（由新到旧，最多 `maxProbeFrames` 个）。
    ///
    /// - Parameters:
    ///   - now: 注入的「现在」（单测可固定）。
    ///   - limit: 取多少帧。
    /// - Returns: 时戳数组，长度 = `limit`（含第一个对齐帧）。
    static func probeStamps(now: Date, limit: Int = maxProbeFrames) -> [String] {
        let cap = max(0, min(limit, maxProbeFrames))
        guard cap > 0 else { return [] }
        let first = alignedToFrame(now: now)
        var out: [String] = []
        out.reserveCapacity(cap)
        for i in 0..<cap {
            let t = first.addingTimeInterval(-Double(i) * frameStepSeconds)
            out.append(stamp(forUTCDate: t))
        }
        return out
    }

    // MARK: - 私有

    /// 4 位补零。
    private static func pad4(_ value: Int) -> String {
        let s = String(value)
        return s.count >= 4 ? s : String(repeating: "0", count: 4 - s.count) + s
    }

    /// 2 位补零。
    private static func pad2(_ value: Int) -> String {
        let s = String(value)
        return s.count >= 2 ? s : "0" + s
    }
}

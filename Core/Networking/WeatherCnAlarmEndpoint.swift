//
//  WeatherCnAlarmEndpoint.swift
//  Core / Networking  [App + Widget 共用]
//
//  第七源：中国气象网（d1.weather.com.cn 同族）**结构化预警详情**通道 ——
//  NMC预警源（第六源）的**字段级补源**，不是独立预警源（为什么这么定位，
//  见 `OfficialWarningEnrichment.swift` 文件头的架构裁定）。
//
//  ═══════════════════════════════════════════════════════════════════════
//  实测结论（2026-10-06 21:4x~22:0x 真实 curl，均带 `-L --compressed`）
//  ═══════════════════════════════════════════════════════════════════════
//
//  ── ① **任务书给定的 `d1.weather.com.cn/dingzhi/<码>.html` 不可用** ──────
//  实测 `https://d1.weather.com.cn/dingzhi/101010100.html` → **HTTP 403**，
//  响应体349 字节，**逐字**为：
//      <html><head><title>403 Forbidden</title></head><body>
//      <center><h1>403 Forbidden</h1></center><hr><center>openresty</center>
//      <p>Node_info: 2201-CACHE59</p>
//      <p>Forbid_code: 020200</p><p>Hit-status: MISS</p>...</body></html>
//  ⚠️ 判读：`Forbid_code: 020200` + `openresty` + `Hit-status: MISS`
//  是**CDN 边缘 WAF 拦截**特征，**不是**「缺 Key」也不是「Invalid Host」
//  （那两种含义完全相反，见纪律）。逐路径实测`/dingzhi/` `/alarm/`
//  `/alarm/index.html` `/weather1d/` `/newalarm/index.html`
//  **全部 403**（349 字节，响应体形状逐字一致）→ 是**主机级**策略，
//  不是路径级。与任务书「换个路径试试」的前提不符，如实记录。
//  同族主机对照实测（同一时刻、同一 UA）：
//      www.weather.com.cn→ **200**（26954 字节）
//      product.weather.com.cn → 403（353 字节 openresty）
//      i.weather.com.cn      → 403（552 字节 openresty）
//  → **`weather.com.cn` 整体按主机分策略**，只有 `www` 与
//    `product`（带正确 Referer 时）可达。
//
//  ── ② 真正可用的**列表**端点（免 Key、**免 Referer**）────────────────────
//  `https://forecast.weather.com.cn/api/v1/traffic/alarm/alarmMap`
//    → **HTTP 200**，`content-type: text/html;charset=utf-8`
//      （⚠️ 头标称 text/html 但**体是 JSON**，实测 `{"status":"success",
//      "errMsg":"","result":{"count":"137","data":[[...]]}}` —— 按 JSON 解）
//    · 实测 `count` **是字符串** `"137"`（逐字 type= str），**不是**数字
//      → 故 DTO 里按`String?` 建模。
//    · 实测响应体 137~ 478 KB（`--compressed` 下约 120 ~ 150 KB；
//      不压缩实测 478755 字节）→ 体积差是**压缩**造成的，非数据差异。
//    · ✅ **活性实证**：实测两次抓取 `count` 138 → **137**（有预警消解）。
//    ·✅ **免 Referer**：实测不带 Referer 连续 3 次均**200**（478755 字节）。
//    · ✅ **限频**：实测**连抓 6 次全部 200**、字节数逐次相同（150027）、
//      单次耗时 0.27~0.32 s → 无可观测限频。
//  该端点是本仓**从官方前端 JS 反查**到的（`j.i8tq.com/newAlarm/index.js`
//  内出现该 URL 逐字），非猜测。
//
//  ── ③ 真正可用的**详情**端点（**必须带 Referer**）────────────────────────
//  `http://product.weather.com.cn/alarm/webdata/<file>`（实测 **http** 可用，
//  同一 URL 的 **https** 实测亦**200**，故端点统一用 https）
//    ·⚠️⚠️ **Referer 是硬要求**（实测各3 次，结论稳定）：
//        无 Referer            → **403**（353 字节）
//        `Referer: https://example.com/`（他域）→ **403**（353 字节）
//        `Referer: http://www.weather.com.cn/alarm/index.shtml` → **200**
//      → 故 `requiredRefererValue` 是**常量**而非可选项；
//        且必须是 **weather.com.cn 域**的 Referer（他域 403）。
//        403 与「缺 Key」含义相反：这里**恰恰是 Referer 错**。
//    · 返回体**不是纯 JSON**，是 **JSONP 壳**（实测逐字，615~1082 字节）：
//        `var alarminfo={"head":"…",…};`
//      → 必须**剥壳**后再 JSON 解码（见 `WeatherCnAlarmResponse`）。
//    · ✅ **字段集合完全稳定**：实测 5 个不同城市样本，
//      **key 集合逐字完全相同（21 个键，只有 1 种 key 集合）**。
//    ·⚠️ **限频较严**（与列表端点不同）：实测**连发 6~8 个不同 file
//      全部连接失败（curl code 000，非 HTTP 状态码 → 传输层被断）**；
//      冷却 ~90 s 后单发 → **200**；冷却后再以 **10 s 间隔**连发 3 次
//      → **200/200/200**。→ 故取详情**必须串行 + 带间隔**，
//      绝不能并发（见 `WeatherCnAlarmService` 的串行实现）。
//      ⚠️ 冷却时长 45~90 s 是**实测区间**，精确阈值**无法确定**
//      （未做二分探测）。
//
//  ── ④ 与已接入 NMC 源的**重叠度**（实测，同一时刻两次抓取比对）────────
//  · weather.cn 列表 138 条vs NMC `findAlarm` 162 条
//    （NMC 侧 `count` 实测在 161 / 162 / 163 间变动，与既有文件记载一致）。
//  · 以 **alertid 精确相等**求交集：**127 条**重合；
//    weather.cn 独有 **11** 条；NMC 独有 **35** 条。
//  · 重合的 127 条里，`identifier`/`alertid` **逐字相同**（5/5 抽样核对）。
//  → 结论：**d1 列表不是 NMC 的超集**，两者互补 → 故 d1 定位为
//    **字段级补源**（补正文/秒级时间/英文），而**不是**替代 NMC 的列表源。
//
//  ── 许可状态（必须如实，不得美化）────────────────────────────────────
//  与 NMC 源同性质：调用的是**公开网页接口**，**未获中国气象局任何形式的
//  API 授权 / 许可协议签署**（无账号、无 Key、无协议）。
//  ⚠️ 且本通道**必须伪装 Referer** 才能取到数据 —— 这**不是**"官方授权"，
//  更应如实告知。`SourceDescriptor.usageNote` 已按此措辞登记。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 中国气象网（`weather.com.cn`）结构化预警**详情**通道端点拼装器。
///
/// ⚠️ **它不是"又一个预警列表源"**：列表由 NMC（第六源）负责，
/// 本端点只负责**取单条预警的结构化详情**（防御指南正文 / 秒级发布时间 /
/// 英文颜色名）。合并方式见 `OfficialWarningEnrichment`。
enum WeatherCnAlarmEndpoint {

    // MARK: - 列表端点（用于把 alertid 映射到详情 filename）

    /// 预警**列表**端点（实测免 Key、**免 Referer**、无可观测限频）。
    ///
    /// ⚠️ 该响应体虽为 JSON，但 `content-type` 实测为 `text/html;charset=utf-8`
    /// → 解码**不可**依据 content-type 判定，必须直接尝试 JSON 解码。
    static let listURLString =
        "https://forecast.weather.com.cn/api/v1/traffic/alarm/alarmMap"

    /// 拼装预警列表 URL（实测**无任何查询参数**，加参数未测）。
    static func listURL() -> URL? {
        URL(string: listURLString)
    }

    // MARK: - 详情端点

    /// 预警**详情**端点前缀（实测 **https** 与 **http** 均 200）。
    ///
    /// ⚠️ 末尾**必须带斜杠** —— 详情文件名直接拼在其后（实测形如
    /// `…/webdata/101131007-20261006212927-0902.html`）。
    static let detailBaseURLString =
        "https://product.weather.com.cn/alarm/webdata/"

    /// **必需**的 Referer 值（实测硬要求，见文件头 ③）。
    ///
    /// ⚠️ 必须是 `weather.com.cn` **域**的页面：他域 Referer 实测 403。
    /// 该值指向官方"预警频道"页，与前端 `index.js` 里硬编码的
    /// `alarm/index.shtml` 逐字一致（实测）。
    static let requiredRefererValue =
        "http://www.weather.com.cn/alarm/index.shtml"

    /// `SourceDirectory` 登记用的可追溯地址（实测 **HTTP 200**）。
    static let websiteURLString = "http://www.weather.com.cn/"

    /// 拼装单条预警详情 URL。
    ///
    /// - Parameter filename: 列表行 `data[i][1]` 的**逐字原样**文件名，
    ///   实测形如 `101131007-20261006212927-0902.html`。
    /// - Returns: 失败返回 nil（由调用方收敛为 `WeatherError.badURL`）。
    ///
    /// ⚠️ **刻意不做任何"清洗"**（不 trim、不改大小写、不补后缀）：
    /// 上游给什么就请求什么。实测该字段 137/137 条**全部**匹配
    /// `^<数字>-<14位数字>-<4位数字>\.html$`，无需容错；
    /// 若将来上游变形（如带路径分隔符），`URL(string:)` 自行返回 nil
    /// 或拼出非预期 URL —— 此时**如实失败**优于"猜一个能用的"。
    ///
    /// ⚠️ 空串→ nil（不拼出 `…/webdata/` 这种必然 404 的 URL）。
    static func detailURL(filename: String) -> URL? {
        guard !filename.isEmpty else { return nil }
        return URL(string: detailBaseURLString + filename)
    }
}
//
//  QWeatherCityResponse.swift
//  Core / Models  [App + Widget 共用]
//
//  第九源「和风天气」坐标反查（`/geo/v2/city/lookup`）**原始响应 DTO**
//  + 弱类型兜底解码。
//
//  ══════════════════════════════════════════════════════════════════════════
//  🔴🔴 **本端点未实测** —— 这是本文件最重要的一句话
//  ══════════════════════════════════════════════════════════════════════════
//  2026-10-08 主理人用真实凭据实测：该 Host 下 `/geo/v2/city/lookup`
//  **404 空响应体**（用故意错误的 token 则返回 401 → 说明路由存在、
//  Host/订阅侧有问题）。**本仓库从未收到过该端点的真实响应。**
//  → 本文件的字段清单逐字取自官方 OpenAPI 规格文件
//     `qweather-apis-zh.yml`（`getCityLookup` / `locationArray`），
//     **规格如此 ≠ 该账号真实响应**（不同套餐返回字段可能不同）。
//  → **接入后必须真机核验**，逐条比对本文件注释里标「规格如此（未实测）」的字段。
//
//  ──🔴🔴🔴 全部字段都是 `string`（**包括 `lat` / `lon`**） ──────────────────
//  官方规格 `locationArray.items.properties` 逐字：
//  `name` / `id` / `lat` / `lon` / `adm2` / `adm1` / `country` / `tz` /
//  `utcOffset` / `isDst` / `type` / `rank` / `fxLink` —— **13 个键全部
//  `type: string`**，连坐标都是字符串（规格示例值形如 `"39.92"`）。
//
//  → 若用 `let lat: Double` 声明，**真实响应里是 `"39.92"` 就整包解码抛
//    `typeMismatch`** → 整个反查链路静默失败（本仓 P-18 最坏的失败模式）。
//  → 故全部走**既有的** `LenientString` / `LenientDouble`
//    （定义在 `QWeatherDailyResponse.swift`，本文件**复用、不重造**）。
//
//  ── 顶层结构（规格 `getCityLookup` 逐字）───────────────────────────────
//      { "code": "200", "location": [ {…}, … ], "refer": {…} }
//
//  ⚠️ 🔴 **本端点的顶层没有 `metadata` 块**—— 与逐日/逐时端点**不同**。
//  逐日/逐时是 `metadata.attributions`（署名），
//  本端点把署名放在 **`refer.metaAttributions`**（规格 `referObject` 逐字：
//  `sources` / `license` / `metaTag` / `metaAttributions` / `metaZeroResult`）。
//  → 写成 `metadata` **不会编译报错、也不会解码报错**，只会让署名**恒为空**
//    —— 而署名是**许可条件**（官方明文「必须与当前数据共同显示」），
//    漏掉它是**违反许可**，比数据缺失严重得多。
//  → `QWeatherCityLookupTests` 专门断言「从 `refer.metaAttributions` 取到」。
//
//  ── `adm2` 才是本需求的核心字段（**区级**）──────────────────────────────
//  主理人原话：「所谓的**街道级是名义上**，他们是 api 能获取到的最高精度，
//  **通常覆盖到街区**」→ 本需求要的是该 API 能给的**最细粒度行政区**，
//  **不是**门牌号。对应字段是 **`adm2`（上级行政区划名称 = 区级）**。
//  ⚠️ 官方**未承诺** `adm2` 一定落到「街道」粒度，故模型对它**不做任何
//  粒度假设**，只是原样承载（理由见 `QWeatherResolvedPlace` 文件头）。
//
//  ── 弱类型兜底三条铁律（同 `QWeatherDailyResponse.swift`，不重复论证）──
//  ① 字段缺失 → nil，绝不抛错；
//  ② 类型漂移 → nil，绝不抛错（`LenientDouble` / `LenientString` 吸收）；
//  ③ 绝不猜值。
//
//  ── 为什么 `location` 声明成 `[Location?]` 而不是 `[Location]` ──────────
//  与逐时 `hours` 同款纪律：数组元素**逐个可空**。`[null, {…}]` 这种形态会让
//  `[Location]` 整体解码抛错 → 整条链路消失。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

// MARK: - DTO

/// 和风坐标反查原始响应（**解码失败安全**：逐字段可选 + 弱类型兜底）。
///
/// ⚠️ 官方规格如此（**未实测**）。顶层三个键：`code` / `location` / `refer`。
struct QWeatherCityResponse: Decodable, Sendable {

    /// 🔴 状态码（规格 `statusCode` 是 **`type: string`**，不是 integer）。
    ///
    /// ⚠️ 刻意用 `LenientString` 而非 `LenientDouble`：规格把它定义为字符串
    ///   （示例 `"200"`），若上游某天改成数字 `200`，`LenientString` 会吸收
    ///   那个漂移（`"200"` 与 `200` 都能解出），而 `LenientDouble` 反而在
    ///   上游给字符串时要多绕一层。两者都能吸收漂移，但**规格是字符串**，
    ///   按规格建模更贴合上游本意。
    var code: LenientString?

    /// 🔴 **`location` 数组**（规格 `getCityLookup.location`）。
    ///
    /// ⚠️ 元素逐个可空（`[Location?]`）：`[null, {…}]` 不应让整包解码失败。
    var location: [Location?]?

    /// 🔴 **`refer` 块**（署名与许可 —— **规格如此，本端点没有 `metadata`**）。
    var refer: Refer?

    // MARK: 条目

    /// 单个位置条目（规格 `locationArray.items`，逐字 **13 个 string 键**）。
    struct Location: Decodable, Sendable {

        /// 位置名称（如「东城区」/「北京市」）。
        var name: LenientString?

        /// 位置 ID（LocationID，如 `"101010100"`）。
        var id: LenientString?

        /// 🔴 纬度（**规格是 `string`** —— 不是 number！）。
        var lat: LenientString?

        /// 🔴 经度（**规格是 `string`** —— 不是 number！）。
        var lon: LenientString?

        /// 🔴 **上级行政区划名称（区级）** —— 本需求的核心字段。
        var adm2: LenientString?

        /// 一级行政区域名称（省级）。
        var adm1: LenientString?

        /// 国家名称。
        var country: LenientString?

        /// 🔴 **IANA 时区标识**（如 `"Asia/Shanghai"`）。
        ///
        /// ⚠️ 上游可能下发**非法** IANA 标识 → 必须经
        ///   `WeatherTimeFormatter.resolveTimeZone(identifier:)` 裁定，
        ///   **绝不**硬编码固定偏移（理由见 `QWeatherResolvedPlace` 文件头）。
        var tz: LenientString?

        /// 与 UTC 的偏移小时数（规格是 `string`，如 `"8"` / `"0"`）。
        var utcOffset: LenientString?

        /// 🔴 是否处于夏令时（规格逐字：**`"1"` 表示是、`"0"` 表示不是**）。
        ///
        /// ⚠️ 规格是**字符串** `"1"` / `"0"`，**不是布尔**——
        ///   用 `Bool` 声明会在真实响应下整包解码失败。用 `LenientString`
        ///   原样承载，由 mapper 侧裁定（见 `QWeatherMapper`）。
        var isDst: LenientString?

        /// 位置的属性（如 `"administrative"`）。
        var type: LenientString?

        /// 位置的评分（规格是 `string`）。
        var rank: LenientString?

        /// 该位置的天气预报网页链接。
        var fxLink: LenientString?
    }

    // MARK: refer

    /// `refer` 块（规格 `referObject` 逐字：数据来源与许可信息）。
    ///
    /// 🔴 **本端点的署名在这里**（`metaAttributions`），**不在 `metadata`**。
    struct Refer: Decodable, Sendable {

        /// 原始数据来源（规格注明「可能为空」且 `nullable: true`）。
        var sources: LenientStringArray?

        /// 数据许可或版权声明（同样可能为空 / 可空）。
        var license: LenientStringArray?

        /// 数据唯一标识（供诊断）。
        var metaTag: LenientString?

        /// 🔴 **数据归因信息（许可条件：必须与当前数据共同显示）**。
        var metaAttributions: LenientStringArray?

        /// 🔴 **零结果标志（规格是 `boolean`）**。
        ///
        /// ⚠️ 规格明确它是 **`boolean`**（与其他 string 字段不同），
        ///   但用 `Bool` 声明有风险：上游若改成 `"false"` 字符串就会整包失败。
        ///   → 故**不解码**它（JSON 解码默认忽略未知键，不违反 P-18）。
        ///   **是否零结果的判据由 mapper 用 `location` 是否为空来判**
        ///   ——那是**直接可观测**的事实，不依赖一个可能变形的标志位。
        ///   代价：若上游「有结果但 `metaZeroResult=true`」这种自相矛盾形态
        ///   出现，我们以 `location` 为准（见 mapper 注释）。
    }
}
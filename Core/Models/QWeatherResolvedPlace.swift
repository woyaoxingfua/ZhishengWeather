//
//  QWeatherResolvedPlace.swift
//  Core / Models  [App + Widget 共用]
//
//  第九源「和风天气」坐标反查（`/geo/v2/city/lookup`）**领域模型**。
//
//  ══════════════════════════════════════════════════════════════════════════
//  🔴🔴 **本端点未实测** —— 2026-10-08 实测该 Host 下 `/geo/v2/city/lookup`
//  **404 空响应体**，本仓库**从未收到过该端点的真实响应**。
//  字段清单逐字取自官方 OpenAPI 规格（`getCityLookup` / `locationArray`），
//  **规格如此 ≠ 该账号真实响应**。接入后必须真机核验。
//  ══════════════════════════════════════════════════════════════════════════
//
//  ── 这个模型解决什么问题 ────────────────────────────────────────────────
//  此前遗留问题：「选择当前位置时只显示『当前位置』，不显示到底是哪里」。
//  本模型承载坐标反查回来的**行政区划层级信息**，让 UI 能显示
//  「北京市 · 东城区」这样的真实归属。
//
//  ── 🔴 精度纪律：「能拿到的最细粒度」，**不是**门牌号 ────────────────────
//  主理人原话：「所谓的**街道级是名义上**，他们是 api 能获取到的最高精度，
//  **通常覆盖到街区**」。
//  → 本模型**不去声称**任何精度等级，也**不**把 `adm2` 硬说成「街道」：
//  官方规格只写「上级行政区划名称」，**未承诺**粒度到街道。
//  → 字段名保持 `adm1` / `adm2` 这类**上游原名**，由UI 决定怎么措辞；
//    谁把它渲染成「街道级」谁就承担了那个未经证实的断言。
//
//  ── 🔴 为什么 `timeZoneIdentifier` 存**原始串**而不是 `TimeZone` ─────────
//  ① `TimeZone` 不可 `Codable` 往返（`Codable` 合成会失败），
//     而本仓模型惯例是 `Codable + Equatable + Sendable`；
//  ② 上游 `tz` **可能给非法 IANA 标识** → 解析失败必须在**一个可观测的
//     地方**发生，而不是在模型构造期静默变成 `.current`
//     （那样就分不清「上游给了什么」与「我们最终用了什么」）。
//  → 故：**存原始串**（可回查、可诊断），**解析**统一走既有的
//     `WeatherTimeFormatter.resolveTimeZone(identifier:)`，
//     它对nil / 非法标识一律回退 `.current`、**绝不崩、绝不硬编码 +8**。
//
//  ── 🔴🔴 坐标**必须可选、且来自字符串** ─────────────────────────────────
//  上游 `lat` / `lon` 是**字符串**（规格逐字）。若模型里写成非可选 `Double`
//  mapper 侧一旦漏掉解析就编译不过；更重要的是**别在上游给不出时编一个 0**——
//  `(0, 0)` 是几内亚湾，**看起来合法但完全错**。
//
//  ── 与快照的关系 ─────────────────────────────────────────────────────────
//  本模型**不在** `WeatherFieldKey` 域内 → 不进 `WeatherSnapshot` / 共享容器
//  → **Widget 载荷契约零改动**（同 `QWeatherDailyForecast` 的处境）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

// MARK: - 单个地点

/// 坐标反查得到的一个地点（**全字段可选**，P-18 防线）。
///
/// ⚠️ 官方规格如此（**未实测**）。字段名保持上游原名（`adm1` / `adm2` /
///   `tz` …），**不**擅自改造成「省 / 市 / 区」这类中文语义名 ——
///   上游的层级语义在不同国家**并不一致**（`adm1` 在多数国家是「一级行政区」，
///   但不等于「省」），擅自改名会把一个事实性问题变成命名误导。
struct QWeatherResolvedPlace: Codable, Equatable, Identifiable, Sendable {

    /// 序号（**由 mapper 按数组下标赋值**，非上游字段）。
    ///
    /// ⚠️ 它就是 `Identifiable` 的 `id`，**必须唯一**。
    ///   刻意**不用**上游 `id`（LocationID）当稳定标识：它**可能缺失**
    ///   （→ `ForEach` 拿到重复/全空 id 会静默错渲甚至崩）。
    ///   下标由 mapper 保证唯一且确定，沿用逐日/逐时的同一做法。
    var sequenceIndex: Int

    /// 位置名称（规格示例形如「东城区」）。上游已本地化，**不翻译**。
    var name: String?

    /// 🔴 **位置 ID（LocationID）**，如 `"101010100"`。可用于后续按 ID 查询。
    var locationID: String?

    /// 🔴 **区级行政区划名称**（上游键 `adm2`，规格描述「上级行政区划名称」）。
    ///
    /// ⚠️ **本需求的核心字段**：主理人要求的「能拿到的最细粒度行政区」
    ///   就落在这里。官方**未承诺**它是街道级，故**不做粒度假设**、原样承载。
    var adm2: String?

    /// 一级行政区域名称（上游键 `adm1`，规格描述「一级行政区域名称」）。
    var adm1: String?

    /// 国家名称。
    var country: String?

    /// 🔴 **IANA 时区原始标识**（上游键 `tz`，形如 `"Asia/Shanghai"`）。
    ///
    /// ⚠️ **存原始串，不存 `TimeZone`**：理由见文件头。
    ///   nil = 上游未下发（或非法串被 mapper 净化丢弃，见 mapper 注释）。
    var timeZoneIdentifier: String?

    /// 与 UTC 的偏移小时数（上游键 `utcOffset`，规格是字符串如 `"8"`）。
    ///
    /// ⚠️ **只作诊断展示**，**绝不**用于时区裁定 ——偏移量不含夏令时规则，
    ///   用它算时刻会在夏令时切换那天错一小时。时区裁定一律走
    ///   `timeZoneIdentifier` + `WeatherTimeFormatter.resolveTimeZone`。
    var utcOffset: String?

    /// 🔴 是否处于夏令时（上游键 `isDst`，规格逐字 `"1"`=是 / `"0"`=否）。
    ///
    /// ⚠️ 存**已裁定的 `Bool?`**：规格是字符串 `"1"`/`"0"`，
    ///   原始串形态由 mapper 转换；**无法判定时为 nil**（**不猜**）。
    var isDaylightSavingTime: Bool?

    /// 位置的属性（上游键 `type`，如 `"administrative"`）。原样保留，不建枚举。
    var placeType: String?

    /// 位置的评分（上游键 `rank`，规格是字符串）。原样保留（值域未逐字列出）。
    var rank: String?

    /// 该位置的天气预报网页链接（上游键 `fxLink`）。
    var webLink: String?

    /// 🔴 **纬度（来自上游的字符串）**。
    ///
    /// ⚠️ 上游 `lat` 是**字符串**；本字段**可选** ——
    ///   上游给不出或给的不是合法数字时为 `nil`，
    ///   **绝不**用 0 顶替（`0` 是几内亚湾，一个看起来合法但完全错的值）。
    var latitude: Double?

    /// 🔴 **经度（来自上游的字符串）**。同 `latitude`，**绝不**用 0 顶替。
    var longitude: Double?

    /// 稳定标识（= `sequenceIndex`，满足 `Identifiable`）。
    var id: Int { sequenceIndex }

    /// 🔴 **已裁定的时区**（供渲染层直接使用）。
    ///
    /// ⚠️ 刻意**做成计算属性**而不是存一个 `TimeZone`：
    ///   ① `TimeZone` 不可 `Codable` 往返，存它会让本模型的 `Codable` 合成失败
    ///     （CI 会报 `does not conform to protocol 'Decodable'`）；
    ///   ② 它**复用既有单一真源** `WeatherTimeFormatter.resolveTimeZone(identifier:)`
    ///     ——`nil` / 非法标识 → **回退设备当前时区**，
    ///     **绝不崩、绝不硬编码 +08:00**。
    ///
    /// ⚠️ **计算属性不参与 `Codable`**：它每次现算，不占存储，
    ///   也就不可能与存储的 `timeZoneIdentifier` 不一致。
    var resolvedTimeZone: TimeZone {
        WeatherTimeFormatter.resolveTimeZone(identifier: timeZoneIdentifier)
    }

    /// 无任何可用字段的空值（供 mapper 的「缺块」回落路径使用）。
    static let empty = QWeatherResolvedPlace(sequenceIndex: 0,
                                              name: nil,
                                              locationID: nil,
                                              adm2: nil,
                                              adm1: nil,
                                              country: nil,
                                              timeZoneIdentifier: nil,
                                              utcOffset: nil,
                                              isDaylightSavingTime: nil,
                                              placeType: nil,
                                              rank: nil,
                                              webLink: nil,
                                              latitude: nil,
                                              longitude: nil)
}

// MARK: - 顶层

/// 一次坐标反查的完整领域模型。
struct QWeatherResolvedPlaces: Codable, Equatable, Sendable {

    /// 🔴 **署名（许可条件，非可选）**。
    ///
    /// 和风官方明文：`refer.metaAttributions` **必须与当前数据共同显示**。
    /// → 缺省为 `[]`（不是 nil）：**「上游没给署名」与「有署名却没解出来」**
    ///   必须可区分 ——前者要如实告知「上游未提供」，后者是缺陷。
    /// ⚠️ 本端点的署名**只在 `refer.metaAttributions`**（规格逐字），
    ///   **没有 `metadata` 块** —— 详见 `QWeatherCityResponse` 文件头。
    var attributions: [String]

    /// 响应状态码（上游键 `code`，规格是**字符串**如 `"200"`）。仅供诊断。
    var statusCode: String?

    /// 地点序列（上游键 `location`）。空数组 = 上游没给任何地点。
    var places: [QWeatherResolvedPlace]

    /// **实质无数据**判定：地点序列为空。
    ///
    /// ⚠️ 判据只问「有没有地点」，**不**问「字段填得满不满」——
    ///    一个条目里字段几乎全缺，**仍是上游下发的一个地点**，应如实展示
    ///   （各项显示「暂无」）。反之（0 个）才是真的查不到。
    ///
    /// 🔴 「查不到」与「取不到」**必须可区分**（本仓纪律）：
    ///   · 空数组 = **查了，没有**（`.noData`）——
    ///     用户该知道「这个坐标上游没有对应行政区」；
    ///   · 请求失败 = **取不到**（`.unavailable`）—— 该查网络/凭据。
    ///   把两者混同，用户会去查网络，而问题在上游数据。
    var isEffectivelyEmpty: Bool {
        places.isEmpty
    }

    /// **最细粒度的单个地点**（上游返回多个时取第一个）。
    ///
    /// ⚠️ **刻意不做「按 `adm2` 非空排序」**：官方**未承诺**返回顺序的含义
    ///   （`rank` 字段的存在暗示有排序，但规格未逐字定义排序规则），
    ///   擅自重排就是在编造一个未经证实的语义。
    ///   → 沿用上游顺序，`nil`（空序列时）由调用方收敛为「查不到」。
    var mostGranular: QWeatherResolvedPlace? {
        places.first
    }

    /// 无任何数据的空值（供 mapper 的「缺块」回落路径使用）。
    static let empty = QWeatherResolvedPlaces(attributions: [], statusCode: nil, places: [])
}
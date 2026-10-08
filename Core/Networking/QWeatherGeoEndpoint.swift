//
//  QWeatherGeoEndpoint.swift
//  Core / Networking  [App + Widget 共用]
//
//  第九源「和风天气」**坐标反查**端点（`/geo/v2/city/lookup`）请求 URL 拼装。
//
//  ══════════════════════════════════════════════════════════════════════════
//  🔴🔴🔴 **本端点未实测 —— 2026-10-08 用真实凭据实测该 Host 下不可用**
//  ══════════════════════════════════════════════════════════════════════════
//  实测记录（主理人 2026-10-08，Host `n959fbnwar.re.qweatherapi.com`）：
//  · `/weather/v1/*` 与 `/geo/v2/city/lookup` **全部 404 空响应体**；
//  · 用**故意错误**的 token 请求 `city/lookup` 返回 **401**，而同一坏token
//    请求 `/weather/v1/hourly` 返回 **404**
//    → 说明**路由存在**（会做鉴权），但 Host / 订阅侧有问题。
//  ⇒ **本文件的 URL 形态与字段名来自官方 OpenAPI 规格文件逐字核实，
//     但真机行为（能否 200、字段是否逐字如此）未经验证。**
//     Host 恢复后必须真机核验（逐条对照本文件与 `QWeatherCityResponse.swift`
//     的字段注释）。**在此之前，本链路的所有断言都只是「规格如此」，
//     不是「实测如此」。**
//
//  ── 🔴🔴 坐标顺序是「**经度,纬度**」，与本仓天气端点**完全相反** ─────────
//  官方规格 `locationQuery` 逐字：
//    > 需要查询地区的名称、[LocationID]或以英文逗号分隔的**[经度,纬度]坐标**
//    > 例如 `location=101010100` 或 `location=116.41,39.92`
//
//  而本仓天气端点 `/weather/v1/daily/{lat}/{lon}` 是**纬度在前**。
//  → **同一个仓库里两个和风端点的坐标顺序是相反的**，写错**不会编译报错**，
//    只会让服务端拿 39.92° 当经度去查 → 返回一个**看起来合法但完全错**的
//    地点（北京 vs 几内亚湾），是本仓最隐蔽的错误类型之一。
//  → `QWeatherCityLookupTests` 用`URLComponents` 解出query 逐字断言
//    `location == "116.41,39.92"` 把这一点钉死。
//
//  ── 为什么单独一个文件（而不是并进 `QWeatherEndpoint`）────────────────────
//  ① 形状不同：天气端点坐标在**路径段**（`{lat}/{lon}`），本端点在**查询串**
//     （`location={lon},{lat}`）→ 强行并进去就得给共用的私有 `url(...)`
//     加一个「坐标放哪」的开关参数，那会让两条链路的差异藏进参数里
//     ——**参数藏差异 = 差异迟早被改错**（本仓已在逐日/逐时上吃过这个亏）。
//  ② 复用仍在：**Host 规范化**（`QWeatherEndpoint.normalizeHost`）与
//     **坐标校验 + 定点格式化**（`QWeatherEndpoint.validatedCoordinateTexts`）
//     都是**直接调用**既有实现，**没有第二份**。小数位数沿用既有
//     `QWeatherEndpoint.coordinateDecimalPlaces`（2 位）。
//
//  ── 量纲纪律 ────────────────────────────────────────────────────────────
//  · 坐标**最多两位小数**（官方文档明确）→ 直接复用既有定点格式化；
//  · `number`（返回条数）合法域 **1–20**，默认 **10**（官方规格逐字）
//    → 越界返回 `nil`，**绝不**静默改成 10（理由同 `daysRange`/`hoursRange`）。
//
//  🔴 凭据纪律：本文件**只拼 URL**，**不读任何凭据**（SC-42a）。
//  API Host 由调用方（App 层）注入 —— 它因账号而异，仓库内无从得知。
//
//  Core 纪律：仅 import Foundation；禁 UIKit /内部 Date() / try! / fatalError。
//

import Foundation

/// 和风天气**坐标反查**（GeoAPI city lookup）请求地址拼装器。
enum QWeatherGeoEndpoint {

    // MARK: - 常量

    /// 城市反查端点的路径（官方规格逐字 `/geo/v2/city/lookup`）。
    static let cityLookupPath = "/geo/v2/city/lookup"

    /// 默认返回条数（官方规格：`number` 默认 10）。
    static let defaultNumber = 10

    /// 🔴 `number` 的合法区间（官方规格逐字：**`1-20`**，默认 10）。
    ///
    /// ⚠️ 与 `daysRange` / `hoursRange` 同款纪律：**越界 → nil**
    ///   （收敛为 `badURL`），**绝不**静默改成 10。
    ///   静默改成一个「看起来对但完全错」的条数，比明确报错坏得多。
    static let numberRange = 1...20

    /// 官方文档给出的默认语言（简体中文 `zh`）。
    ///
    /// ⚠️ 沿用 `QWeatherEndpoint.defaultLanguage` 的取值（同样是 `zh`），
    ///   但**刻意重声明**而非引用：Geo 端点与天气端点的 `lang` 是
    ///   **两个独立参数**，共用一个常量会让「改一个，另一个跟着变」。
    static let defaultLanguage = "zh"

    // MARK: - URL 拼装

    /// 坐标反查 URL 拼装。
    ///
    /// 🔴 **坐标顺序：经度在前、纬度在后**（官方规格逐字，与天气端点相反）。
    ///   理由与实测记录见文件头。
    ///
    /// - Parameters:
    ///   - apiHost: **控制台分配的专属 API Host**（形如 `xxxxxx.qweatherapi.com`，
    ///     可带或不带 `https://`；带路径 / 带尾斜杠都会被
    ///     `QWeatherEndpoint.normalizeHost` 规范化）。
    ///     ⚠️ **必须由调用方注入** —— 它因账号而异（硬编码即编造，P-24）。
    ///   - latitude: 纬度（WGS84）。
    ///   - longitude: 经度（WGS84）。
    ///   - number: 返回条数，**必须落在 `1...20`**（越界 → `nil`）。
    ///   - language: 语言代码（`zh` / `en` 等）；nil 或空串 → 不下发该参数。
    /// - Returns: 拼装好的 URL；Host 非法 / 坐标非法 / 条数越界 → `nil`。
    static func cityLookupURL(apiHost: String,
                              latitude: Double,
                              longitude: Double,
                              number: Int = defaultNumber,
                              language: String? = defaultLanguage) -> URL? {
        // ① Host 规范化（**复用既有单一真源**，不写第二份）。
        guard let normalizedHost = QWeatherEndpoint.normalizeHost(apiHost) else { return nil }

        // ② 条数校验：越界 → nil，**绝不**静默改成 10。
        guard numberRange.contains(number) else { return nil }

        // ③ 坐标校验 + 定点格式化（**复用既有单一真源**：拒绝 NaN/±∞/越界，
        //    并按官方约定四舍五入到 2 位小数、locale 无关）。
        guard let coordinates = QWeatherEndpoint.validatedCoordinateTexts(
            latitude: latitude, longitude: longitude) else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = normalizedHost
        components.path = cityLookupPath

        // ④ 🔴🔴 查询参数 `location` = **「经度,纬度」**（经度在前！）。
        //    官方规格示例逐字是 `location=116.41,39.92`。
        //    ⚠️ 逗号会被 `URLComponents` 正确百分号编码进查询串吗？
        //    `URLQueryItem` 的 value 走 query 允许字符集，`,` 属合法字符，
        //    因此**不会**被编码成 `%2C`，服务端能原样收到逗号。
        var items = [
            URLQueryItem(name: "location",
                         value: coordinates.longitude + "," + coordinates.latitude),
            URLQueryItem(name: "number", value: String(number))
        ]
        if let language, !language.isEmpty {
            items.append(URLQueryItem(name: "lang", value: language))
        }
        // ⚠️ 空数组置nil 的纪律与天气端点一致（见 `QWeatherEndpoint.url`）。
        components.queryItems = items.isEmpty ? nil : items

        return components.url
    }
}
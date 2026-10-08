//
//  QWeatherEndpoint.swift
//  Core / Networking  [App + Widget 共用]
//
//  第九源「和风天气」请求 URL 拼装（**需 Key**：JWT + 控制台专属 API Host）。
//
//  ══════════════════════════════════════════════════════════════════════════
//  ✅ 本文件端点形态**已实测**（主理人 2026-10-08，用真实凭据打通）：
//     · 不带 Authorization → **HTTP 401**（证明专属 Host + 路径正确）；
//     · 带正确 JWT（Ed25519 签名）→ **HTTP 200**，返回 gzip JSON；
//     · `daily?days=3` 实测 200，`astro`(15 键) / `daytime`(10 键) 结构
//       与官方文档**逐字一致**；
//     · 实测 `humidity` / `cloudCover` / `precipitation.probability` 确为
//       **`[0,1]`**（实测 `0.32` / `0` / `0`，**不是** 0–100）。
//     · 实况端点逐字为 **`/weather/v1/current`**（**不是** `/now/`），
//       实测 200，`condition` 等字段在**顶层**、**无** `now` 包装层。
//  🔴 但**凭据本身不入库**：API Host / Project ID / Credential ID / 私钥
//     由用户自备并在App 侧配置，仓库内**只有形态与解析**，没有秘密。
//  ══════════════════════════════════════════════════════════════════════════
//
//  ── 🔴 为什么 **API Host 必须外部注入、绝不硬编码** ─────────────────────
//  和风给每个账号分配一个**专属 API Host**，形如
//  `https://<你的Host>.qweatherapi.com`。它**因账号而异**
//  → **硬编码就是编造**（P-24），且会把开发者的凭据写进公开仓库。
//  故本文件的所有 URL 拼装都**要求调用方传入 Host**，
//  缺失时返回 `nil` → 上层收敛为「未配置 API 凭据」，**绝不含糊成网络错误**。
//
//  ── 🔴 认证方式已改版，**网上老博客全部过时** ─────────────────────────
//  老写法（大量博客在用）：`https://devapi.qweather.com/v7/weather/3d/...
//  ?key=<KEY>` —— ⚠️ **主理人实测 `devapi.qweather.com` → HTTP 403 Invalid Host**
//  （**带Key 也403**，是主机名问题，不是鉴权问题）。**不要照抄。**
//  官方现行方式：**JWT（Ed25519 数字签名）+ 控制台分配的专属 API Host**，
//  端点形如 `/weather/v1/daily/{lat}/{lon}?days=7`（**注意是 `v1` 不是 `v7`**），
//  认证头 `Authorization: Bearer <JWT>`。
//
//  ── ⚠️ 端点清单 ────────────────────────────────────────────────────────
//  · `/weather/v1/daily/{lat}/{lon}?days=7`← **已接入**（逐日）
//  · `/weather/v1/hourly/{lat}/{lon}?hours=24`  ← **已接入**（逐时，实测 200）
//  · `/weather/v1/current/{lat}/{lon}`      ← **未接入**（常量已按实测更正）
//    故 `SourceCapability` 只声明 `.qWeatherDailyForecast` 与
//    `.qWeatherHourlyForecast`，**不**声明 `.currentObservation`
//    （**未接即不声明**，见该文件注释）。
//  · `/geo/v2/city/lookup?location={lon},{lat}` ← **已接入**（端点与解析）
//    拼装在**独立文件** `QWeatherGeoEndpoint.swift`（形状不同：坐标走**查询串**
//    且是「经度在前」，与天气端点的「路径 `lat/lon`」不是同一套），
//    但 Host 规范化与坐标校验/定点格式化**复用本文件的单一真源**
//    （`normalizeHost` / `validatedCoordinateTexts`）。
//
//  🔴🔴 **逐时的路径段是 `hourly`，但响应体顶层键逐字是 `hours`**（实测）。
//  这两个词不一样 —— 写错**不会编译报错**，只会让整源静默变成「无数据」
//  （P-18 最坏的失败模式）。`QWeatherHourlyTests` 用断言钉死。
//
//  ── 🔴 JWT token **必须缓存并按过期重签**（实测依据）────────────────────
//  官方 JWT 的 `exp` **最长 24 小时**（实测口径取 30 分钟更安全），
//  每次请求都重新签会白耗CPU；只签一次又会在过期后**全量401**。
//  → 必须「缓存 token + 到期时间，过期前重签」，见 `QWeatherTokenSigner`。
//
//  ── 量纲纪律：坐标**最多两位小数**（官方文档明确）─────────────────────
//  本文件按官方约定把经纬度**四舍五入到 2 位小数**再拼进路径：
//  ① 官方路径参数格式明确要求「最多两位小数」；
//  ② 超出位数可能被服务端判为非法参数 → 403/400；
//  ③ 天气要素的空间尺度远大于 0.01°（约 1.1 km），**多给位数是无效精度**。
//  ⚠️ 用`(value * 100).rounded() / 100` 而非 `String(format:)`：
//     后者受 locale 影响（小数点可能是逗号）→ 在某些系统区域设置下产出
//     `39,90` 这种**非法路径**。这是真实的跨区域设置事故，不是洁癖。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 和风天气请求地址拼装器（**API Host 由调用方注入**）。
enum QWeatherEndpoint {

    // MARK: - 常量

    /// 逐日预报的**路径前缀**（官方现行形态是 `/weather/v1/…`，**不是**老的 `/v7/…`）。
    static let dailyPathPrefix = "/weather/v1/daily"

    /// 实况的路径前缀。
    ///
    /// 🔴 **逐字为 `/weather/v1/current`，不是 `/weather/v1/now`** ——
    /// 主理人 2026-10-08 逐字核实官方文档 `dev.qweather.com/docs/api/weather/
    /// weather-current/`，并**真实请求实测 HTTP 200** 确认。
    /// （网上部分样例写 `/now/`，那是错的；写错会直接 404。）
    ///
    /// ⚠️ **仍未接入**（取数 actor 只做了逐日与逐时），仅登记常量以固定形态事实。
    static let currentPathPrefix = "/weather/v1/current"

    /// 逐时预报的**路径前缀**（实测 2026-10-09：带正确 JWT → **HTTP 200**）。
    ///
    /// 🔴 路径段是 `hourly`，但**响应体顶层键是 `hours`**（实测逐字）。
    /// 这两个词不一样，是本端点最容易写错的地方 —— 见
    /// `QWeatherHourlyResponse` 文件头。
    static let hourlyPathPrefix = "/weather/v1/hourly"

    /// 默认逐日天数（官方文档：`days` 默认 7）。
    static let defaultDays = 7

    /// 🔴 `days` 的合法区间（官方文档：**1–10**，默认 7）。
    ///
    /// ⚠️ 显式钉住上下界的原因（与 `FloodEndpoint.forecastDays` 同款纪律）：
    /// 一是官方文档明确写了 1–10；二是越界极可能被服务端判非法。
    /// → `url(...)` 对越界值**返回 nil**（收敛为 `badURL`），
    ///   **绝不**静默改成 7 或 10（那会让用户以为自己看的是 7 天）。
    static let daysRange = 1...10

    /// 默认逐时小时数（**24**）。
    ///
    /// 🔴 为什么是 24 而不是官方上限：本仓是**主屏卡片**，
    /// 24 小时恰好覆盖「今天剩余 + 明天」这一最常用视界；
    /// 且逐时条目最密，240 条会显著拖慢渲染与首屏。
    /// 这是**产品取舍**，不是协议上限 —— 上限见 `hoursRange`。
    static let defaultHours = 24

    /// 🔴 `hours` 的合法区间（官方文档：**`1-240`**）。
    ///
    /// ⚠️ 与 `daysRange` 同款纪律：**越界 → nil**（收敛为 `badURL`），
    ///   **绝不**静默改成 24。那会让用户以为看的是 24 小时，
    ///   实际请求了别的小时数 —— 一个**看起来对但完全错**的结果，
    ///   比明确报错坏得多。
    ///
    /// 🔴🔴 **2026-10-08 更正：此前本常量错写为 `1...360`，且被测试钉死。**
    ///   官方文档逐字（`dev.qweather.com/docs/api/weather/weather-hourly-forecast/`
    ///   参数节，本轮**重新查官方文档核实**）：
    ///   > `hours` integer 预报小时数，支持 **`1-240`** 小时，默认返回 `24` 小时
    ///   > 页面标题亦逐字写「获取…每小时天气预报，**最多 240 小时**」
    ///   → 360 会让服务端报错或截断，而 `QWeatherHourlyTests` 曾断言 `upperBound == 360`，
    ///   **测试因此永远"绿"** —— 一个被测试背书的错误事实。
    ///   这也是本仓「**有测试 ≠ 事实正确**」的又一例：测试只能钉住当时写下的值，
    ///   钉不住值本身对不对。
    static let hoursRange = 1...240

    /// 坐标小数位数（官方文档：**最多两位小数**）。
    static let coordinateDecimalPlaces = 2

    /// 官方文档给出的默认语言（简体中文 `zh`）。
    static let defaultLanguage = "zh"

    // MARK: - URL 拼装

    /// 逐日预报 URL 拼装。
    ///
    /// - Parameters:
    ///   - apiHost: **控制台分配的专属 API Host**（形如 `xxxxxx.qweatherapi.com`，
    ///     可带或不带 `https://` 前缀；带路径/带结尾斜杠都会被规范化）。
    ///     ⚠️ **必须由调用方注入** —— 它因账号而异，本仓库无账号故无从得知。
    ///   - latitude: 纬度（WGS84）。
    ///   - longitude: 经度（WGS84）。
    ///   - days: 逐日天数，**必须落在 `1...10`**（越界 → nil）。
    ///   - language: 语言代码（`zh` / `en` 等）；nil → 不下发该参数（用服务端默认）。
    /// - Returns: 拼装好的 URL；Host 非法 / 天数越界 / 坐标非法 → `nil`。
    static func dailyURL(apiHost: String,
                         latitude: Double,
                         longitude: Double,
                         days: Int = defaultDays,
                         language: String? = defaultLanguage) -> URL? {
        url(pathPrefix: dailyPathPrefix,
            apiHost: apiHost,
            latitude: latitude,
            longitude: longitude,
            queryItems: [
                URLQueryItem(name: "days", value: String(days))
            ],
            days: days,
            hours: nil,
            language: language)
    }

    /// 实况 URL 拼装（**仍未接线**，仅固定端点形态供后续接线）。
    ///
    /// ⚠️ **已实现但未接线** —— 这是**刻意**的：形状先钉死并可单测，
    /// 免得将来接线时才发现路径写错。`SourceCapability` 因此**不**声明
    /// `.currentObservation`（未接即不声明）。
    ///
    /// - Parameters:
    ///   - apiHost: 控制台专属 API Host（同 `dailyURL`）。
    ///   - latitude: 纬度（WGS84）。
    ///   - longitude: 经度（WGS84）。
    ///   - language: 语言代码；nil → 不下发该参数。
    /// - Returns: 拼装好的 URL；Host 非法 / 坐标非法 → `nil`。
    static func currentURL(apiHost: String,
                           latitude: Double,
                           longitude: Double,
                           language: String? = defaultLanguage) -> URL? {
        url(pathPrefix: currentPathPrefix,
            apiHost: apiHost,
            latitude: latitude,
            longitude: longitude,
            queryItems: [],
            days: nil,
            hours: nil,
            language: language)
    }

    /// 逐时预报 URL 拼装（**实测 2026-10-09**：`?hours=24` → HTTP 200）。
    ///
    /// - Parameters:
    ///   - apiHost: **控制台分配的专属 API Host**（同 `dailyURL`，因账号而异）。
    ///   - latitude: 纬度（WGS84）。
    ///   - longitude: 经度（WGS84）。
    ///   - hours: 逐时小时数，**必须落在 `1...240`**（官方上限 240）。
    ///     越界 → **nil**（收敛为 `badURL`），**绝不**静默改成 24。
    ///   - language: 语言代码；nil → 不下发该参数。
    /// - Returns: 拼装好的 URL；Host 非法 / 小时数越界 / 坐标非法 → `nil`。
    static func hourlyURL(apiHost: String,
                           latitude: Double,
                           longitude: Double,
                           hours: Int = defaultHours,
                           language: String? = defaultLanguage) -> URL? {
        url(pathPrefix: hourlyPathPrefix,
            apiHost: apiHost,
            latitude: latitude,
            longitude: longitude,
            queryItems: [
                URLQueryItem(name: "hours", value: String(hours))
            ],
            days: nil,
            hours: hours,
            language: language)
    }

    // MARK: - Private

    /// 通用 URL 拼装（逐日 / 实况 / 逐时共用同一条路径规则）。
    ///
    /// - Parameters:
    ///   - pathPrefix: 路径前缀（如 `/weather/v1/daily`）。
    ///   - apiHost: 控制台专属 Host。
    ///   - latitude: 纬度（WGS84）。
    ///   - longitude: 经度（WGS84）。
    ///   - queryItems: 额外查询参数。
    ///   - days: 逐日天数；`nil` = 该端点无此参数。非 nil 时**校验 `daysRange`**。
    ///   - hours: 逐时小时数；`nil` = 该端点无此参数。非 nil 时**校验 `hoursRange`**。
    ///   - language: 语言代码；nil → 不下发。
    /// - Returns: URL；任一前置校验不通过 → `nil`。
    private static func url(pathPrefix: String,
                            apiHost: String,
                            latitude: Double,
                            longitude: Double,
                            queryItems: [URLQueryItem],
                            days: Int?,
                            hours: Int?,
                            language: String?) -> URL? {
        // ① Host 必须能规范化成一个**带主机名**的 https URL。
        //⚠️ 刻意**只接受 https**：和风是 HTTPS-only，
        //    放行 http 会把Bearer Token 明文发出去（凭据泄露路径）。
        guard let normalizedHost = normalizeHost(apiHost) else { return nil }

        // ② 条数校验（仅当该端点有此参数时）。
        //    🔴 `days` 与 `hours` **各按各的合法域**校验，且**越界一律 nil**，
        //      绝不静默改成默认值（理由见两个 `*Range` 常量的注释）。
        if let days, !daysRange.contains(days) { return nil }
        if let hours, !hoursRange.contains(hours) { return nil }

        // ③ 坐标校验 + 定点格式化（**单一真源**：`validatedCoordinateTexts`，
        //    天气端点与 Geo 反查端点共用，见该函数注释）。
        //    ⚠️ NaN / ±∞ 会让 `String(...)` 产出 "nan" / "inf" → 拼进路径变成
        //    一个语法上"合法"但语义上荒谬的 URL，服务端会返回难以理解的错误。
        guard let coordinates = validatedCoordinateTexts(latitude: latitude,
                                                         longitude: longitude) else {
            return nil
        }
        let latText = coordinates.latitude
        let lonText = coordinates.longitude

        var components = URLComponents()
        components.scheme = "https"
        components.host = normalizedHost
        components.path = pathPrefix + "/" + latText + "/" + lonText

        var items = queryItems
        if let language, !language.isEmpty {
            items.append(URLQueryItem(name: "lang", value: language))
        }
        // ⚠️ `queryItems` 为空数组时**必须置 nil**：
        //    空数组会让 `components.url` 产出带裸 `?` 的 URL（`…/now/39.9/114.3?`），
        //    部分服务端对裸 `?` 处理不一致。
        components.queryItems = items.isEmpty ? nil : items

        return components.url
    }

    /// Host 规范化：容忍用户直接粘贴控制台里的原文（带 scheme / 带路径 / 带尾斜杠）。
    ///
    /// ⚠️ 为什么需要它：和风控制台展示的 Host 常带 `https://` 前缀，
    ///   而本文件内部以「裸主机名」拼装 → 不规范化就会得到
    ///   `https://https//xxxx.x.qweatherapi.com/…` 这种废串，
    ///   且**报错点极远**（表现为 403，与「Key 错」难以区分）。
    ///
    /// - Parameter raw: 用户/控制台给出的 Host 原文。
    /// - Returns: 裸主机名（小写）；无法解析或为空 → `nil`。
    static func normalizeHost(_ raw: String) -> String? {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        // 缺 scheme 时**补上** https（便于统一走 URLComponents 解析）。
        if !candidate.contains("://") {
            candidate = "https://" + candidate
        }
        guard let components = URLComponents(string: candidate),
              let host = components.host,
              !host.isEmpty else { return nil }
        //⚠️ 主机名不含空格 / 不含 "/"（后者说明粘贴了完整 URL 的路径段，
        //   那不是 Host）—— 宁可判为非法，也不要拼出一个必然 403 的地址。
        guard !host.contains(" "), !host.contains("/") else { return nil }
        // 🔴 只允许 https 语义：原串若显式写了 http → 判非法（凭据不得明文发送）。
        if let scheme = components.scheme, scheme.lowercased() != "https" { return nil }
        return host.lowercased()
    }

    /// 坐标 → 路径片段（**最多两位小数**，locale 无关）。
    ///
    /// ⚠️ 刻意**不用 `String(format:)`**：它受locale 影响，
    /// 在小数点为逗号的区域设置下会产出 `39,90` —— 一个**非法路径**
    /// （逗号是查询串分隔符）。这是真实的跨区域设置事故。
    ///
    /// - Parameter value: 原始坐标值。
    /// - Returns: 定点小数字符串（已去尾随 0）。
    static func coordinateText(_ value: Double) -> String {
        let scale = pow(10.0, Double(coordinateDecimalPlaces))
        let rounded = (value * scale).rounded() / scale
        // `String(describing:)` 对 Double 已是 locale 无关的 Swift 描述，
        // 且会自动省略尾随零（39.90 → "39.9"、39.00 → "39"），正合需要。
        return String(describing: rounded)
    }

    /// 坐标校验 + 定点格式化（**天气端点与 Geo 反查端点的单一真源**）。
    ///
    /// 🔴 **为什么抽出来**：Geo 反查端点（`/geo/v2/city/lookup`，见
    ///   `QWeatherGeoEndpoint`）也需要**完全相同**的两件事 —— 拒绝 NaN/±∞/
    ///   越界值，并把坐标按官方约定保留 2 位小数。两处各写一份的代价是
    ///   **悄悄漂移**（本仓已在别处吃过「两份鉴权处置各自演化」的亏）。
    ///   → 故只有这一份实现，天气端点与 Geo 端点都调它。
    ///
    /// ⚠️ 越界一律返回 `nil`（收敛为 `badURL`），**绝不**静默改成 0
    ///   ——把非法坐标改成 0 会得到「几内亚湾的天气」，一个**看起来成功
    ///   但完全错**的结果，比明确报错坏得多。
    ///
    /// - Parameters:
    ///   - latitude: 纬度（WGS84）。
    ///   - longitude: 经度（WGS84）。
    /// - Returns: 已按 2 位小数定点化的 (纬度文本, 经度文本)；非法 → `nil`。
    static func validatedCoordinateTexts(latitude: Double,
                                         longitude: Double) -> (latitude: String, longitude: String)? {
        guard latitude.isFinite, longitude.isFinite,
              (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude) else { return nil }
        return (coordinateText(latitude), coordinateText(longitude))
    }
}

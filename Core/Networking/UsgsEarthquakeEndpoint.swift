//
//  UsgsEarthquakeEndpoint.swift
//  Core / Networking  [App + Widget 共用]
//
//  第九源 USGS 地震请求 URL 拼装（`earthquake.usgs.gov`，FDSN Event Web Service，
//  **完全免 Key、免注册、零鉴权**）。
//
//  ═══════════════════════════════════════════════════════════════════════
//  实测基准：2026-10-08（主理人当次真实 curl 探针）
//  ═══════════════════════════════════════════════════════════════════════
//
//  ── 实测通过的「附近查询」参数组合（逐字）─────────────────────────────
//  ```
//  https://earthquake.usgs.gov/fdsnws/event/1/query
//    ?format=geojson
//    &latitude=39.9&longitude=116.4
//    &maxradiuskm=300
//    &minmagnitude=2.5
//    &starttime=2026-09-08
//    &orderby=time
//    &limit=20
//  ```
//  → **HTTP 200**（实测经代理）。
//
//  ── 为什么用**半径查询**而不是矩形查询 ──────────────────────────────────
//  FDSN 同时支持两种空间范围：
//  · 半径：`latitude` + `longitude` + `maxradiuskm`（圆心 + 半径）；
//  · 矩形：`minlatitude` / `maxlatitude` / `minlongitude` / `maxlongitude`。
//  本源取**半径**：`latitude` / `longitude` / `maxradiuskm`。
//  理由是**语义**而非参数个数：卡片的主题是「**附近**有感地震」，
//  圆形才对应「附近」；矩形会把对角线上的城市也算进来
//  （北京到广州的矩形里包含整个华北与华中，用户会看到「几千公里外的地震」
//  被标成「附近」—— 那是**内容错误**）。
//
//  ⚠️ `maxradiuskm` 的实测**上限是 20001 km**（本仓只用到 300，远在限内）。
//
//  ── ⚠️⚠️ **绝对不要依赖 `metadata.count`**（实测踩过的坑）────────────
//  `metadata` 里**加了 `limit` 之后就不再返回 `count` 字段**
//  （改为返回 `limit` / `offset`）。故：
//  · 本文件**不**请求 `count`；
//  · 单测**不得**断言 `metadata.count`；
//  · 判「有没有地震」一律用 **`features.count`**（`features` 为空数组是实测的常态形态：
//    北京 300km / 30 天 / M2.5+ 实测 `count = 0`，主理人已确认那是**真的没地震**，
//    不是参数写错）。
//
//  ── 参数取值的三条理由 ─────────────────────────────────────────────────
//  · `maxradiuskm = 300`：卡片是「**附近**」，300 km 约等于一个省的范围，
//    再远就不叫「附近」了；
//  · `minmagnitude = 2.5`：实测 M2.5 以下极少被主动上报，
//    拉进来只会让列表被微小远震刷屏（实测样本 M5.0 是常见量级）；
//  · `limit = 20`：上游**分页**上限足够大，实测 20 条足够覆盖 300km 内的活跃期；
//    ⚠️ 实测加了 `limit` 就没有 `count`（见上），故 20 是**展示条数上限**，
//    不是「只查了前 20 条然后宣称没有更多」——页脚会如实说明这一点。
//
//  ── 🔴 `starttime` **必须注入**（Core 层硬纪律）───────────────────────
//  Core 内**禁 `Date()`**（静态门禁 SC-11 会扫），
//  故 `startDate` 由 **App 层**取当前时间后**注入**，
//  格式化成 `yyyy-MM-dd`（**固定 locale / 固定 UTC 时区**，
//  否则设备区域设置会让非公历日历把日期格式化错——与
//  `NmcTyphoonMapper.utcMinuteFormatter` 同款纪律）。
//  → 单测可固定 `startDate` 逐字断言 URL。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// USGS 地震请求 URL 拼装器（免 Key、零鉴权）。
enum UsgsEarthquakeEndpoint {

    /// 基础地址（FDSN Event Web Service 的 GeoJSON 查询端点）。
    ///
    /// ⚠️ rawValue 与域名语义一致（`SourceID.usgsEarthquake = "usgs-earthquake"`）：
    /// USGS 的服务域名是 `earthquake.usgs.gov`（**不是** `usgs.gov` 主站，
    /// 主站上没有这个路径）。
    static let baseURLString = "https://earthquake.usgs.gov/fdsnws/event/1/query"

    /// `SourceDirectory` 登记用的官网地址（给用户看的可点入口）。
    static let websiteURLString = "https://earthquake.usgs.gov/"

    /// 响应格式（实测 `geojson` 返回 `{type, metadata, features[]}`）。
    static let responseFormat = "geojson"

    /// 「附近」的半径（**km**）。理由见文件头。
    static let radiusKm = 300.0

    /// 最低震级过滤。理由见文件头。
    ///
    /// ⚠️ 阈值是**展示口径**的一部分：它同时决定了「附近无地震」这句话的
    ///含义 —— 本源说的其实是「**300km 内没有 M2.5 以上的地震**」，
    /// 不是「300km 内任何震动都没有」。卡片文案**必须**带上这个限定
    /// （见 `EarthquakeCardModel` 与 `EarthquakeCard` 页脚）。
    static let minimumMagnitude = 2.5

    /// 最多取多少条（实测分页上限足够大；20 条足够覆盖活跃期）。
    static let resultLimit = 20

    /// 排序（实测 `time` = 时间倒序，最新在前）。
    ///
    /// ⚠️ **这是端点侧的排序，不是展示排序**：本卡片最终**按距离升序**展示
    /// （「离你最近的那次」才是用户问的问题），重排发生在 mapper（见其注释）。
    /// 两个排序都要存在、各司其职：端点排序决定**取哪20 条**，
    /// mapper 重排决定**怎么展示**。
    static let orderBy = "time"

    /// 依坐标与**注入的起始日期**拼装「附近查询」URL。
    ///
    /// - Parameters:
    ///   - latitude: 观测点纬度（WGS84；由调用方从既有真源取）。
    ///   - longitude: 观测点经度（WGS84）。
    ///   - startDate: 查询起始时刻（**注入**；Core 内不取时钟）。
    ///     取其**UTC 日期部分**作为 `starttime`。
    /// - Returns: URL；坐标非法（非有限值）或日期格式化失败 → nil
    ///   （由调用方收敛为 `WeatherError.badURL`）。
    static func url(latitude: Double, longitude: Double, startDate: Date) -> URL? {
        // 坐标守卫：非有限值直接拒（否则会拼出 `latitude=nan` 打到别的端点上）。
        guard latitude.isFinite, longitude.isFinite else { return nil }
        // 纬度取值域（±90）；超出即参数错误，宁可**不发请求**。
        guard latitude >= -90, latitude <= 90 else { return nil }
        guard longitude >= -180, longitude <= 180 else { return nil }

        guard let startText = Self.utcDayText(from: startDate) else { return nil }

        var components = URLComponents(string: baseURLString)
        components?.queryItems = [
            URLQueryItem(name: "format", value: responseFormat),
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            // ⚠️ 半径查询的三个参数**必须成组**出现，缺一半会退回全表查询。
            URLQueryItem(name: "maxradiuskm", value: String(radiusKm)),
            URLQueryItem(name: "minmagnitude", value: String(minimumMagnitude)),
            // 起始时刻**注入**（Core 不读 `Date()`，见文件头）。
            URLQueryItem(name: "starttime", value: startText),
            URLQueryItem(name: "orderby", value: orderBy),
            // ⚠️ 加了 `limit` 就没有 `metadata.count`（见文件头）——
            // 本仓**不**依赖那个字段，改用 `features.count`。
            URLQueryItem(name: "limit", value: String(resultLimit))
        ]
        return components?.url
    }

    // MARK: - Private

    /// `Date` → `yyyy-MM-dd`（**UTC**）。
    ///
    /// ⚠️ **固定 locale + 固定 UTC 时区**是硬要求：
    /// · locale 若跟随设备（部分区域用非公历日历），`yyyy` 会输出非公历年份；
    /// · 时区若跟随设备，取整日边界会随设备时区漂 ±1 天，
    ///   导致「近 30 天」变成「近 30 天 ± 1 天」—— 查询窗口与文案不符。
    /// （与 `NmcTyphoonMapper.utcMinuteFormatter` 完全同款纪律。）
    ///
    /// - Returns: 形如 `"2026-09-08"`；格式化失败 → nil。
    static func utcDayText(from date: Date) -> String? {
        utcDayFormatter.string(from: date)
    }

    /// `yyyy-MM-dd` UTC 格式化器（`static let` 只构造一次；formatter 本身不可变配置）。
    ///
    /// ⚠️ **诚实披露（非缺陷、但不是零风险）**：`DateFormatter` **非线程安全**，
    /// 而本实例是共享 `static let`。沿用本仓既有做法
    /// （`NmcTyphoonMapper.utcMinuteFormatter` 同款），理由是**调用面收敛**：
    /// `url(...)` 的**唯一**生产调用点是 `UsgsEarthquakeService`（一个 actor，
    /// 内部串行），单测里也是逐个串行 `await` 调用。
    /// 一旦将来出现「从多个隔离域并发调 `url(...)`」的用法，这里会变成数据竞争
    /// —— 届时的正解是改用 `actor` 包裹的 formatter 缓存或`Date.FormatStyle`，
    /// **不是**加锁（`NSLock` 会把纯函数变成阻塞点）。
    private static let utcDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
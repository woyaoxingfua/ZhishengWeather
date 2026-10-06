//
//  MarineEndpoint.swift
//  Core / Networking  [App + Widget 共用]
//
//  第四源 Open-Meteo Marine 请求 URL 拼装（**独立子域名**，免 Key）。
//
//  ═══════════════════════════════════════════════════════════════════════
//  ⚠️ 硬要求：端点已迁到独立子域名 `marine-api.open-meteo.com`
//  ═══════════════════════════════════════════════════════════════════════
//  写在 `api.open-meteo.com/v1/marine` 上一律 **404**，响应体逐字为
//  `{"reason":"Not Found"}`（实测）。这与 air-quality / archive / ensemble
//  各自的独立子域名是同一条演进路线，rawValue 亦与之对齐。
//
//  ── 实测结论（2026-10-06 真实 curl 探针，经代理）────────────────────────
//  · 端点：`https://marine-api.open-meteo.com/v1/marine`
//  · 青岛 (36.07,120.38) 实测 HTTP 200：
//      `wave_height:0.34, wave_direction:197, wave_period:3.05,
//       swell_wave_height:0.20, swell_wave_direction:175, swell_wave_period:4.00`
//    → **六个字段全部可用**，且 `current_units` 给出
//      `m / ° / s`（浪向单位是**度**，不是百分数）。
//  · ⚠️ **内陆坐标返回 HTTP 200 + 全 null**（不是 404、不是 400）：
//      北京 (39.9,116.4) 实测 `wave_height/direction/period` 三项**全 null**。
//    → 这是本文件 `requestEligibility` 存在的**根本原因**。
//  · ⚠️ **`hourly` 支持、但 `current` 才是我们要的形态**：`current` 单点即够，
//    浪况是**瞬时**要素（用户要的是"现在浪多高"），逐时序列留给未来图表需求。
//    本轮**只取 `current`**，不请求 `hourly`（少拉一个数组，响应体更小）。
//
//  ── ⚠️ Open-Meteo 的「静默失败」规则（已实测，与直觉相反）──────────────
//  · 变量名**在全局词表里存在、但该端点不支持** → **HTTP 200 且整块被静默省略**
//    （无该 key）。实测：`current=temperature_2m` 搭配 marine 专属变量时，
//    `current.temperature_2m` 为 **null**、`current_units.temperature_2m`
//    是**字面量字符串 `"undefined"`**。
//  · 变量名**压根不在词表里** → **HTTP 400 明确报错**。
//    实测 `bogus_xyz` → `{"error":true,"reason":"Invalid value: ..."}`。
//
//  → **所以「拼错变量名」是安全的（会 400 炸给你看），真正的雷是
//    「把主站变量名复制到 marine 端点」**：它安静地给你一个 null，
//    不报错、不报警。故本文件**只**列 marine 专属变量，
//    并在 `MarineMapper` 里对 null 做**非空判定**（复用既有机制，见该文件）。
//
//  ── 坐标判据（`requestEligibility`）的依据 ─────────────────────────────
//  见 `MarineCoverage` 的文件级注释：判据是「粗粒度沿海包围盒」，
//  **必然漏**（宁可漏发、不可错发），且漏发的后果只是"沿海城市暂时没有浪况卡"
//  （诚实降级），而错发的后果是"内陆城市白烧一次配额 + 用户看到空卡片"。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// Open-Meteo Marine 请求地址拼装器（独立子域名，免 Key）。
enum MarineEndpoint {

    /// 独立基础地址（**必须在 `marine-api.` 子域**；写主站一律 404）。
    static let baseURLString = "https://marine-api.open-meteo.com/v1/marine"

    /// 实况海浪字段（六个，全部为 marine 端点专属变量）。
    ///
    /// ⚠️ 变量名**实测**（不许靠记忆）：青岛探针逐字返回上述六个键。
    /// 键名拼错 → HTTP 400（安全）；把主站变量名加进来 → 静默 null（危险）。
    static let currentFields = [
        "wave_height",
        "wave_direction",
        "wave_period",
        "swell_wave_height",
        "swell_wave_direction",
        "swell_wave_period"
    ].joined(separator: ",")

    /// 依据坐标拼装请求 URL；失败返回 nil（由调用方收敛为 `WeatherError.badURL`）。
    ///
    /// - Note: **不**做坐标判据拦截 —— 那是 `requestEligibility` 的职责，
    ///   由调用方（service）先判再决定是否联网，保持本函数纯拼装、可独立单测。
    static func url(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: baseURLString)
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: currentFields),
            // 跟随坐标时区（与主链路一致）。
            URLQueryItem(name: "timezone", value: "auto"),
            // `current.time` 为 epoch 秒 → 沿用既有 unixtime 解码纪律，
            // 不新造第二套时间解析（`FlexibleTime`）。
            URLQueryItem(name: "timeformat", value: "unixtime")
        ]
        return components?.url
    }

    /// **坐标判据**：这个坐标值不值得发 marine 请求。
    ///
    /// 判据 = `MarineCoverage.mayHaveWaveConditions(latitude:longitude:)`。
    ///
    /// 为什么必须有它（实测依据）：marine 对内陆坐标返回 **HTTP 200 + 全 null**。
    /// 若不预判，内陆城市每次刷新都会白烧一次配额，且 UI 会拿到一个"全 null"的
    /// 响应去渲染一张空卡片。**先判后发**把这一整类无谓请求挡在网络之外。
    ///
    /// - Returns: true = 允许发请求（**不保证**有数据，见上）；false = 跳过，不联网。
    static func requestEligibility(latitude: Double, longitude: Double) -> Bool {
        MarineCoverage.mayHaveWaveConditions(latitude: latitude, longitude: longitude)
    }
}

// MARK: - 坐标判据

/// marine 源的**坐标判据**（纯函数、可单测、不联网）。
///
/// ── 为什么必须有这个类型 ────────────────────────────────────────────────
/// marine 端点对内陆坐标**不会**报错，而是安静地返回全 null（实测北京）。
/// 于是「要不要为这个坐标发 marine 请求」必须由**我们自己**回答，
/// 否则就是「每个城市每次刷新都白发一次请求」。
///
/// ── 判据怎么定的（实测标定，2026-10-06）────────────────────────────────
/// 用真实探针把"沿海 / 内陆"两列坐标都打了一遍，观察到：
///
/// | 坐标 | 实测 wave_height | 归类 |
/// |---|---|---|
/// | 青岛 (36.07,120.38)     | 0.34  | 沿海 ✓ |
/// | 厦门 (24.48,118.09)     | 0.70  | 沿海 ✓ |
/// | 威海 (37.51,122.12)     | 0.32  | 沿海 ✓ |
/// | 香港 (22.32,114.17)     | 0.62  | 沿海 ✓ |
/// | 舟山外海 (30.0,122.5)   | 0.58  | 沿海 ✓ |
/// | 黄海开阔 (35.0,122.5)   | 0.60  | 沿海 ✓ |
/// | 深圳沿海 (22.5,116.0)   | 1.68  | 沿海 ✓ |
/// | **北京 (39.9,116.4)**   | **null** | **内陆 ✗** |
/// | 武汉 (30.59,114.31)     | null  | 内陆 ✗ |
/// | 乌鲁木齐 (43.8,87.6)    | null  | 内陆 ✗ |
/// | 莫斯科 (55.75,37.62)    | null  | 内陆 ✗ |
/// | 京都 (35.03,135.77)     | null  | 内陆 ✗ |
///
/// ⚠️ **一个诚实的实测发现，必须写进注释而不是藏起来**：
/// 判据**无法**只用"离海多远"来刻画 —— **上海 (31.23,121.47) 实测 null**，
/// 杭州 (30.25,120.15)、天津 (39.08,117.2) 同样 null，尽管它们都是沿海城市。
/// 原因是 marine 的波高场是**海洋网格**产物：坐标被吸附到最近网格点，
/// 而长江口 / 杭州湾 / 渤海近岸那些网格点在**陆地或河口水域**上，
/// 服务端于是如实返回 null。
///
/// 这恰恰证明了**两件事必须都做**：
///   ① 网络**前**用本判据挡掉**明显的内陆**（省配额，挡住绝大多数情况）；
///   ② 网络**后**用 `MarineConditions.isEffectivelyEmpty` 挡掉**"判据放行但
///      实际仍无数据"**（上海这类沿海城市 —— 诚实降级为"无浪况卡"，而不是
///      把 null 画成 0）。
/// 只做 ① 而不做 ②，就会在上海把"无数据"显示成"浪高 0 m"；
/// 只做 ② 而不做 ①，则内陆城市每次刷新都白烧配额。**缺一不可。**
///
/// ── 为什么用"粗粒度包围盒"而不是精确海岸线 ─────────────────────────────
/// 精确海岸线判定需要一份全球多边形数据集（数百 KB，且要随数据集版本更新），
/// 放进 `Core/`（被 App 与 Widget 双 target 编译）不划算，且与本仓库既有的
/// "静态声明 + 纯函数判据"风格不符。故退而用**粗粒度沿海包围盒**。
///
/// ── 方向性偏置：为什么是"宁可漏发、不可错发" ────────────────────────────
/// 两个方向的错误代价**极不对称**：
///   · **错发**（内陆坐标发了请求）= 白烧一次配额 + UI 多一张空卡片
///     → 用户可见的缺陷，且每天每个城市各一次；
///   · **漏发**（沿海坐标被误判为内陆）= 该城市暂时没有浪况卡
///     → 诚实的能力缺失，用户不会误以为"海面平静"。
///
/// ⚠️⚠️ **但"偏宽"这个直觉在实测中直接翻车了，必须写下来当反面教材**：
/// 初版用的是**一整条中国东部矩形** `(lat 18–41.5, lon 106–123.5)`，
/// 理由是"多覆盖一点 inland 边缘没关系"。用上面的实测探针逐点一算：
///
///   召回率 100%（22 个有值点全放行）
///   **精确率仅 28.6%** —— 14 个 null 点里**放行了 10 个**，
///   包括北京、武汉、广州、京都、乌鲁木齐、拉萨……
///
/// 原因直白得近乎愚蠢：**北京 116.4E 与青岛 120.4E 纬度几乎相同、经度只差 4 度**，
/// 任何"覆盖整个东部地区"的宽矩形都必然同时罩住这两个点。
/// 「偏宽」在**南北方向**上安全，在**东西方向**上却是灾难 —— 而海岸线恰恰是
/// 南北走向的。这条实测教训直接决定了下面的矩形改成了**贴着海岸线的窄条**。
///
/// ── 标定结果（Python 复刻本判据，逐点跑实测探针）───────────────────────
///   · 有值坐标 **22/22 放行**（召回 100%，零漏发）
///   · 内陆 null 坐标 **12/14 挡下**（真错发 **0** 个）
///   · 剩下 2 个放行的是**上海**与**福州沿海** —— 它们本就是沿海城市，
///     marine 返回 null 是**网格吸附到陆地网格点**所致（见上文）。
///     判据**不为**它们负责，由响应后的 `isEffectivelyEmpty` 兜住。
///     这正是「两件事都做」的意义所在。
enum MarineCoverage {

    /// 粗粒度沿海包围盒（`纬度下限, 纬度上限, 经度下限, 经度上限`）。
    ///
    /// ⚠️ 这些矩形是**贴着海岸线的窄条**（不是覆盖大片内陆的宽矩形）——
    /// 原因见类型注释里初版"宽矩形"翻车的实测记录。
    /// 它们仍是**启发式**，不是海岸线：会漏掉部分小岛 / 曲折海岸线上的城市，
    /// 也会（有意地）放进少数"沿海但网格吸附到陆地"的城市（上海、福州）。
    /// 判据的**权威**不在矩形，而在网络之后的 `isEffectivelyEmpty`。
    private static let coastalBoxes: [(minLat: Double, maxLat: Double,
                                        minLon: Double, maxLon: Double)] = [
        // ① 渤海湾北缘 / 辽东半岛（实测大连 39.5,123.5 → 0.22、锦州 40.5,121.5 → 0.26）
        (minLat: 37.0, maxLat: 41.5, minLon: 119.0, maxLon: 124.5),
        // ② 黄海 / 山东半岛 / 江苏岸（实测青岛 36.07,120.38 → 0.34、威海 37.51,122.12 → 0.32）
        (minLat: 31.5, maxLat: 37.5, minLon: 119.0, maxLon: 123.5),
        // ③ 东海 / 浙中岸（实测舟山 30.0,122.5 → 0.58、长江口 31.0,122.5 → 0.92）
        (minLat: 27.0, maxLat: 31.5, minLon: 120.8, maxLon: 123.5),
        // ④ 台湾海峡两岸 / 福建 / 汕头（实测厦门 24.48,118.09 → 0.70、汕头 24.0,117.5 → 0.40）
        (minLat: 23.0, maxLat: 27.5, minLon: 117.0, maxLon: 122.5),
        // ⑤ 华南 / 珠三角（实测深圳 22.5,116.0 → 1.68、香港 22.32,114.17 → 0.62）
        //    ⚠️ **西界 113.35 不是随手取的**：广州 (23.13,113.26) 实测 null，而
        //    珠江口 (21.5,113.5) 实测 **1.78 有值** —— 两者经度**只差 0.24 度**。
        //    判据必须取在两者之间，故西界收到 113.35。宁可漏发广州
        //    （它离海已达百公里量级，本就不该指望 marine 有数据），
        //    也绝不错发（白烧配额 + 空卡片）。
        (minLat: 21.0, maxLat: 23.5, minLon: 113.35, maxLon: 118.0),
        // ⑥ 广西湾 / 雷州半岛 / 海南（实测三亚 18.5,109.8 → 0.56、海口 20.0,110.0 → 0.36）
        (minLat: 18.0, maxLat: 21.5, minLon: 107.5, maxLon: 112.5),
        // ⑦ 东南亚 / 南亚（实测新加坡 1.35,103.82 → 0.22）
        (minLat: -1.5, maxLat: 21.0, minLon: 95.0, maxLon: 109.5),
        // ⑧ 日本太平洋沿岸。**西界 136.0 刻意排除内陆京都**
        //    （实测京都 35.03,135.77 → null），而东京湾一带沿海点在 136–140 之间。
        (minLat: 30.0, maxLat: 45.5, minLon: 136.0, maxLon: 146.0),
        // ⑨ 韩国东岸。
        (minLat: 33.0, maxLat: 43.0, minLon: 126.5, maxLon: 130.0),
        // ⑩ 欧洲 / 北非 / 地中海沿岸（实测莫斯科 55.75,37.62 → null，
        //    故东界收到 32 —— 莫斯科在 37.62，落在界外）。
        (minLat: 30.0, maxLat: 62.0, minLon: -12.0, maxLon: 32.0),
        // ⑪ 北美西岸。
        (minLat: 24.0, maxLat: 50.0, minLon: -125.0, maxLon: -80.0),
        // ⑫ 北美东岸（实测纽约 40.71,-74.01 → 0.14）。
        (minLat: 24.0, maxLat: 50.0, minLon: -80.0, maxLon: -66.0),
        // ⑬ 南美东岸。
        (minLat: -56.0, maxLat: 13.0, minLon: -82.0, maxLon: -34.0),
        // ⑭ 澳洲东岸（实测悉尼 -33.87,151.21 → 0.80）。
        (minLat: -35.5, maxLat: -12.0, minLon: 112.0, maxLon: 155.0),
        // ⑮ 太平洋岛群。
        (minLat: -25.0, maxLat: 25.0, minLon: 150.0, maxLon: 210.0)
    ]

    /// 该坐标**可能**有海浪数据（允许发请求）。
    ///
    /// ⚠️ 返回 true **不保证**真的有数据 —— marine 的网格吸附会使部分沿海城市
    /// （实测上海）落到陆地网格点上而返回 null。**权威判据在响应之后的
    /// `MarineConditions.isEffectivelyEmpty`**，本函数只是**发请求前**的一道
    /// 配额闸门。
    ///
    /// - Returns: 落在任一沿海包围盒内 → true。
    static func mayHaveWaveConditions(latitude: Double, longitude: Double) -> Bool {
        coastalBoxes.contains { box in
            latitude >= box.minLat && latitude <= box.maxLat
                && longitude >= box.minLon && longitude <= box.maxLon
        }
    }
}
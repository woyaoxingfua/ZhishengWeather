//
//  UsgsEarthquakeResponse.swift
//  Core / Networking  [App + Widget 共用]
//
//  第九源 USGS 地震（FDSN Event Web Service，`earthquake.usgs.gov`）原始响应 DTO。
//
//  ═══════════════════════════════════════════════════════════════════════
//  实测基准：2026-10-08（主理人当次真实 curl 探针）
//  ═══════════════════════════════════════════════════════════════════════
//
//  ── 实测顶层形态 ───────────────────────────────────────────────────────
//  `{ "type": "FeatureCollection", "metadata": { … }, "features": [ … ] }`
//
//  ⚠️⚠️ **`metadata` 里没有 `count`**（本轮实测踩过的坑）：
//  端点**加了 `limit` 之后**，`metadata` 就不再返回 `count`，
//  改为返回 `limit` / `offset`。故本DTO**刻意不声明 `count`** ——
//  声明一个上游已不再返回的字段，会让「等它回来」变成对未来的臆测。
//  判「有没有地震」一律用 **`features.count`**（见 `EarthquakeMapper`）。
//
//  ── 实测单条 feature 形态（逐字）──────────────────────────────────────
//  ```json
//  {
//    "type": "Feature",
//    "properties": {
//      "mag": 5, "place": "92 km N of Ruteng, Indonesia",
//      "time": 1791434939943, "updated": 1791435696440,
//      "tz": null, "url": "https://earthquake.usgs.gov/earthquakes/feed/v1.0/detail/us6000kcd",
//      "detail": "…", "felt": null, "cdi": null, "mmi": null, "alert": null,
//      "status": "reviewed", "tsunami": 0, "sig": 594, "net": "us",
//      "code": "6000kcd", "ids": […], "sources": […], "types": null,
//      "nst": 88, "dmin": 0.51, "rms": 0.53, "gap": 88,
//      "magType": "mb", "type": "earthquake",
//      "title": "M 5.0 - 92 km N of Ruteng, Indonesia"
//    },
//    "geometry": { "type": "Point", "coordinates": [120.5395, -7.7761, 10] },
//    "id": "us6000kcd"
//  }
//  ```
//
//  ── ⚠️ `properties` 全部键（实测逐字，26 个）────────────────────────
//  `alert, cdi, code, detail, dmin, felt, gap, ids, mag, magType, mmi, net,`
//  `nst, place, rms, sig, sources, status, time, title, tsunami, type, types,`
//  `tz, updated, url`
//
//  ⚠️ **本DTO 只声明其中 8 个**（`mag` / `magType` / `place` / `time` / `felt` /
//  `alert` / `tsunami` / `url`）。**没声明的键由`JSONDecoder` 自动忽略**，
//  这不是遗漏，是本仓既有纪律「**无消费者不建模**」
//  （`dmin` / `rms` / `gap` / `nst` / `sig` 等是地震台网专业指标，
//  本App 没有消费者、也没有能力正确解释它们 —— 与其渲染成看不懂的数字，
//  不如不取）。
//
//  ──🔴 为什么**全部字段可选** ─────────────────────────────────────────
//  ① `mag` 实测可缺（领域模型 `EarthquakeEvent.magnitude` 是 `Double?`）；
//  ② `felt` 实测就是 `null`（**没人上报有感**是常态，不是缺测）；
//  ③ `alert` 实测就是 `null`（PAGER 只对有重大影响的地震触发，绝大多数事件没有）；
//  ④ `tsunami` 实测是 **0 / 1 整数**（不是布尔）——
//     实测样本逐字为 `0`，若声明成`Bool`，遇到整数 `1` 虽能解，
//     但**遇到上游若改成字符串就会整包失败**，故用 `Int?` 显式收窄再转；
//  ⑤ `coordinates` 实测恒为 3 元素 `[经度, 纬度, 深度]`，但**允许长度 < 3**
//     （深度缺测时上游会给 2 元素）→ mapper 按下标安全取，绝不越界。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// USGS 地震 GeoJSON 响应（解码失败安全：**全部字段可选**）。
struct UsgsEarthquakeResponse: Decodable, Sendable {

    /// 顶层 `metadata`。
    ///
    /// ⚠️ **刻意不声明 `count`**：实测端点**加了 `limit` 之后就不再返回该字段**
    /// （改为返回 `limit` / `offset`）。声明它等于对上游未来行为的臆测，
    /// 且会诱使后来者写出「断言 `metadata.count`」的测试 —— 那种测试必红，
    /// 且红的原因（字段根本不存在）完全不在错误信息里。
    /// 判「有没有地震」用 **`features.count`**（见 `EarthquakeMapper`）。
    struct Metadata: Decodable, Sendable {
        /// 实测存在（epoch 毫秒）；声明它只是为了**逐字反映**实测形态，
        /// 本App **不使用**（不用它去判断数据新鲜度——那是 UI 层该管的事）。
        var generated: Double?
        /// 实测加了 `limit` 后出现的分页字段。
        var limit: Int?
        /// 实测加了 `limit` 后出现的分页字段。
        var offset: Int?
    }

    /// 单条 feature 的 `properties`（实测 26 个键，此处只声明有消费者的 8 个）。
    struct Properties: Decodable, Sendable {
        /// 震级（**可空**：实测 `mag` 理论可缺；`null` = 上游未给出）。
        ///
        /// ⚠️ 绝**不**用 `mag ?? 0` ——那会把「没定级」渲染成「一场 M0.0 微震」。
        var mag: Double?
        /// 震级量表代号（实测 `mb` / `md` / `ml` / `mww` 等）。
        ///
        /// ⚠️ **必须保留**：不同量表测的不是同一个物理量，
        /// 混用会讲错震级（见 `EarthquakeEvent` 文件头的诚实警告）。
        var magType: String?
        /// 震中描述（实测英文，如 `"92 km N of Ruteng, Indonesia"`）。
        var place: String?
        /// 发生时刻（**Unix 毫秒**，实测 `1791434939943`）。
        var time: Double?
        /// 有感上报数（实测 `null` 是常态 —— 没人上报，不是缺测）。
        var felt: Double?
        /// PAGER 警报等级字符串（实测 `null` 是常态 —— 无 PAGER 产品）。
        var alert: String?
        /// 海啸相关标志（实测 **0 / 1 整数**，不是布尔）。
        var tsunami: Int?
        /// USGS 官方详情页地址（实测 `url` 字段，可点）。
        var url: String?
    }

    /// 单条 feature 的 `geometry`。
    ///
    /// ⚠️🔴 **坐标序：经度在前**（GeoJSON / RFC 7946 规范）。
    /// 实测逐字 `[120.5395, -7.7761, 10]` = [经度, 纬度, 深度(km)]。
    /// 写反的后果：事件**镜像到地球另一侧**，数值全部合法、
    /// **编译与运行都不报错** —— 只有看图才发现（与本仓台风源同款陷阱）。
    struct Geometry: Decodable, Sendable {
        /// 位置坐标数组：`[经度, 纬度, 深度(km)]`。
        ///
        /// ⚠️ **长度可能是 2**（深度缺测）→ mapper 按下标安全取，**绝不越界**。
        var coordinates: [Double]?
    }

    /// 单条地震事件（实测对应 GeoJSON 的一个 `feature`）。
    struct Feature: Decodable, Sendable {
        /// 该feature 的 `properties`（可能整个缺失）。
        var properties: Properties?
        /// 该 feature 的 `geometry`（可能整个缺失）。
        var geometry: Geometry?
        /// USGS 事件 id（实测形如 `us6000kcd`）。
        var id: String?
    }

    /// 顶层 `metadata`。
    var metadata: Metadata?
    /// 命中事件列表（实测**可能为空数组** —— 北京 300km/30天/M2.5+ 实测为 0 条，
    /// 那是**真的没地震**，是合法业务结果，不是故障）。
    var features: [Feature]?
}
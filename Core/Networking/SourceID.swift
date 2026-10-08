//
//  SourceID.swift
//  Core / Networking  [App + Widget 共用]
//
//  数据源稳定标识（字符串真源，禁散落字面量）。
//
//  ── T10 变更（ARCH-T10 §3.4）────────────────────────────────────────────────
//  由 `struct RawRepresentable` 改为 **`enum ... CaseIterable`**：
//  `SourceID.allCases` 由**编译器**保证完备 —— 新增源必须加 case，
//  **无法「忘记声明」**。这使「每个被声明的源都有目录条目」这条性质可被
//  机械守卫（`SourceCatalog.all` 与之求双射）钉死；漏登记会让该源
//  自动摘除**静默哑火**且设置页**隐身**（本仓库已存在的 `openMeteoAirQuality`
//  缺目录项就是现实样本）。
//
//  ⚠️ 迁移注意：`init?(rawValue:)` 现在是**可失败**的（enum 合成）。
//  `SourceHealthLedger` 反序列化历史键时对未知 rawValue **跳过该项**，
//  绝不造一个假 id（见该文件注释）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 数据源稳定标识（每个源一个 case；rawValue 即持久化 / 落盘用的稳定字符串）。
enum SourceID: String, CaseIterable, Sendable {

    /// 主天气源（Open-Meteo forecast，现状整体快照的来源）。
    case openMeteoForecast = "open-meteo-forecast"
    /// 空气质量源（Open-Meteo air-quality）。
    case openMeteoAirQuality = "open-meteo-air-quality"
    /// 第二源：日出日落（仅补 solarEvents 能力字段）。
    case sunriseSunset = "sunrise-sunset"
    /// 第三源：MET Norway（api.met.no locationforecast compact，免 Key）
    /// —— 仅补**基础数值字段**（温 / 压 / 湿 / 云 / 风），且是**不同的数值模式**
    /// （与 Open-Meteo 交叉校验才有意义）。
    case metNorwayForecast = "met-norway-forecast"
    /// 第四源：海浪（Open-Meteo Marine，`marine-api.open-meteo.com`，免 Key）——
    /// 仅补**海浪要素**（浪高 / 浪向 / 周期 / 涌浪），且**只在沿海坐标**才有数据。
    ///
    /// ⚠️ rawValue **必须与实际域名语义一致**：端点已从 `api.open-meteo.com`
    /// 迁到**独立子域名** `marine-api.open-meteo.com`，写在主站上一律 404
    /// （实测 `{"reason":"Not Found"}`）。故此处是 `open-meteo-marine`，
    /// **不是** `open-meteo-forecast` 的变体、也不是 `marine.open-meteo.com`。
    case marineForecast = "open-meteo-marine"
    /// 第五源：河道流量（Open-Meteo Flood，`flood-api.open-meteo.com`，免 Key）——
    /// 仅补**河道流量**（`river_discharge`，m³/s）。
    ///
    /// ⚠️ 同上：独立子域名，写在主站上 404。
    case floodForecast = "open-meteo-flood"
    /// 第六源：**官方气象预警**（中国气象局 NMC 预警信号公开接口，免 Key）
    /// —— 仅补**预警**能力（颜色等级 / 类型 / 行政区划 / 发布时间）。
    ///
    /// ⚠️ rawValue 用 `nmc-alarm`：与前五个源不同，本源**不是**数值预报，
    /// 而是**预警信号**本身（其余五家都是气象要素）。
    case nmcAlarm = "nmc-alarm"
    /// 第七源：**台风路径**（中央气象台台风网 `typhoon.nmc.cn`，免 Key、零鉴权）
    /// —— 仅补**台风路径与官方预报**能力（路径点 / 强度 / 风圈 / BABJ 预报）。
    ///
    /// ⚠️ rawValue 用 `nmc-typhoon`：与第六源 `nmc-alarm` **同域名不同服务**
    /// （`www.nmc.cn/rest/findAlarm` 是预警信号，本源是
    /// `typhoon.nmc.cn/weatherservice/typhoon/jsons/…` 的台风路径），
    /// 但二者是**完全不同的数据形态**（一个是预警条目，一个是路径点序列），
    /// 故**必须**是两个独立 SourceID —— 否则健康账本会把台风故障
    /// 记到预警源头上（两个源的失败域是独立的）。
    case nmcTyphoon = "nmc-typhoon"

    /// 第八源：**兜底源**（7timer!，`www.7timer.info/bin/api.pl`，免 Key、零鉴权）
    /// —— 仅补**能与主源精确对齐**的两个数值标量（2 米气温 / 修正海平面气压）
    /// 与**风向**，且被放在辅助链**末位**。
    ///
    /// ⚠️ **它为什么值得作为兜底（独立性实测结论，2026-10-07）**：
    /// · 域名完全独立：`www.7timer.info` vs `api.open-meteo.com`；
    /// · **服务端软件完全不同**：实测响应头 `Server: Apache/2.4.68 (Debian)`
    ///   （自建裸 Apache），Open-Meteo 侧**实测无 `Server` / 无 `cf-ray` 头**
    ///   → **不共享 Cloudflare 等任何 CDN**（这一点是兜底价值的前提）；
    /// · ⚠️ **但两家很可能同在 Hetzner 机房（AS24940，DE）** —— 本次**未用 whois
    ///   复核 ASN**，该归属为**推定**：实测 7timer `178.104.189.96`、
    ///   Open-Meteo `188.40.99.226`（2026-10-08；注意 Open-Meteo 的解析 IP 会变动，
    ///   连两次实测即可不同），二者**不同 /16 网段**但都落在 Hetzner 常用段。
    ///   → 疑似同一家机房/上游供应商，**不是完全隔离的故障域**（诚实披露）。
    ///
    /// ⚠️ **它不提供湿度 / 云量 / 风速**（不是漏接，是上游给的是**档位码**
    ///   不是物理量 —— 详见 `SevenTimerMapper` 文件头的逐字段诚实性对照表）。
    ///   声明了却拿不到会造成 EV-1 误摘，故 `requiredFields` 只有三个字段。
    ///
    /// ⚠️ rawValue 用 `7timer`（**不是** `7timer-info`）：与前七源「域名/服务名」
    ///   的命名口径一致，且这是本仓该源的稳定持久化键。
    case sevenTimer = "7timer"

    /// 第九源：**和风天气**（QWeather，**需 Key**：JWT + 控制台分配的专属 API Host）——
    /// 仅补**和风侧逐日预报**能力（逐日高低温 / 天气现象 / 昼夜分块 / 天文）。
    ///
    /// ⚠️ **rawValue 用 `qweather`**（与真实服务语义一致：官方品牌英文名 QWeather，
    ///   域名 `qweatherapi.com`）。**不是** `q-weather`、不是 `devapi-qweather`
    ///   ——那会把一个并不存在的主机名写进持久化键。
    ///
    /// ⚠️ **已实测（2026-10-08，主理人用真实凭据打通）**：先前记为「未实测（无 Key）」，
    ///   现已作废 —— 实测结论如下：
    ///   · 不带 `Authorization` → **HTTP 401**（证明专属 Host 与端点路径正确）；
    ///   · 带正确 JWT（Ed25519 签名）→ **HTTP 200**，返回 gzip JSON，
    ///     实况顶层结构与官方文档**逐字一致**（`condition` / `temperature` /
    ///     `humidity` / `wind` / `precipitation` / `pressure` / `visibility` /
    ///     `dewPoint` / `cloudCover` / `uvIndex`，**无** `now` 包装层）。
    ///   · 实测 `humidity = 0.32`、`cloudCover = 0` → **确认官方文档的 `[0,1]`
    ///     量纲正确**（不是 0–100），此点已在 `QWeatherMapper` 用断言钉死。
    ///   · `daily` 端点 `?days=3` 实测 200，`astro`(15 键) / `daytime`(10 键) 结构
    ///     亦与文档一致。
    ///   · 实测 Host 需代理（无代理时本机 HTTP 000）——**这是本机网络环境事实，
    ///     不等于 API 不可用**。
    ///
    /// ⚠️ **鉴权方式已改版，勿照抄老博客**：网上大量样例写的是老式
    ///   `https://devapi.qweather.com/v7/...?key=xxx`，**那套实测 403**。
    ///   官方现行方式是 **JWT（Ed25519 数字签名）+ 控制台分配的专属 API Host**，
    ///   形如 `https://<你的Host>.qweatherapi.com`，认证头 `Authorization: Bearer <JWT>`。
    case qWeather = "qweather"

    /// 第十源：**USGS 地震**（`earthquake.usgs.gov`，FDSN Event Web Service，
    /// **完全免 Key、免注册、零鉴权**）——提供「附近有感地震」。
    ///
    /// ⚠️ rawValue 用 `usgs-earthquake`：USGS 的服务域名是
    ///   `earthquake.usgs.gov`（**不是** `usgs.gov` 主站，主站上没有这个路径）。
    ///
    /// ⚠️ **本轮已完整实测（2026-10-08，主理人真实 curl）**：
    ///   · `.../event/1/query?format=geojson&latitude=&longitude=&maxradiuskm=
    ///     &minmagnitude=&starttime=&orderby=time&limit=` → **HTTP 200**；
    ///   · 半径查询（`latitude`+`longitude`+`maxradiuskm`）可用，语义上对应「附近」；
    ///   · **北京 300km / 30 天 / M2.5+ 实测返回 0 条**（另用 `/count` 端点交叉验证，
    ///     确认是**真的没地震**，不是参数写错）→ **「附近无地震」是常态而非故障**，
    ///     故状态机必须把 `.none`（查过了、没有）与 `.unavailable`（取不到）分开。
    ///   · 🔴 实测坑：`metadata` **加了 `limit` 后就不再返回 `count`**
    ///     （改为 `limit`/`offset`）→ 判有无地震一律用 `features.count`。
    ///
    /// 地震要素**不在 `WeatherFieldKey` 域内**（与 marine / flood 同处境），
    /// 故 `requiredFields: []` 诚实留空、`participatesInAutoExclusion: false`。
    case usgsEarthquake = "usgs-earthquake"
}

// MARK: - Codable

extension SourceID: Codable {

    /// 解码：接受**单值字符串**形态（enum 的惯用形态），
    /// 并**兼容旧 struct 的 keyed 容器**形态（`{"rawValue": "..."}`）。
    ///
    /// 为什么必须两种都收：本类型的旧定义是
    /// `struct SourceID: RawRepresentable, Codable { let rawValue: String }`，
    /// 其编码形态与 enum 的合成形态**可能不同**（合成 Codable 对单属性 struct
    /// 走 keyed 容器）。而 `SourcePreferences` 把用户「手动停用某源」的偏好
    /// 以 `Set<SourceID>` **落盘在 UserDefaults** —— 若只认一种形态，
    /// 升级后旧数据解不出来，`try?` 静默回落成空集合，用户的停用选择被**无声清空**。
    /// 双形态解码把这个静默行为变更彻底消除（写出去一律用单值形态）。
    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let raw = try? single.decode(String.self), let id = SourceID(rawValue: raw) {
            self = id
            return
        }
        // 兼容旧 keyed 形态。
        let keyed = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let raw = try keyed.decode(String.self, forKey: .rawValue)
        guard let id = SourceID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .rawValue,
                                                   in: keyed,
                                                   debugDescription: "未知的 SourceID rawValue: \(raw)")
        }
        self = id
    }

    /// 编码：一律写**单值字符串**（enum 的惯用形态）。
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// 旧形态（struct 合成 Codable）的键。
    private enum LegacyCodingKeys: String, CodingKey {
        case rawValue
    }
}

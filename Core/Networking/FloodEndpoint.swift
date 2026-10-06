//
//  FloodEndpoint.swift
//  Core / Networking  [App + Widget 共用]
//
//  第五源 Open-Meteo Flood 请求 URL 拼装（**独立子域名**，免 Key）。
//
//  ═══════════════════════════════════════════════════════════════════════
//  ⚠️ 硬要求：端点已迁到独立子域名 `flood-api.open-meteo.com`
//  ═══════════════════════════════════════════════════════════════════════
//  写在 `api.open-meteo.com/v1/flood` 上一律 **404**（实测 `{"reason":"Not Found"}`）。
//
//  ── 实测结论（2026-10-06 真实 curl 探针）──────────────────────────────
//  · 端点：`https://flood-api.open-meteo.com/v1/flood`
//  · 武汉 (30.6,114.3) 实测 HTTP 200，`daily.river_discharge`
//    逐日 92 天，`daily_units.river_discharge == "m³/s"`。
//  · ⚠️ **`river_discharge` 是「逐日」变量，不存在于 `hourly`**：
//    实测 `hourly=river_discharge` → **HTTP 400**
//    （`Invalid value: ... from invalid String value river_discharge`）。
//    故本端点**只请求 `daily`**。（`hourly` 本身是支持的 —— 实测
//    `hourly=wave_height` 在 marine 端点 200；这里 400 的原因是
//    **`river_discharge` 这个变量不属于 hourly 变量集**，不是 hourly 不可用。）
//  · 实测另有 `river_discharge_max`（**日最大流量**，同为 m³/s）可用。
//    本轮**不**映射它：能力声明只写了「河道流量」，多映射一个字段就会
//    让 `SourceDescriptor` 的能力声明与实际产出漂移（同 METNorway 的
//    "声明了却拿不到会误摘"纪律，此处是反向：拿得到却不声明）。
//    留待需要时按实测加。
//  · ⚠️ **默认窗口是 92 天**，实测逐日数组长 92。本端点用 `forecast_days`
//    **显式收窄**到 7 天：洪水预报的实际决策窗口就是未来一周，
//    拉 92 天既拖长响应体又让 UI 拿到一长串用不到的远期值。
//
//  ── ⚠️ 内陆坐标对 flood **照样有值**（与 marine 相反的实测结论）────────
//  实测：
//    · 北京 (39.9,116.4)   → `river_discharge:[5.07, 5.05, ...]` **有值**
//    · 拉萨 (29.65,91.1)   → `[0.24, 0.17, 0.15]` **有值**
//    · 乌鲁木齐 (43.8,87.6) → `[0.00, 0.00, 0.00]`（**有键、值为 0.00**）
//
//  → 所以 **flood 不做坐标判据**：河道流量对内陆城市同样有意义
//  （北京有永定河、武汉有长江），按"是否沿海"过滤会**错杀**真实数据。
//  这与 marine 形成对照，也说明「内陆 → 无数据」这条经验**只对 marine 成立**，
//  不可外推。
//
//  ⚠️ 注意乌鲁木齐那组 `0.00`：**它是有值的 0.00，不是 null**。
//  这正是"0 是合法读数、绝不与缺测混同"的那条纪律的现实用例 ——
//  若把它当成"无数据"而隐藏卡片，就是把一条真实读数（断流）说成"没查到"。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// Open-Meteo Flood 请求地址拼装器（独立子域名，免 Key）。
enum FloodEndpoint {

    /// 独立基础地址（**必须在 `flood-api.` 子域**；写主站一律 404）。
    static let baseURLString = "https://flood-api.open-meteo.com/v1/flood"

    /// 逐日字段（**只有 `river_discharge`**，单位 m³/s）。
    ///
    /// ⚠️ 变量名实测：放在 `daily` 下有效；放进 `hourly` 会 **HTTP 400**。
    static let dailyFields = ["river_discharge"].joined(separator: ",")

    /// 逐日预报天数（**显式**声明，理由见文件头：默认 92 天太宽）。
    ///
    /// 洪水预报的决策窗口就是未来一周；显式声明同时免疫服务端默认值变化。
    static let forecastDays = 7

    /// 依据坐标拼装请求 URL；失败返回 nil（由调用方收敛为 `WeatherError.badURL`）。
    static func url(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: baseURLString)
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "daily", value: dailyFields),
            // 显式钉住天数，免疫服务端默认窗口（实测默认 92 天）。
            URLQueryItem(name: "forecast_days", value: String(forecastDays)),
            // 跟随坐标时区（与主链路一致）：daily.time 随之是**当地零点**。
            URLQueryItem(name: "timezone", value: "auto"),
            // 逐日含时间数组 → 声明 epoch 秒（沿用既有 unixtime 解码纪律）。
            URLQueryItem(name: "timeformat", value: "unixtime")
        ]
        return components?.url
    }
}
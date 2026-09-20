//
//  AirQualityEndpoint.swift
//  Core / Networking  [App + Widget 共用]
//
//  拼装 Open-Meteo Air Quality API 请求 URL（第二条免密链路，独立域名）。
//  与 `OpenMeteoEndpoint`（/v1/forecast 主链路）并列，互不干扰。
//
//  设计点：
//  - `current`：瞬时八字段（AC-A2-1）。
//  - `hourly`：P2 修订（D-B11 / D-C4）新增，逐时 `us_aqi` / `pm2_5` / `pm10`（AC-B22）。
//    **仍并入既有那一条 URL 的一次请求**——只往既有 query 里追加 `hourly`，
//    绝不新增第二条 URL、绝不做第二次请求（AC-B23）。
//  - **显式钉住逐时条数**：`forecast_hours=24`。为什么**必须**显式声明（实测依据，
//    2026-09-20 探针 / 北京 39.9042,116.4074）：不声明任何长度参数时，
//    Open-Meteo 空气链路会继承**默认窗口** —— 实测返回 `hourly.time` 共 **120 条**，
//    自**当地当日 00:00** 起算（含已经过去的小时，本样本含 11 个已过小时），
//    且尾段元素实测为 null（CAMS 模式的预报时效到不了那里）。既白白拉长响应体，
//    又让趋势曲线右端拖出一段无意义的空档。声明 `forecast_hours=24` 后实测
//    恰好返回 **自当前小时起的 24 条**（每个整点一条，`time` 步长 3600s）。
//  - 逐时携带时间数组 → 现在**必须**声明 `timeformat=unixtime`（此前只有 current、
//    无时间数组，故刻意未声明），使 `hourly.time` 为 epoch 秒；mapper 沿用既有
//    epoch → `Date` 解码纪律，不新造第二套时间解析。
//  - 声明 `timezone=auto` 跟随坐标时区（与主链路一致），用于服务端一致性。
//  - 字段名**实测**（不许靠记忆）：`hourly=us_aqi,pm2_5,pm10` 实测 HTTP 200，
//    返回块键名确为 `time` / `us_aqi` / `pm2_5` / `pm10`；未知字段名
//    （实测 `bogus_xyz`）直接 HTTP 400，错误文本为
//    `Invalid value: ... from invalid String value bogus_xyz` ——
//    ⚠️ **CI 不打网络，测不出这个错**，改字段名务必重新探针。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// Open-Meteo Air Quality 请求地址拼装器（独立域名）。
enum AirQualityEndpoint {

    /// 独立基础地址（与主链路 api.open-meteo.com 分离）。
    static let baseURLString = "https://air-quality-api.open-meteo.com/v1/air-quality"

    /// 实况字段（AC-A2-1，八字段）。
    static let currentFields = [
        "pm10",
        "pm2_5",
        "carbon_monoxide",
        "nitrogen_dioxide",
        "sulphur_dioxide",
        "ozone",
        "us_aqi",
        "european_aqi"
    ].joined(separator: ",")

    /// 逐时字段（P2 / D-B11，AC-B22）：逐时 AQI + 两种颗粒物。
    /// 键名以 2026-09-20 探针实测为准：`us_aqi` / `pm2_5` / `pm10`。
    static let hourlyFields = [
        "us_aqi",
        "pm2_5",
        "pm10"
    ].joined(separator: ",")

    /// 逐时窗口条数：**显式**声明取未来 24 小时。
    /// 不声明就会继承 120 小时（5 天）默认窗口并带回尾段 null —— 见文件头说明。
    static let hourlyWindowHours = 24

    /// 依据坐标拼装请求 URL；失败返回 nil（由调用方收敛为 `WeatherError.badURL`）。
    static func url(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: baseURLString)
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: currentFields),
            // D-B11：并入既有请求的逐时块（AC-B23：仍是一次请求，无第二条 URL）。
            URLQueryItem(name: "hourly", value: hourlyFields),
            // 显式钉住返回条数，免疫服务端默认窗口（见文件头）。
            URLQueryItem(name: "forecast_hours", value: String(hourlyWindowHours)),
            // 跟随坐标时区（与主链路一致）。
            URLQueryItem(name: "timezone", value: "auto"),
            // 逐时含时间数组 → 声明 epoch 秒（复用既有 unixtime 解码纪律）。
            URLQueryItem(name: "timeformat", value: "unixtime")
        ]
        return components?.url
    }
}

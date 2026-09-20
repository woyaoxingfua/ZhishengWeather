//
//  METNorwayEndpoint.swift
//  Core / Networking  [App + Widget 共用]
//
//  第三个源 api.met.no（MET Norway）Locationforecast 2.0 compact 请求拼装。
//  选它的理由：**无 Key、无账号**（零注册先跑起来），且是**与 Open-Meteo 不同的
//  数值模式** —— 模式独立，交叉校验才有意义。
//
//  **实测结论（2026-09-20 真实 curl 探针，HTTP 200）**：
//  · 端点：`https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=&lon=`
//  · ⚠️ **必须带可识别的 `User-Agent`**（MET Norway 条款要求标识自身，不带可能被拒）。
//    实测可用：`ZhishengWeather/1.0 github.com/woyaoxingfua/ZhishengWeather` → 200。
//  · 顶层键：`type` / `geometry` / `properties`；`properties.{meta, timeseries}`；
//    `meta.{updated_at, units}`。
//  · `properties.timeseries` 实测 **89–90 条**，逐小时、UTC（`...Z` 结尾），
//    每条形如 `{"time":"2026-09-20T05:00:00Z","data":{"instant":{"details":{...}}, ...}}`。
//  · `data.instant.details` 的**全字段集合**（对全部条目取并集）实测为：
//    `air_pressure_at_sea_level`(hPa) / `air_temperature`(celsius) /
//    `cloud_area_fraction`(%) / `relative_humidity`(%) /
//    `wind_from_direction`(degrees) / `wind_speed`(m/s)。
//  · ⚠️ `wind_speed_of_gust` 在 compact 端点**不存在**（实测 90 条里 0 条有）
//    → 本源**不**映射 `.windGust`（声明了却拿不到会造成 EV-1 误摘）。
//  · `data.next_1_hours.details.precipitation_amount`(mm) 与
//    `next_1_hours.summary.symbol_code` 存在，但 `symbol_code` 是 **MET 自有符号集、
//    不是 WMO 天气码**；映射它需要一张长期维护的对照表（明确不做，本轮也不需要）
//    → 故本源**不**映射降水概率与天气符号。
//
//  ⚠️ **明确未做**：MET 条款建议坐标最多保留 4 位小数（提升其缓存命中率）。
//    本轮请求面与上面那条实测探针**逐字一致**（不对坐标做截断），
//    以免引入未经实测的行为差异；若将来要截断，请连同探针一并复核。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// api.met.no Locationforecast compact 请求拼装器（独立域名，免 Key）。
enum METNorwayEndpoint {

    /// 独立基础地址。
    static let baseURLString = "https://api.met.no/weatherapi/locationforecast/2.0/compact"

    /// MET Norway 条款要求的**可识别标识**；缺它可能被拒（实测带此值 → 200）。
    static let userAgent = "ZhishengWeather/1.0 github.com/woyaoxingfua/ZhishengWeather"

    /// 拼装请求 URL（只有这一条 URL / 一次请求）。
    ///
    /// - Returns: 失败返回 nil（由调用方收敛为 `WeatherError.badURL`）。
    static func url(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: baseURLString)
        components?.queryItems = [
            URLQueryItem(name: "lat", value: String(latitude)),
            URLQueryItem(name: "lon", value: String(longitude))
        ]
        return components?.url
    }

    /// 拼装带 `User-Agent` 的请求（**本源的门槛之一**，故与 URL 同处声明，不留散）。
    ///
    /// 为什么把请求头放在端点而不是服务里：`User-Agent` 是 MET 条款要求的**契约项**
    /// （缺它可能被拒 → 403 → EV-3 把本源摘掉），把它和 `userAgent` 常量放在一起、
    /// 并由端点统一拼装，才不会在换调用点时漏带（且测试可**不联网**地钉住它）。
    ///
    /// - Returns: 失败返回 nil（由调用方收敛为 `WeatherError.badURL`）。
    static func request(latitude: Double, longitude: Double) -> URLRequest? {
        guard let url = url(latitude: latitude, longitude: longitude) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }
}

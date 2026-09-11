//
//  OpenMeteoEndpoint.swift
//  Core / Networking  [App + Widget 共用]
//
//  拼装 Open-Meteo /v1/forecast 请求 URL。
//
//  v1.1 修订（团队裁定）：采纳 `daily` 参数，追加
//    daily=temperature_2m_max,temperature_2m_min
//  与 current / hourly / timezone / timeformat 并列。
//  v1.2 修订（QA 用例暴露）：显式声明 wind_speed_unit=ms —— Open-Meteo 该参数
//  默认为 kmh，不声明会让 wind_speed_10m 以 km/h 返回，与模型/UI 标注的 m/s
//  不符（风速被放大 3.6 倍）。
//  其余参数：timezone=auto（跟随坐标时区）+ timeformat=unixtime（时间以 epoch 秒返回）。
//  v1.3 修订（F-A 逐日预报）：daily 追加 weather_code 与
//    precipitation_probability_max；显式声明 forecast_days=7 ——
//    不传时依赖服务端默认值，一旦服务端策略变更会导致逐日长度漂移
//    （ARCH-zhisheng-ios-FA-increment §2.4 / A-G3 前提）。
//  wind_speed_unit=ms 与 timezone=auto / timeformat=unixtime 维持不动（v1.2 裁定）。
//

import Foundation

/// Open-Meteo 请求地址拼装器。
enum OpenMeteoEndpoint {

    /// 基础地址。
    static let baseURLString = "https://api.open-meteo.com/v1/forecast"

    /// 实况字段。
    static let currentFields = [
        "temperature_2m",
        "relative_humidity_2m",
        "apparent_temperature",
        "weather_code",
        "wind_speed_10m",
        "wind_direction_10m",
        "is_day"
    ].joined(separator: ",")

    /// 逐小时字段。
    static let hourlyFields = ["temperature_2m", "weather_code"].joined(separator: ",")

    /// 逐日字段（v1.1 新增高低温；F-A 追加天气码与最大降水概率）。
    static let dailyFields = [
        "temperature_2m_max",
        "temperature_2m_min",
        "weather_code",
        "precipitation_probability_max"
    ].joined(separator: ",")

    /// 依据坐标拼装请求 URL；失败返回 nil（由调用方收敛为 `WeatherError.badURL`）。
    static func url(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: baseURLString)
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: currentFields),
            URLQueryItem(name: "hourly", value: hourlyFields),
            URLQueryItem(name: "daily", value: dailyFields),
            // 必须显式声明 m/s：Open-Meteo 的 wind_speed_unit 默认是 kmh，
            // 不声明则 wind_speed_10m 会以 km/h 返回，而领域模型与主屏 UI
            // 均按 m/s 标注 → 风速被放大 3.6 倍且单位错误。
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
            // F-A：显式取 7 天逐日，防服务端默认值策略变更（A-G3）。
            URLQueryItem(name: "forecast_days", value: "7"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime")
        ]
        return components?.url
    }
}

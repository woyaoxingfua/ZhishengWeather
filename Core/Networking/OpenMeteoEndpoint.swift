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
//  v1.4 修订（A1 数据拉满，ARCH-zhisheng-ios-A1-increment §1.0 参数对照表）：
//    - current 追加 pressure_msl、surface_pressure（7→9 字段，A1-1）；
//    - daily 追加 sunrise、sunset（4→6 字段，A1-4）——⚠️ 二者绕过
//      timeformat=unixtime 全局参数，仍以 ISO 本地墙钟字符串返回，
//      解码走 ISOTimeStringDecoder 独立路径（禁止混入 epoch 解析）；
//    - forecast_days 显式 7→16（A1-3）；
//    - 新增 past_days=1（A1-5）——⚠️ 触发 daily[0] 由「今天」变「昨天」，
//      mapper 侧 todayIndex 定位配套（OpenMeteoMapper，最高静默回归风险点）。
//  wind_speed_unit=ms 与 timezone=auto / timeformat=unixtime 逐字不动（v1.2 裁定）。
//

import Foundation

/// Open-Meteo 请求地址拼装器。
enum OpenMeteoEndpoint {

    /// 基础地址。
    static let baseURLString = "https://api.open-meteo.com/v1/forecast"

    /// 实况字段（A1 后共 9 字段）。
    static let currentFields = [
        "temperature_2m",
        "relative_humidity_2m",
        "apparent_temperature",
        "weather_code",
        "wind_speed_10m",
        "wind_direction_10m",
        "is_day",
        // A1-1：气压双键。领域层只在 mapper 做一次 msl→surface 回退，
        // 取回退语义（ARCH-A1 §1.1）。
        "pressure_msl",
        "surface_pressure"
    ].joined(separator: ",")

    /// 逐小时字段。
    static let hourlyFields = ["temperature_2m", "weather_code"].joined(separator: ",")

    /// 逐日字段（v1.1 新增高低温；F-A 追加天气码与最大降水概率；
    /// A1 追加 sunrise/sunset——ISO 墙钟字符串，与 unixtime 解码路径隔离）。
    static let dailyFields = [
        "temperature_2m_max",
        "temperature_2m_min",
        "weather_code",
        "precipitation_probability_max",
        // A1-4：日出日落（ISO 本地墙钟字符串，如 "2026-09-11T05:53"）。
        "sunrise",
        "sunset"
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
            // A1-3：显式取 16 天（今天 + 15 天），延续"显式防漂移"纪律（A-G3）。
            URLQueryItem(name: "forecast_days", value: "16"),
            // A1-5：多取一天过去数据，供"昨日对比"。
            // ⚠️ daily[0] 由此从"今天"变"昨天"——mapper 内 todayIndex 定位配套。
            URLQueryItem(name: "past_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime")
        ]
        return components?.url
    }
}

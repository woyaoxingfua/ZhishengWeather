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
//    - daily 追加 sunrise、sunset（4→6 字段，A1-4）——⚠️ **run37 真机修正**：
//      二者**同样**受 timeformat=unixtime 影响，实测返回 epoch 整数
//      （原"绕过 unixtime 仍是 ISO"的论断有误 → 真机解码全失败）。
//      现由 FlexibleTime 双态容忍，mapper 归一为 DateTime；
//    - forecast_days 显式 7→16（A1-3）；
//    - 新增 past_days=1（A1-5）——⚠️ 触发 daily[0] 由「今天」变「昨天」，
//      mapper 侧 todayIndex 定位配套（OpenMeteoMapper，最高静默回归风险点）。
//  wind_speed_unit=ms 与 timezone=auto / timeformat=unixtime 逐字不动（v1.2 裁定）。
//  v1.6 修订（P2 数据补全，用户诉求"补全数据吧…先把天气做好吧"）：
//    在**既有单次 /v1/forecast 请求**内追加实况 / 逐时 / 逐日本体字段，
//    **不新增任何 query 参数**（仍是单请求，Open-Meteo 配额计数 ×1，R-Q2 纪律——
//    与 B1-2 的"加字段不加剧请求"同款约束）。追加：
//    - current：precipitation / rain / showers / snowfall / uv_index；
//    - hourly：precipitation / wind_speed_10m / wind_gusts_10m / apparent_temperature；
//    - daily：precipitation_sum / rain_sum / snowfall_sum / wind_speed_10m_max /
//      wind_gusts_10m_max / wind_direction_10m_dominant / daylight_duration /
//      sunshine_duration / apparent_temperature_max / apparent_temperature_min。
//    全部字段名经真实 curl 探针（北京 39.9042,116.4074，与本枚举逐字相同的参数）
//    逐个验证返回 HTTP 200 且键存在。单位事实：snowfall / snowfall_sum 实测为
//    cm（Open-Meteo 原值，mapper 原样透传，单位换算归 UI）；daylight_duration /
//    sunshine_duration 单位为**秒**（同透传）。wind_speed_unit=ms 等既有参数逐字不动。
//  v1.5 修订（B1-2 短时降水，PRD §4.3 R-Q2「加字段不加剧请求」）：
//    在**既有单次 forecast 请求**内追加 minutely_15=precipitation,precipitation_probability
//    （不新增第二个端点/请求）；并**必须**显式声明 forecast_minutely_15=8 —— 把返回条目
//    钉在 8×15min=2h（本项目调研文档 open-meteo-capability-verified.md 第 19 行口径）。
//    ⚠️ 不传该长度控制参数会**继承 forecast_days 窗口**（forecast_days=1→96 条；
//       本工程 forecast_days=16→约 1600 条），白白膨胀响应体与共享容器载荷。
//    ⚠️ 事实更正（实测验证）：中国等非原生覆盖区的 minutely_15 为**逐小时插值到
//       15 分钟网格**，**非实况外推 / nowcast**；且**数组长度无法区分原生与插值**
//       （柏林与杭州同为 96 条），故**绝不可**据条目数推断数据质量。time 沿用既有
//       `timeformat=unixtime` 的 epoch 纪律，**不引入第二套时间解码**。
//

import Foundation

/// Open-Meteo 请求地址拼装器。
enum OpenMeteoEndpoint {

    /// 基础地址。
    static let baseURLString = "https://api.open-meteo.com/v1/forecast"

    /// 实况字段（A1 后 9 字段；B1 遥测补全 +4 = 13 字段；P2 数据补全 +5 = 18 字段）。
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
        "surface_pressure",
        // B1 遥测补全：单请求内追加 4 个实况字段（**禁止**第二次请求）——
        // 能见度 / 2m 露点 / 总云量 / 10m 阵风。
        "visibility",
        "dew_point_2m",
        "cloud_cover",
        "wind_gusts_10m",
        // P2 数据补全：实况降水本体（precipitation / rain / showers / snowfall）
        // 与实况 UV 指数。snowfall 单位实测为 cm（Open-Meteo 原值，mapper 透传）；
        // 四降水键任一缺失服务端即整组省略，mapper 侧四键全 nil → UI 整格隐藏。
        "precipitation",
        "rain",
        "showers",
        "snowfall",
        "uv_index"
    ].joined(separator: ",")

    /// 逐小时字段。
    // A2-2：+precipitation_probability（逐时降水概率，摘要引擎输入）
    // P2 数据补全：+precipitation（逐时降水 mm）/ wind_speed_10m（m/s）/
    //   wind_gusts_10m（m/s）/ apparent_temperature（℃体感）。四者均为可选元素数组，
    //   截断日尾段为 null（v1.6 纪律已在 DTO 落 `[Double?]?`），mapper 跳过不补 0。
    static let hourlyFields = ["temperature_2m", "weather_code", "precipitation_probability", "precipitation", "wind_speed_10m", "wind_gusts_10m", "apparent_temperature"].joined(separator: ",")

    /// 逐日字段（v1.1 新增高低温；F-A 追加天气码与最大降水概率；
    /// A1 追加 sunrise/sunset——run37 实测在 unixtime 下返回 epoch 整数，
    /// 由 FlexibleTime 双态容忍解码）。
    static let dailyFields = [
        "temperature_2m_max",
        "temperature_2m_min",
        "weather_code",
        "precipitation_probability_max",
        // A1-4：日出日落（unixtime 下为 epoch 秒；部分部署为 ISO 字符串）。
        "sunrise",
        "sunset",
        // A2-2：UV 指数峰值（摘要引擎 UV 规则 + A2-5 逐日展开预埋）。
        "uv_index_max",
        // P2 数据补全：逐日本体字段。precipitation_sum / rain_sum / snowfall_sum 单位
        //   mm（snowfall_sum 实测 cm）；wind_speed_10m_max / wind_gusts_10m_max 单位 m/s；
        //   wind_direction_10m_dominant 单位度；daylight_duration / sunshine_duration 单位
        //   **秒**；apparent_temperature_max / _min 单位 ℃。全部 `[Double?]?`（截断日末行 null）。
        "precipitation_sum",
        "rain_sum",
        "snowfall_sum",
        "wind_speed_10m_max",
        "wind_gusts_10m_max",
        "wind_direction_10m_dominant",
        "daylight_duration",
        "sunshine_duration",
        "apparent_temperature_max",
        "apparent_temperature_min"
    ].joined(separator: ",")

    /// 短时降水字段（B1-2，15 分钟粒度）。
    ///
    /// 15 分钟累计降水量（mm）+ 降水概率（%）。与 current/hourly/daily **并列同一请求**
    /// （R-Q2：加字段不加剧请求，绝不新增第二个端点）。
    static let minutelyFields = ["precipitation", "precipitation_probability"].joined(separator: ",")

    /// 短时降水返回条数上限（B1-2：8×15min=2h，与本项目调研文档口径一致）。
    static let minutelyForecastCount = 8

    /// 依据坐标拼装请求 URL；失败返回 nil（由调用方收敛为 `WeatherError.badURL`）。
    static func url(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: baseURLString)
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: currentFields),
            URLQueryItem(name: "hourly", value: hourlyFields),
            URLQueryItem(name: "daily", value: dailyFields),
            // B1-2：短时降水（15 分钟粒度），**并入同一请求**（R-Q2）。
            URLQueryItem(name: "minutely_15", value: minutelyFields),
            // B1-2：显式钉住 8×15min=2h（防服务端默认把序列撑到 forecast_days 全域）。
            URLQueryItem(name: "forecast_minutely_15", value: String(minutelyForecastCount)),
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

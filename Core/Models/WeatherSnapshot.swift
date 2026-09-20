//
//  WeatherSnapshot.swift
//  Core / Models  [App + Widget 共用]
//
//  领域主模型：一次成功取数的完整天气快照。
//
//  v1.1 修订（团队裁定）：`dailyHigh` / `dailyLow` 由「计算属性」改为「存储属性」，
//  取值自 Open-Meteo `daily` 的第 0 项；仅当 `daily` 缺失或长度不足时，
//  才由 OpenMeteoMapper 回退按 hourly 窗口的 min/max 派生。
//
//  v1.2 修订（F-A 逐日预报）：新增可选存储属性 `daily: [DailyForecast]?`
//  （插在 `dailyLow` 与 `fetchedAt` 之间）。其余字段一律不动；
//  旧缓存兼容依赖合成 Codable 对缺失键返回 nil（详见字段注释）。
//
//  v1.3 修订（A1，ARCH-A1 §1.1/§1.4/§1.5）：新增 4 个可选字段（默认 nil，
//  合成 Codable，旧缓存解码不失败）——
//    - `pressureMSL: Double?`：海平面气压，mapper 内 msl→surface 一次回退定值；
//    - `sunrise` / `sunset: Date?`：今日日出/日落（mapper 从今日行拷贝，UI 免索引）；
//    - `yesterday: DailyForecast?`：昨日整对象（AC-A1-14/15 同时要昨日温度与现象）。
//  语义注记：A1 后 `daily` 数组**自今日起截**（daily[0] 恒为今天，
//  `yesterday` 单独存放），全仓既有「daily.first = 今天」语义不变。
//
//  v1.4 修订（B1-2 短时降水）：新增可选字段 `minutely15: [MinutelyPrecipitationPoint]?`
//  （默认 nil，置于 `fetchedAt` 之后），承载未来约 2 小时的 15 分钟粒度降水序列。
//  可选 + 合成 Codable，旧缓存缺键 → nil、解码不失败（R3；禁手写 init(from:)/payloadVersion）。
//
//  v1.5 修订（P2 数据补全，用户诉求"补全数据吧"）：新增 5 个实况可选字段
//  （`precipitation` / `rain` / `showers` / `snowfall` / `uvIndex`），**插在 `fetchedAt`
//  之后**（沿用 `minutely15` 的既有范式），保证合成逐成员初始化器把本组参数放末位且带
//  默认值，全仓既有 `WeatherSnapshot(...)` 调用点零改动即可编译。四降水键（precipitation /
//  rain / showers / snowfall）整组缺失 → 全 nil，UI 整格隐藏，绝不合成 0.0（AC-A5）；
//  `uvIndex` 为实况值，与 `DailyForecast.uvIndexMax`（当日峰值）语义不同，UI 分标签。
//  snowfall 单位实测为 cm（Open-Meteo 原值，透传，换算归 UI）。
//

import Foundation

/// 一次成功取数得到的天气快照（落盘 / 展示 / 小组件共用）。
struct WeatherSnapshot: Codable, Equatable, Sendable {

    /// 查询所用的位置。
    var location: LocationInfo
    /// 当前气温（℃）。
    var temperature: Double
    /// 当前体感温度（℃）。
    var apparentTemperature: Double
    /// 当前 WMO 天气码。
    var weatherCode: Int
    /// 当前风速（m/s）。
    var windSpeed: Double
    /// 当前风向（0–360 度）。
    var windDirection: Double
    /// 当前相对湿度（%）。
    var humidity: Int
    /// 当前是否白天。
    var isDay: Bool
    /// 逐小时预报（已按 now 起截取，≤ 24 条，A1-2 由 12 放宽）。
    var hourly: [HourlyPoint]
    /// 今日最高温（℃）。A1 后取自 daily 的**今日索引**行（past_days=1 使
    /// daily[0] 变昨天，mapper 内 todayIndex 定位）；缺失时回退 hourly 窗口 max。
    var dailyHigh: Double
    /// 今日最低温（℃）。取值语义同 `dailyHigh`（今日索引；回退 hourly 窗口 min）。
    var dailyLow: Double
    /// 逐日预报（F-A 新增，可选）。
    ///
    /// 兼容性核心（F-A-9）：**必须**保持合成 Codable + 可选类型 ——
    /// 旧版 App 写入的共享容器 JSON 没有 `daily` 键，合成解码器对缺失键
    /// 天然返回 nil、不抛错，旧缓存读取必然成功。
    /// **禁止**为本字段手写 `init(from:)` 或引入 payloadVersion（会击穿兼容保证）。
    ///
    /// 取值约定：
    /// - 服务端返回且映射成功 → 数组（可能为空，空数组同样整块隐藏）；
    /// - DTO `daily` 缺失 → nil；
    /// - 旧缓存无此键 → nil。
    var daily: [DailyForecast]? = nil

    /// 海平面气压（hPa，A1 新增，可选）。
    ///
    /// mapper 内 `pressure_msl ?? surface_pressure` 一次回退定值（ARCH-A1 §1.1）：
    /// 领域层不区分数据来自哪个字段，UI 层不做第二次回退决策。
    /// nil = 双键均缺失 / 旧缓存无此键 → UI 显示 "--"（AC-A1-3，绝不显示 0）。
    var pressureMSL: Double? = nil

    /// 今日日出（A1 新增，可选）。由 mapper 从今日行经 `ISOTimeStringDecoder`
    /// 解码拷贝而来，UI 免索引；nil = 缺失/解析失败/旧缓存 → 对应段隐藏。
    var sunrise: Date? = nil

    /// 今日日落（A1 新增，可选）。语义同 `sunrise`。
    var sunset: Date? = nil

    /// 昨日天气（A1 新增，可选，整对象）。
    ///
    /// AC-A1-14/15 需要昨日的温度**与**现象，单字段不够；nil = 无昨日数据
    /// （todayIndex=0 / 旧缓存）→ 主屏对比行整行隐藏（AC-A1-16）。
    /// 取值约定：`daily` 输出自今日起截（daily[0] 恒为今天），昨日不混入
    /// `daily` 数组，仅单独存放在此。
    var yesterday: DailyForecast? = nil

    /// B1 遥测补全：能见度（m，Open-Meteo 原值，可选，默认 nil）。
    ///
    /// 兼容核心（R3）：可选 + 合成 Codable，旧缓存无此键 → nil、解码不失败；
    /// nil = 服务端未返回 / 旧缓存 → UI 显示 "--"（AC-A1-3 同款，绝不显示 0 冒充）。
    var visibility: Double? = nil

    /// B1 遥测补全：2m 露点温度（℃）。语义同 `visibility`。
    var dewPoint: Double? = nil

    /// B1 遥测补全：总云量（%）。语义同 `visibility`（0% 是合法值，仅 nil 显示 "--"）。
    var cloudCover: Double? = nil

    /// B1 遥测补全：10m 阵风（m/s）。语义同 `visibility`。
    var windGusts: Double? = nil

    /// 本次取数时间。
    var fetchedAt: Date

    /// P2 数据补全：此刻降水量（mm）。可选 + 默认 nil（置于 `fetchedAt` 之后，
    /// 与 `minutely15` 的既有范式一致：合成逐成员初始化器把本参数放末位且带默认值，
    /// 全仓既有 `WeatherSnapshot(...)` 调用点零改动即可编译）。
    /// nil = 服务端四降水键整组省略 / 旧缓存无此键 → UI 整格隐藏，绝不合成 0。
    var precipitation: Double? = nil

    /// P2 数据补全：此刻液态降水量（mm）。可选 + 默认 nil（语义同 `precipitation`）。
    var rain: Double? = nil

    /// P2 数据补全：此刻阵雨降水量（mm）。可选 + 默认 nil（语义同 `precipitation`）。
    var showers: Double? = nil

    /// P2 数据补全：此刻降雪量（**cm**，Open-Meteo 原值；UI 换算归展示层）。
    /// 可选 + 默认 nil（语义同 `precipitation`）。
    var snowfall: Double? = nil

    /// P2 数据补全：此刻 UV 指数（实况值）。可选 + 默认 nil。
    /// ⚠️ 与 `DailyForecast.uvIndexMax`（当日峰值）语义不同，UI 不许共用一个标签。
    var uvIndex: Double? = nil

    /// B1-2 短时降水（15 分钟粒度，可选）。
    ///
    /// 兼容核心（R3）：**可选 + 合成 Codable + 默认 nil**（沿用 `daily` 的既有范式，见上方
    /// `daily` 注释）——旧版共享容器 JSON 无此键时合成解码器返回 nil、不抛错。
    /// **禁止**手写 `init(from:)`、**禁止**引入 payloadVersion。
    ///
    /// 声明在 `fetchedAt` **之后**：合成的逐成员初始化器把本参数放到末位且带默认值，
    /// 全仓既有 `WeatherSnapshot(...)` 调用点零改动即可编译。
    ///
    /// 取值约定：mapper 自"当前 15 分钟窗"起截 ≤ 8 条（2 小时）；服务端未返回 /
    /// 无有效点 / 旧缓存 → nil。主屏短时降水卡在**干窗或 nil** 时整卡隐藏
    /// （AC-B1-8/B1-9，不显示空槽）。
    var minutely15: [MinutelyPrecipitationPoint]? = nil

    // MARK: - 派生属性（不参与 Codable 存储）

    /// 月相，由 `fetchedAt` 纯计算得出。
    var moonPhase: MoonPhase {
        MoonCalculator.phase(for: fetchedAt)
    }
}

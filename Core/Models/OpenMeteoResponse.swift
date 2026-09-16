//
//  OpenMeteoResponse.swift
//  Core / Models  [App + Widget 共用]
//
//  Open-Meteo /v1/forecast 的原始 DTO。
//  请求带 `timeformat=unixtime`，故时间字段一律为 epoch 秒（Int），
//  解析侧 `Date(timeIntervalSince1970:)`，不做字符串解析。
//  ⚠️ **run37 真机修正**：daily.sunrise / daily.sunset（A1-4）**同样**
//  受 unixtime 影响——实测返回 epoch 整数（ARCH-A1 §1.4 原"仍是 ISO
//  本地墙钟字符串"的论断有误，曾导致真机 100% 解码失败 / UI "格式问题"）。
//  DTO 因此用 FlexibleTime 双态容忍（epoch 数字 或 ISO 字符串都能解），
//  mapper 侧归一为 Date；ISO 形态仍由 ISOTimeStringDecoder 兜底。
//
//  v1.1 修订：新增 `daily` 块（采纳 daily 参数）。
//  v1.2 修订（A1）：Current +pressure_msl/surface_pressure（可选 Double，
//    键缺失不炸，偏差备案 D-A1）；Daily +sunrise/sunset（D-1 风格）。
//  v1.3 修订（run37）：Daily.sunrise/sunset 由 [String?]? 改 [FlexibleTime?]?
//    —— epoch / ISO 双态容忍（真机实测为 epoch，见上）。
//  v1.4 修订（B1-2 短时降水）：新增整块可选的 `minutely_15`（time/precipitation/
//    precipitation_probability），真机实测（杭州 30.27,120.16）：HTTP 200，
//    块键名确为 `time`/`precipitation`/`precipitation_probability`，time 为 epoch 秒
//    （900s 间隔），precipitation 单位 mm、precipitation_probability 单位 %。
//    整块/元素均可选：服务端未返回或旧部署不炸、不连累主链路解码。
//

import Foundation

/// Open-Meteo 原始响应（仅保留本项目所需字段）。
struct OpenMeteoResponse: Codable, Sendable {

    /// 当前实况。
    struct Current: Codable, Sendable {
        /// epoch 秒（timeformat=unixtime）。
        let time: Int
        let temperature_2m: Double
        let relative_humidity_2m: Int
        let apparent_temperature: Double
        let weather_code: Int
        let wind_speed_10m: Double
        let wind_direction_10m: Double
        /// 0 = 夜，1 = 昼。
        let is_day: Int
        /// 海平面气压（hPa）。A1 新增，整键可选：服务端异常省略键时不炸
        /// （偏差备案 D-A1；mapper 内 msl 优先、缺则回退 surface_pressure）。
        let pressure_msl: Double?
        /// 地面气压（hPa）。A1 新增，整键可选（同上）。
        let surface_pressure: Double?
        /// B1 遥测补全：能见度（m）。整键可选 + 默认 nil：服务端省略键 / 旧测试
        /// 零改动，解码不炸（合成 Codable 对缺失 Optional 键返回 nil）。
        var visibility: Double? = nil
        /// B1 遥测补全：2m 露点温度（℃）。可选 + 默认 nil。
        var dew_point_2m: Double? = nil
        /// B1 遥测补全：总云量（%）。可选 + 默认 nil。
        var cloud_cover: Double? = nil
        /// B1 遥测补全：10m 阵风（m/s，随 wind_speed_unit=ms）。可选 + 默认 nil。
        var wind_gusts_10m: Double? = nil
    }

    /// 逐小时序列。
    struct Hourly: Codable, Sendable {
        let time: [Int]
        let temperature_2m: [Double]
        let weather_code: [Int]
        /// A2-2 新增。逐时降水概率（%），元素/整键均可选（Open-Meteo 可能返回 null 元素）。
        /// 默认 nil：旧测试/旧调用零改动（Codable 解码不受默认值影响）。
        var precipitation_probability: [Double?]? = nil
    }

    /// 逐日序列（用于当日高/低温 + F-A 逐日预报）。
    struct Daily: Codable, Sendable {
        let time: [Int]
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
        /// F-A 新增。整键可选：服务端异常省略键时不炸
        /// （mapper 按空数组对齐 → 逐日为空 → 区块隐藏）。
        /// 偏差备案 D-1：PRD 原写非可选，改为可选以与 `daily: Daily?`
        /// 的解码鲁棒性风格一致（DTO 不落盘，解码失败会连累实况与逐小时）。
        let weather_code: [Int]?
        /// F-A 新增。整键可选 + 元素可选：Open-Meteo 可能返回 null 元素（AC-A5）。
        let precipitation_probability_max: [Int?]?
        /// A1-4。日出时刻——⚠️ **双态容忍解码**（run37 修正，真机实测）：
        /// `timeformat=unixtime` 下 Open-Meteo 实测返回 **epoch 数字**
        /// （设计文档 A1 §1.4"仍是 ISO 字符串"的论断有误，真机全量解码失败）；
        /// 部分部署也可能返回 ISO 字符串。经 FlexibleTime 双态容忍，
        /// mapper 侧统一归一为 Date。整键可选 + 元素可选（极地日期可能 null）。
        let sunrise: [FlexibleTime?]?
        /// A1-4。日落时刻，同上（双态容忍）。整键可选 + 元素可选。
        let sunset: [FlexibleTime?]?
        /// A2-2 新增。逐日 UV 指数峰值，元素/整键均可选。默认 nil（旧调用零改动）。
        var uv_index_max: [Double?]? = nil
    }

    /// 短时降水序列（B1-2，15 分钟粒度）。
    ///
    /// 请求带 `timeformat=unixtime`，故 `time` 为 epoch 秒（真机实测 900s 间隔）。
    /// 字段/元素全部可选：服务端未返回块时整块缺失（`OpenMeteoResponse.minutely_15 == nil`）、
    /// 元素可能为 null —— 均不连累主链路解码（沿用 DTO 整键可选纪律）。
    struct Minutely15: Codable, Sendable {
        /// 15 分钟窗起始时刻（epoch 秒）。
        let time: [Int]
        /// 15 分钟累计降水量（mm）。整键/元素可选。
        var precipitation: [Double?]? = nil
        /// 15 分钟降水概率（%）。整键/元素可选。
        var precipitation_probability: [Double?]? = nil
    }

    let timezone: String
    let utc_offset_seconds: Int
    let current: Current
    let hourly: Hourly
    /// 可选：当服务端未返回 daily（或旧缓存）时为 nil，映射层负责回退。
    let daily: Daily?
    /// B1-2 短时降水块，可选（默认 nil）。
    ///
    /// `var ... = nil` 而非 `let`：保持合成的逐成员初始化器把本参数**放到末位且带默认值**，
    /// 既有 `OpenMeteoResponse(...)` 调用点（测试构造）零改动即可编译；
    /// 同时 JSON 缺 `minutely_15` 键 → 合成解码器返回 nil、不抛错。
    var minutely_15: Minutely15? = nil
}

/// A1-4（run37 修正）：日出/日落的双态容忍解码——
/// `timeformat=unixtime` 下 Open-Meteo 实测返回 epoch 数字；部分部署/旧文档
/// 为 ISO 字符串。两种形态都统一为 epoch 秒（Double?），mapper 直接用。
enum FlexibleTime: Codable, Sendable {

    case epoch(Double)
    case iso(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .epoch(value)
        } else if let value = try? container.decode(String.self) {
            self = .iso(value)
        } else {
            throw DecodingError.typeMismatch(
                FlexibleTime.self,
                .init(codingPath: decoder.codingPath,
                      debugDescription: "期待 epoch 数字或 ISO 字符串"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .epoch(let value): try container.encode(value)
        case .iso(let value): try container.encode(value)
        }
    }

    /// epoch 秒；ISO 形态返回 nil（mapper 侧用 ISOTimeStringDecoder 另行解码）。
    var epochSeconds: Double? {
        if case .epoch(let value) = self { return value }
        return nil
    }

    /// ISO 字符串形态（若此值是 ISO）。
    var isoString: String? {
        if case .iso(let value) = self { return value }
        return nil
    }
}
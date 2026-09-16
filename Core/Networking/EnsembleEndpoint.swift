//
//  EnsembleEndpoint.swift
//  Core / Networking  [App + Widget 共用]
//
//  拼装 Open-Meteo Ensemble API 请求 URL（第三条免密链路，独立域名）。
//  与 `OpenMeteoEndpoint`（/v1/forecast 主链路）、`AirQualityEndpoint`
//  （空气第二链路）并列，互不干扰。
//
//  设计点（对齐 ARCH-zhisheng-ios-multi-source §1「新增链路六步模板」）：
//  - **模式显式固定**：`models=gfs025`（GFS 0.25° 全球集合）。理由：省略 `models`
//    时为 Best Match，成员数随服务端选择漂移；显式模式使「成员数」确定性可预期。
//    【实测备案，杭州 30.27,120.16】`models=gfs025` → HTTP 200，`hourly` 含
//    `time` + 控制成员 `precipitation` + `precipitation_member01…member30`，
//    即 **30 个成员**（不含控制成员）。**解析侧仍按 `_member\d{2}` 动态匹配、
//    绝不硬编码 30**（成员数随模式变化：icon_seamless→40、ecmwf_ifs025→50、
//    bom_access_global→1，见 PRD §11-8）。
//  - **请求面最小化**（额度纪律，PRD §4.1：本调用等价 4.0 次额度）：只请求决策所需
//    的 `hourly=precipitation`，`forecast_days=2`（48 小时）——够「未来 1–2 天」的
//    概率判断，不做冗余字段。**绝不发空 `models=`**（空值 → HTTP 400）。
//  - **不声明 `timeformat`**：默认 `iso8601`，故 `time` 为本地墙钟字符串
//    （实测 "2026-09-16T00:00"），由 `ISOTimeStringDecoder` + 根级
//    `utc_offset_seconds` 解释为绝对时刻。
//  - 声明 `timezone=auto` 跟随坐标时区（与其余链路一致）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// Open-Meteo Ensemble 请求地址拼装器（独立域名）。
enum EnsembleEndpoint {

    /// 独立基础地址（与主链路 api.open-meteo.com、空气链路分离）。
    static let baseURLString = "https://ensemble-api.open-meteo.com/v1/ensemble"

    /// 显式集合模式：GFS 0.25°（实测 30 个成员）。固定模式以保证成员数确定性；
    /// 成员解析仍动态（见 `EnsembleMapper`），本常量**不**用于推断成员数。
    static let model = "gfs025"

    /// 请求的逐小时字段（仅降水——决策所需的最小集）。
    static let hourlyFields = "precipitation"

    /// 预报天数（48 小时，覆盖「未来 1–2 天」概率判断）。
    static let forecastDays = 2

    /// 依据坐标拼装请求 URL；失败返回 nil（由调用方收敛为 `WeatherError.badURL`）。
    /// - Parameters:
    ///   - latitude: 纬度（WGS84）。
    ///   - longitude: 经度（WGS84）。
    /// - Returns: 完整请求 URL；`URLComponents` 构造失败时为 nil。
    static func url(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: baseURLString)
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "hourly", value: hourlyFields),
            // 非空 models（空值 → 400，见 PRD §11-8）。
            URLQueryItem(name: "models", value: model),
            URLQueryItem(name: "forecast_days", value: String(forecastDays)),
            // 跟随坐标时区；不声明 timeformat（默认 iso8601 本地墙钟）。
            URLQueryItem(name: "timezone", value: "auto")
        ]
        return components?.url
    }
}

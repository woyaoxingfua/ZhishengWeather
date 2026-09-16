//
//  ArchiveMapper.swift
//  Core / Networking  [App + Widget 共用]
//
//  历史天气 DTO → 领域模型（A3-1，纯函数）：
//   - 键缺失/null → 对应字段 nil；
//   - time 数组为映射主轴（缺失 → 空 days）；
//   - 其余数组越界安全取值。
//
//  Core 纪律：仅 import Foundation；纯函数；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 历史天气映射器（纯函数）。
enum ArchiveMapper {

    /// 映射。`daily` 缺失 → 空序列（历史页显示"暂无数据"）。
    static func map(_ response: ArchiveResponse) -> HistoricalWeather {
        guard let daily = response.daily, let times = daily.time else {
            return HistoricalWeather(days: [])
        }
        let days = times.enumerated().map { index, dateString in
            HistoricalDay(
                dateString: dateString,
                tempMax: Self.optionalDouble(daily.temperature_2m_max, at: index),
                tempMin: Self.optionalDouble(daily.temperature_2m_min, at: index),
                weatherCode: Self.optionalInt(daily.weather_code, at: index),
                precipitationSum: Self.optionalDouble(daily.precipitation_sum, at: index)
            )
        }
        return HistoricalWeather(days: days)
    }

    // MARK: - Private

    private static func optionalDouble(_ array: [Double?]?, at index: Int) -> Double? {
        guard let array, index < array.count else { return nil }
        return array[index]
    }

    private static func optionalInt(_ array: [Int?]?, at index: Int) -> Int? {
        guard let array, index < array.count else { return nil }
        return array[index]
    }
}

//
//  WidgetShared.swift
//  ZhishengWeatherWidget（Widget target）
//
//  Widget 各尺寸视图共用的**纯格式化工具**。
//  只放与具体布局无关的小东西，避免各 View 各写一份 DateFormatter
//  （`DateFormatter` 构造代价高，重复创建会拖慢时间线渲染）。
//

import Foundation

/// Widget 展示用格式化器集合。
enum WidgetTimeFormatter {

    /// 「14:05」。
    static let hourMinute: DateFormatter = makeFormatter("HH:mm")

    /// 「9月11日 周四」。
    static let monthDayWeekday: DateFormatter = makeFormatter("M月d日 EEEE")

    /// 「9月11日」。
    static let monthDay: DateFormatter = makeFormatter("M月d日")

    /// 「周三」（F-A：Large 逐日列的星期标签；与主 App DailyForecastSection 的
    /// 同语义格式器独立实现 —— 两 target 不共享该文件，各自持有）。
    static let weekdayShort: DateFormatter = makeFormatter("EEE")

    /// 构造一个 zh_CN 本地化的固定格式器。
    /// - Parameter format: `dateFormat` 模式串。
    /// - Returns: 已配置好的 `DateFormatter`。
    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = format
        return formatter
    }
}

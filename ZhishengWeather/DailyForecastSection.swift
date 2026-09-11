//
//  DailyForecastSection.swift
//  ZhishengWeather（主 App target）
//
//  F-A 逐日预报区块：行渲染 + 3/7 天会话内切换。
//
//  关键纪律（ARCH-zhisheng-ios-FA-increment §4.1 / PRD Q2）：
//  - 3/7 展开状态**只存在于本视图的 `@State`**：不进 ViewModel、不进 snapshot、
//    不写共享容器、不持久化。冷启动重建视图自动回 3 天。
//  - 降水概率 nil → 显示 "--"（灰色），**绝不显示 0%**（AC-A5）。
//  - 复用 `WMOCodeMapper`，不新增映射表（AC-A4）。
//  - 「今天/周几」标签基于快照内的日期 + `Calendar.current.isDateInToday`，
//    不取当前时刻构造 Date（与 Core「now 注入」纪律一致；UI 层允许 Calendar.current，
//    先例见 LargeWeatherView 的图标昼夜判断）。
//

import SwiftUI

/// 主屏逐日预报区块。
/// @MainActor：与项目内其他 View 保持一致（SwiftUI 仅 body 推断主 actor，
/// 整体标注消除 init/辅助成员的非隔离盲区）。
@MainActor
struct DailyForecastSection: View {

    /// 逐日数据（由调用方保证非空；nil / 空数组的隐藏判断在 ContentView 侧）。
    let daily: [DailyForecast]

    /// 3/7 展开状态：会话内记忆，默认收起（3 天），不落盘（PRD Q2 / F-A-6）。
    @State private var isExpanded: Bool = false

    /// 展开时最多展示的天数。
    private let expandedCount: Int = 7

    /// 收起时展示的天数（AC-A2 / F-A-2 默认 3 天）。
    private let collapsedCount: Int = 3

    /// 日期标签列固定宽度（iPhone SE 375pt 下不溢出，AC-A9 / F-A-8）。
    private let dateColumnWidth: CGFloat = 64

    /// 当前应展示的天数。
    private var visibleDays: [DailyForecast] {
        Array(daily.prefix(isExpanded ? expandedCount : collapsedCount))
    }

    /// 数据不足 4 天时切换无意义，隐藏按钮。
    private var canToggle: Bool {
        daily.count > collapsedCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            rows
        }
    }

    // MARK: - 标题 + 胶囊切换钮

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("未来数天")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)

            Spacer(minLength: 8)

            if canToggle {
                toggleButton
            }
        }
    }

    /// 「7 天」↔「收起」胶囊按钮。
    private var toggleButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Text(isExpanded ? "收起" : "7 天")
                .font(.system(size: Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Theme.surface, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Theme.divider, lineWidth: 0.5)
                )
        }
        .accessibilityLabel(isExpanded ? "收起，仅显示 3 天" : "展开 7 天预报")
    }

    // MARK: - 逐日行

    private var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(visibleDays) { day in
                row(day)
            }
        }
    }

    /// 单行：日期标签列（固定宽）→ 图标 + 现象 → Spacer → 降水概率 → 高低温。
    private func row(_ day: DailyForecast) -> some View {
        HStack(spacing: 8) {
            // 日期标签列：主标签「今天/周三」+ 次标签「M月d日」。
            VStack(alignment: .leading, spacing: 1) {
                Text(primaryLabel(for: day))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(Self.monthDayFormatter.string(from: day.date))
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(width: dateColumnWidth, alignment: .leading)

            WeatherSymbol(code: day.weatherCode, isDay: true, size: 18)

            Text(WMOCodeMapper.description(for: day.weatherCode))
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)

            Spacer(minLength: 8)

            // 降水概率：nil → "--"（灰色），绝不显示 0%（AC-A5）。
            Text(precipitationText(for: day))
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(day.precipitationProbability == nil
                                 ? Theme.secondaryText
                                 : Theme.accentSecondary)
                .lineLimit(1)

            Text(temperatureText(for: day))
                .font(.system(size: Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
        }
    }

    // MARK: - 取值

    /// 主标签：今天 → 「今天」；其余 → 「周三」等（EEE, zh_CN）。
    /// 判断基于快照内日期与 `Calendar.isDateInToday`，不构造当前时刻。
    private func primaryLabel(for day: DailyForecast) -> String {
        Calendar.current.isDateInToday(day.date) ? "今天"
            : Self.weekdayFormatter.string(from: day.date)
    }

    /// 「80%」或「--」。
    private func precipitationText(for day: DailyForecast) -> String {
        guard let probability = day.precipitationProbability else { return "--" }
        return "\(probability)%"
    }

    /// 「↑25° ↓15°」。
    private func temperatureText(for day: DailyForecast) -> String {
        "↑\(Int(day.tempMax.rounded()))° ↓\(Int(day.tempMin.rounded()))°"
    }

    // MARK: - 格式化工具

    /// 「周三」（周几，zh_CN 缩写）。
    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEE"
        return formatter
    }()

    /// 「9月11日」（DateFormatter 自动正确处理跨月 / 跨年，AC-A10）。
    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
}

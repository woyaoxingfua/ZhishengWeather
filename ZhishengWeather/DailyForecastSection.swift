//
//  DailyForecastSection.swift
//  ZhishengWeather（主 App target）
//
//  F-A 逐日预报区块：行渲染 + 3/7/15 天三档会话内切换（A1-3，ARCH-A1 §1.3）。
//
//  关键纪律（ARCH-zhisheng-ios-FA-increment §4.1 / ARCH-A1 §1.3）：
//  - 档位状态**只存在于本视图的 `@State`**：不进 ViewModel、不进 snapshot、
//    不写共享容器、不跨启动持久化。冷启动重建视图自动回 3 天
//    （F-A"展开状态止步于 @State"的结构性隔离平移，L-9 纪律）。
//  - 3 档选择控件：`Picker(.segmented)`；档位随数据量动态生成（恒含 3 天；
//    `daily.count > 3` 才出现 7 天、`> 7` 才出现 15 天），**不禁用段**（P1-C 修复：
//    原 `.disabled(!canToggle)` 会把恒可用的「3 天」段一并禁用，属档位禁用错误）。
//  - 降水概率 nil → 显示 "--"（灰色），**绝不显示 0%**（AC-A5）。
//  - 复用 `WMOCodeMapper`，不新增映射表（AC-A4）。
//  - 「今天/周几」标签基于快照内的日期 + `Calendar.current.isDateInToday`，
//    不取当前时刻构造 Date（与 Core「now 注入」纪律一致；UI 层允许 Calendar.current，
//    先例见 LargeWeatherView 的图标昼夜判断）。
//    A1 后 mapper 的 daily 输出自今日起截（daily[0] 恒为今天），本判断天然正确。
//

import SwiftUI

/// 主屏逐日预报区块。
/// @MainActor：与项目内其他 View 保持一致（SwiftUI 仅 body 推断主 actor，
/// 整体标注消除 init/辅助成员的非隔离盲区）。
@MainActor
struct DailyForecastSection: View {

    /// 逐日数据（由调用方保证非空；nil / 空数组的隐藏判断在 ContentView 侧）。
    let daily: [DailyForecast]

    /// 三档切换状态：默认 3 天（AC-A1-8），会话内记忆，不落盘。
    @State private var visibleDaysChoice: Int = 3

    /// 日期标签列固定宽度（iPhone SE 375pt 下不溢出，AC-A9 / F-A-8）。
    private let dateColumnWidth: CGFloat = 64

    /// 当前应展示的天数：`daily.prefix(choice)`；数组不足 16 按实际渲染（AC-A1-9）。
    private var visibleDays: [DailyForecast] {
        Array(daily.prefix(visibleDaysChoice))
    }

    /// 数据不足 4 天时切换无意义，隐藏分段控件（判据由 isExpanded 时代平移）。
    private var canToggle: Bool {
        daily.count > 3
    }

    /// 依据数据量动态可调的档位（P1-C 修复：数据不足时不应出现禁用段）。
    /// 3 天恒定可选；数据 `> 3` 天出现 7；数据 `> 7` 天出现 15。
    private var availableChoices: [Int] {
        var result = [3]
        if daily.count > 3 { result.append(7) }
        if daily.count > 7 { result.append(15) }
        return result
    }

    /// 给定数据条数时允许的最大档位（与 `availableChoices` 末端一致），
    /// 用于 `daily.count` 变化时夹紧过期的大档位选择。
    private func maxChoice(for count: Int) -> Int {
        count > 7 ? 15 : (count > 3 ? 7 : 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            rows
        }
        // P1-C 修复：数据条数变化时，若当前档位已超出可调范围（tags 动态裁剪后旧选择失效），
        // 夹紧到最大可用档位，避免 picker 选中项越界 / 残留高挡位。
        .onChange(of: daily.count) { _, newCount in
            let max = maxChoice(for: newCount)
            if visibleDaysChoice > max {
                visibleDaysChoice = max
            }
        }
    }

    // MARK: - 标题 + 三档分段控件

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("未来数天")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)

            Spacer(minLength: 8)

            if canToggle {
                choicePicker
            }
        }
    }

    /// 3/7/15 动态档位选择器：标签随 `availableChoices` 生成，恒可用的「3 天」段
    /// 永不被禁用（P1-C 修复：原 `.disabled(!canToggle)` 误伤恒可用段）。
    private var choicePicker: some View {
        Picker("展示天数", selection: $visibleDaysChoice) {
            ForEach(availableChoices, id: \.self) { choice in
                Text("\(choice) 天")
                    .tag(choice)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .accessibilityLabel("切换逐日预报展示天数")
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

//
//  DailyForecastRow.swift
//  ZhishengWeather（主 App target）
//
//  逐日预报单行子视图（A2-5，ARCH-A2P1 §1.3）：
//   - **逐行独立展开态**：@State expanded 各自持有（AC-A2-16 不联动其他行）；
//   - 展开区：该日日出/日落（A1 按日预埋）、月出月落（MoonCalculator 本地近似）、
//     UV max（A2-P0 按日预埋）——数据零新增请求；
//   - 收起恢复紧凑单行（AC-A2-17）。
//  紧凑行内容自 DailyForecastSection.row 平移而来（不复制档位逻辑——档位仍归父层）。
//
//  D-4：全部时刻/日期渲染改走 `WeatherTimeFormatter`，按**传入时区**（默认设备时区）
//  格式化，并复用其 (格式, 时区) 格式器缓存——不再持有写死设备时区的静态格式器。
//

import SwiftUI

/// 逐日预报单行（可展开）。
@MainActor
struct DailyForecastRow: View {

    let day: DailyForecast
    /// 城市纬度（月出月落计算用）。
    let latitude: Double
    /// 城市经度。
    let longitude: Double
    /// 时间渲染时区（D-4）。默认设备时区；由 DailyForecastSection / FifteenDayView
    /// 透传 VM 的 `selectedTimeZone`。声明为**默认参数**，既有调用点保持源码兼容。
    var timeZone: TimeZone = .current

    /// 本行展开态（逐行独立，AC-A2-16）。
    @State private var expanded: Bool = false

    /// 日期标签列固定宽度（与父层保持一致，iPhone SE 375pt 不溢出）。
    private let dateColumnWidth: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            compactRow
            if expanded {
                detailRows
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                expanded.toggle()
            }
        }
        .accessibilityLabel(expanded ? "收起该日详情" : "展开该日日出日落详情")
        .accessibilityHint("显示该日日出日落、月出月落与紫外线")
    }

    // MARK: - 紧凑行（自原 row 平移，逻辑零改动）

    private var compactRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(primaryLabel(for: day))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                // D-4：按本行时区渲染日期（跨日边界需与城市时区一致）。
                Text(WeatherTimeFormatter.string(from: day.date,
                                                 format: "M月d日",
                                                 timeZone: timeZone))
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

            Text(precipitationText(for: day))
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(day.precipitationProbability == nil
                                 ? Theme.secondaryText
                                 : Theme.accentSecondary)
                .lineLimit(1)

            Text(temperatureText(for: day))
                .font(.system(size: Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
        }
    }

    // MARK: - 展开详情（AC-A2-15）

    @ViewBuilder
    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 日出日落（A1 按日预埋；nil 段隐藏，AC-A1-12 降级面同源）。
            if day.sunrise != nil || day.sunset != nil {
                detailLine(icon: "sunrise.fill",
                           text: sunText(day))
            }
            // 月出月落（MoonCalculator 本地近似，A2-4 引擎复用）。
            let moon = MoonCalculator.moonEvents(for: day.date,
                                                 latitude: latitude,
                                                 longitude: longitude)
            if moon.rise != nil || moon.set != nil {
                detailLine(icon: "moon.stars.fill",
                           text: moonText(moon))
            }
            // UV max（A2-P0 按日预埋）。
            if let uv = day.uvIndexMax {
                detailLine(icon: "sun.max.fill",
                           text: "紫外线峰值 \(Int(uv.rounded()))")
            }
        }
        .padding(.leading, dateColumnWidth + 8)
    }

    private func detailLine(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Theme.accentSecondary)
                .frame(width: 16)
            Text(text)
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    // MARK: - 文案（沿用父层既有格式器风格）

    private func sunText(_ day: DailyForecast) -> String {
        var parts: [String] = []
        if let rise = day.sunrise {
            parts.append("日出 \(timeText(rise))")
        }
        if let set = day.sunset {
            parts.append("日落 \(timeText(set))")
        }
        return parts.joined(separator: " · ")
    }

    private func moonText(_ events: (rise: Date?, set: Date?)) -> String {
        var parts: [String] = []
        if let rise = events.rise {
            parts.append("月出 \(timeText(rise))")
        }
        if let set = events.set {
            parts.append("月落 \(timeText(set))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 标签（从父层平移，语义零改动）

    private func primaryLabel(for day: DailyForecast) -> String {
        Calendar.current.isDateInToday(day.date) ? "今天"
            : WeatherTimeFormatter.string(from: day.date, format: "EEE", timeZone: timeZone)
    }

    private func precipitationText(for day: DailyForecast) -> String {
        guard let probability = day.precipitationProbability else { return "--" }
        return "\(probability)%"
    }

    private func temperatureText(for day: DailyForecast) -> String {
        "\(Int(day.tempMax.rounded()))° / \(Int(day.tempMin.rounded()))°"
    }

    // MARK: - 时刻渲染（D-4：按本行时区，复用 WeatherTimeFormatter 缓存）

    /// 「HH:mm」——按本行时区渲染（`WeatherTimeFormatter` 内缓存格式器，不逐次新建）。
    private func timeText(_ date: Date) -> String {
        WeatherTimeFormatter.string(from: date, format: "HH:mm", timeZone: timeZone)
    }
}

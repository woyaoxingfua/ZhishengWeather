//
//  LargeWeatherView.swift
//  ZhishengWeatherWidget（Widget target）
//
//  Large（约 338×354）——**独立布局**，不是 Medium 的纵向拉伸：
//
//    ┌───────────────────────────────────────────────┐
//    │ 北京 · 默认城市  [⟳]          更新于 14:05     │  ← ① 头部（A1-7 刷新钮）
//    │            ☁️                                  │
//    │            23°        多云                     │  ← ② Hero：大温度 + 现象
//    │        ↑25°  ↓15°  体感 21°                    │
//    │ ─────────────────────────────────────────────  │  ← 分隔线
//    │ 未来三天                                        │  ← ③ 逐日 3 列（F-A）
//    │ ┌─────────┬─────────┬─────────┐                │     （替换原逐小时条）
//    │ │  今天    │  周三    │  周四    │               │
//    │ │   ☀️    │   🌧     │   ⛅     │               │
//    │ │ ↑25°↓15°│ ↑21°↓14°│ ↑23°↓13°│               │
//    │ └─────────┴─────────┴─────────┘                │
//    │ ─────────────────────────────────────────────  │
//    │ ┌──────────┬──────────┐                        │
//    │ │ 湿度 58% │ 3.2 m/s  │                        │  ← ④ 2×3 指标网格
//    │ ├──────────┼──────────┤                        │
//    │ │ 体感 21° │ ↑25°     │                        │
//    │ ├──────────┼──────────┤                        │
//    │ │ 风向 东南 │ ↓15°    │                        │
//    │ └──────────┴──────────┘                        │
//    └───────────────────────────────────────────────┘
//
//  F-A 布局取舍（ARCH §4.2）：逐日 3 列**整体替换**原逐小时条区域 ——
//  逐日预报是本特性核心价值，且 Medium 已覆盖「逐小时」信息；替换后区块数
//  不变、高度预算不变，对 L-1~L-7 已验收布局的扰动最小。
//  头部 / Hero / 2×3 指标网格（MetricGridLayout）全部保留。
//
//  3/7 切换**不存在于 Widget**（L-9 结构性保证）：固定 `prefix(3)`，
//  不读、不写任何展开状态 —— widget 代码里根本没有 3/7 概念。
//  （A1 后 mapper 的 daily 输出自今日起截，prefix(3) = 今天起 3 天，语义不变。）
//
//  A1-7：头部刷新 Button(intent: WidgetRefreshIntent())——openAppWhenRun
//  拉起主 App 强刷，widget 自身零网络零写入；iOS 17+ 才渲染（同源判据）。
//
//  逐日图标**一律用日间符号**：Open-Meteo `daily.time` 是当日 00:00 的 epoch，
//  现有 `isDaytime`（6:00–17:59 为昼）启发式对它必判「夜」，会产生
//  「未来三天全是月亮」的错误观感；逐日语义上以日间天气为准（ARCH §4.2 注记）。
//
//  背景经 `widgetBackground(_:)` 双写（iOS 16 / 17 兼容）。
//

import SwiftUI
import WidgetKit

struct LargeWeatherView: View {

    let entry: WeatherEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            heroSection
            divider
            dailySection
            divider
            // A2-8：逐时趋势条（4 小时，AC-A2-24）。
            hourlyTrendSection
            divider
            metricsSection
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetBackground { entry.backgroundStyle.backgroundView }
    }

    // MARK: - ① 头部（A1-7：刷新按钮）

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(cityName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)

            if isFallbackLocation {
                Text("默认城市")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text(updateText)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)

            if WidgetRuntime.isIOS17OrLater {
                refreshButton
            }
        }
    }

    /// 刷新按钮（A1-7）：点击 → openAppWhenRun 拉起主 App → 强刷 → reload。
    private var refreshButton: some View {
        Button(intent: WidgetRefreshIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("刷新天气")
    }

    // MARK: - ② Hero：大温度 + 现象 + 高低温/体感

    private var heroSection: some View {
        VStack(spacing: 6) {
            WeatherSymbol(code: weatherCode, isDay: isDay, size: 30)

            Text(temperatureText)
                .font(.system(size: 60, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            Text(conditionText)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)

            HStack(spacing: 14) {
                Text(highLowText)
                Text(apparentText)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - ③ 逐日 3 列（F-A，固定 prefix(3)，无任何 3/7 切换概念）

    private var dailySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("未来三天")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)

            if dailyPoints.isEmpty {
                Text("暂无逐日数据")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // 3 列均分（Large 内容宽约 306pt → 单列 ≈ 100pt，L-10 富余充足）。
                HStack(alignment: .top, spacing: 0) {
                    ForEach(dailyPoints) { day in
                        dailyColumn(day)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    // MARK: - 逐时趋势条（A2-8，AC-A2-24）

    /// 未来 4 小时迷你趋势（hourly 已在共享容器，Widget 只读零网络）。
    private var hourlyPoints: [HourlyPoint] {
        Array(entry.payload?.snapshot.hourly.prefix(4) ?? [])
    }

    private var hourlyTrendSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("未来四小时")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)

            if hourlyPoints.isEmpty {
                Text("暂无逐时数据")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(hourlyPoints) { point in
                        hourlyColumn(point)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    /// 单列：时刻 / 温度。
    private func hourlyColumn(_ point: HourlyPoint) -> some View {
        VStack(spacing: 3) {
            Text(WidgetTimeFormatter.hourLabel(point.time, in: timeZone))
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
            Text("\(Int(point.temperature.rounded()))°")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
        }
    }

    /// 单列：星期标签 / 图标 / 温度区间。
    private func dailyColumn(_ day: DailyForecast) -> some View {
        VStack(spacing: 5) {
            Text(dayLabel(for: day))
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)

            // 逐日图标一律日间符号（daily.time 为当日 00:00，昼夜启发式必判夜）。
            WeatherSymbol(code: day.weatherCode, isDay: true, size: 14)

            Text(temperatureRangeText(for: day))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    // MARK: - ④ 2×3 指标网格（数据源不变，MetricGridLayout 零改动）

    @ViewBuilder
    private var metricsSection: some View {
        let metrics = WeatherSnapshot.widgetMetrics(from: snapshot)
        if metrics.isEmpty {
            Text("暂无指标数据")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
        } else {
            MetricGridLayout(metrics: metrics, columns: 2, spacing: 8)
        }
    }

    // MARK: - 通用小件

    private var divider: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(height: 0.5)
    }

    // MARK: - 取值（空态安全兜底）

    private var snapshot: WeatherSnapshot? { entry.payload?.snapshot }

    /// 逐日数据源：固定取前 3 天（L-9）。不读任何展开状态。
    private var dailyPoints: [DailyForecast] {
        Array((entry.payload?.snapshot.daily ?? []).prefix(3))
    }

    private var cityName: String {
        // F-C：实例目标城市优先（固定城市无匹配快照时也显示所配城市名），
        // 回退快照 location（placeholder 预览路径）。
        entry.displayCityName ?? "—"
    }

    private var isFallbackLocation: Bool {
        snapshot?.location.isFallback == true
    }

    private var temperatureText: String {
        guard let snapshot else { return "--°" }
        return "\(Int(UnitPreference.displayTemperature(celsius: snapshot.temperature).rounded()))°"
    }

    private var conditionText: String {
        guard let snapshot else { return "暂无数据" }
        return WMOCodeMapper.description(for: snapshot.weatherCode)
    }

    private var highLowText: String {
        guard let snapshot else { return "↑--°  ↓--°" }
        return "↑\(snapshot.dailyHighText)  ↓\(snapshot.dailyLowText)"
    }

    private var apparentText: String {
        guard let snapshot else { return "体感 --°" }
        return "体感 \(snapshot.apparentTemperatureText)"
    }

    private var updateText: String {
        guard let payload = entry.payload else { return "" }
        return "更新于 \(WidgetTimeFormatter.hourMinute(payload.updatedAt, in: timeZone))"
    }

    /// D-4：时刻渲染时区 = 共享载荷携带的城市时区；缺省 → 设备时区。
    private var timeZone: TimeZone { WidgetTimeFormatter.timeZone(for: entry.payload) }

    private var weatherCode: Int {
        snapshot?.weatherCode ?? -1
    }

    private var isDay: Bool {
        snapshot?.isDay ?? true
    }

    /// 列标签：今天 → 「今天」；其余 → 「周三」等。
    /// 判断基于快照内日期与 `Calendar.isDateInToday`（UI 层允许 Calendar.current，
    /// 先例见原 HourlyStrip 的昼夜启发式），不构造当前时刻 Date。
    private func dayLabel(for day: DailyForecast) -> String {
        Calendar.current.isDateInToday(day.date) ? "今天"
            : WidgetTimeFormatter.weekdayShort(day.date, in: timeZone)
    }

    /// 「↑25° ↓15°」。
    private func temperatureRangeText(for day: DailyForecast) -> String {
        "↑\(Int(UnitPreference.displayTemperature(celsius: day.tempMax).rounded()))° ↓\(Int(UnitPreference.displayTemperature(celsius: day.tempMin).rounded()))°"
    }
}
//
//  SmallWeatherView.swift
//  ZhishengWeatherWidget（Widget target）
//
//  Small（约 155×155）：城市 / 图标 / 大字温度 / 现象 / 更新时间。
//  空态：温度显示 `--°`，图标用问号兜底，现象位与提示行由 `WidgetCopy` 给出
//  （单一真源；「没取过数」「取不到」「没配城市」文案各不相同，且给出下一步）。
//
//  提示行只在**空态**出现（`WidgetCopy.hintText` 有载荷时恒为 nil）
//  → 数据路径布局与提示行引入前完全一致（无溢出风险）。
//
//  背景经 `widgetBackground(_:)` 双写：iOS 17 走
//  `containerBackground(for: .widget)`，iOS 16.x 退回 padding + background。
//

import SwiftUI
import WidgetKit

struct SmallWeatherView: View {

    let entry: WeatherEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(cityName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)

            Spacer(minLength: 0)

            HStack {
                Spacer(minLength: 0)
                WeatherSymbol(code: weatherCode, isDay: isDay, size: 26)
            }

            Text(temperatureText)
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            Spacer(minLength: 0)

            HStack(alignment: .bottom, spacing: 4) {
                Text(conditionText)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(timeText)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }

            // 空态可操作提示（§13）：仅空态出现，绝不改变有数据时的布局。
            if let hintText {
                Text(hintText)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetBackground { entry.backgroundStyle.backgroundView }
    }

    // MARK: - 取值（空态安全兜底；状态文案一律走 WidgetCopy 单一真源）

    private var snapshot: WeatherSnapshot? { entry.payload?.snapshot }

    private var cityName: String {
        // 实例目标城市优先（固定城市无匹配快照时也显示所配城市名），
        // 回退快照 location（placeholder 预览路径）。
        entry.displayCityName ?? "—"
    }

    private var temperatureText: String {
        guard let snapshot else { return "--°" }
        return "\(Int(UnitPreference.displayTemperature(celsius: snapshot.temperature).rounded()))°"
    }

    /// 现象位（有数据 → WMO 描述；空态 → `WidgetCopy` 的如实状态句）。
    private var conditionText: String {
        WidgetCopy.conditionText(resolution: entry.resolution)
    }

    /// 时间位；空态返回空串：状态句已由现象位与提示行承担，
    /// 同一行内不重复渲染同一句话（Small 的底行两个文案并排）。
    private var timeText: String {
        guard let formattedTime else { return "" }
        return WidgetCopy.updateText(resolution: entry.resolution, timeText: formattedTime)
    }

    /// 已格式化的「HH:mm」；无载荷 → nil（Core 的 `WidgetCopy` 不碰格式化，
    /// 见该文件「时刻格式化的边界」说明）。
    private var formattedTime: String? {
        guard let payload = entry.payload else { return nil }
        return WidgetTimeFormatter.hourMinute(payload.updatedAt, in: timeZone)
    }

    /// 空态可操作提示；有载荷 → nil。
    private var hintText: String? {
        WidgetCopy.hintText(resolution: entry.resolution)
    }

    /// D-4：时刻渲染时区 = 载荷携带的城市时区；缺省 → 设备时区。
    private var timeZone: TimeZone { WidgetTimeFormatter.timeZone(for: entry.payload) }

    private var weatherCode: Int {
        snapshot?.weatherCode ?? -1
    }

    private var isDay: Bool {
        snapshot?.isDay ?? true
    }
}

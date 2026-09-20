//
//  HistoricalWeatherView.swift
//  ZhishengWeather（主 App target）
//
//  历史天气页（A3-1，AC-A3-1/2/3）：
//   - 近 7 日高低温条形 + 现象图标 + 降水量；
//   - 进入时拉取（独立第三链路，失败页内降级"暂无数据 + 重试"，不反噬主屏）；
//   - 页脚固定声明"再分析资料（ERA5），非实况观测"（AC-A3-3）。
//

import SwiftUI

/// 历史天气页。
@MainActor
struct HistoricalWeatherView: View {

    let latitude: Double
    let longitude: Double
    /// 历史取数服务（预览/测试可注入 Stub）。
    var archiveService: ArchiveProviding = ArchiveService()

    /// 加载状态。
    @State private var phase: Phase = .loading
    /// 近 7 日起止（yyyy-MM-dd）——进入时由 now 推导一次。
    @State private var dateRange: (start: String, end: String)?

    enum Phase {
        case loading
        case loaded(HistoricalWeather)
        case failure
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(Theme.accent)
                    Text("正在获取历史天气…")
                        .font(.system(size: Theme.FontSize.metric))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .loaded(let historical):
                listView(historical)

            case .failure:
                VStack(spacing: 16) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.secondaryText)
                    Text("历史天气获取失败")
                        .font(.system(size: Theme.FontSize.metric, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                    Button("重试") {
                        Task { await load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("过去 7 日")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - 列表

    private func listView(_ historical: HistoricalWeather) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if historical.days.isEmpty {
                    Text("暂无历史数据")
                        .font(.system(size: Theme.FontSize.metric))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else {
                    ForEach(historical.days) { day in
                        dayRow(day)
                    }
                    // ERA5 资料声明（AC-A3-3）。
                    Text(HistoricalWeather.dataSourceNotice)
                        .font(.system(size: Theme.FontSize.caption))
                        .foregroundStyle(Theme.secondaryText.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    /// 单日行：日期 + 现象图标 + 高低温条形 + 降水量。
    private func dayRow(_ day: HistoricalDay) -> some View {
        HStack(spacing: 10) {
            Text(day.dateString)
                .font(.system(size: Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 80, alignment: .leading)

            if let code = day.weatherCode {
                WeatherSymbol(code: code, isDay: true, size: 16)
            }

            // 高低温条形：以 7 日内极值为标尺（相对比较，非绝对温标）。
            GeometryReader { proxy in
                let range = historicalRange
                let low = day.tempMin ?? range.min
                let high = day.tempMax ?? range.max
                let span = max(range.max - range.min, 1)
                let offset = ((low - range.min) / span) * proxy.size.width
                let width = max(((high - low) / span) * proxy.size.width, 6)
                Capsule()
                    .fill(
                        LinearGradient(colors: [Color(red: 0.35, green: 0.62, blue: 0.90),
                                                Color(red: 0.95, green: 0.56, blue: 0.20)],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: width, height: 6)
                    .offset(x: offset)
            }
            .frame(height: 6)

            // 温度 + 日降水合计（P2 补渲染）：模型 `HistoricalDay.precipitationSum` 与
            // 请求面早就有值，但页面上从未有落点（本函数头部注释写了"降水量"却一直没画）。
            // **竖排**而非再加一列：本行已有 日期(80) + 图标(16) + 条形(flex)，375pt 窄屏
            // 再加固定列会挤压条形（AC-A3 同款布局纪律）。
            VStack(alignment: .trailing, spacing: 1) {
                Text(temperatureText(day))
                    .font(.system(size: Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(precipitationText(day))
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(day.precipitationSum == nil
                                     ? Theme.secondaryText
                                     : Theme.accentSecondary)
            }
            .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// 7 日内温度极值（条形标尺）。
    private var historicalRange: (min: Double, max: Double) {
        var values: [Double] = []
        if case .loaded(let historical) = phase {
            for day in historical.days {
                if let lo = day.tempMin { values.append(lo) }
                if let hi = day.tempMax { values.append(hi) }
            }
        }
        guard let min = values.min(), let max = values.max() else {
            return (0, 1)
        }
        return (min, max)
    }

    private func temperatureText(_ day: HistoricalDay) -> String {
        let high = day.tempMax.map { Int($0.rounded()) }.map(String.init) ?? "--"
        let low = day.tempMin.map { Int($0.rounded()) }.map(String.init) ?? "--"
        return "\(high)° / \(low)°"
    }

    /// 日降水合计（mm）。走共享纯格式化器（同类量单一入口，避免又一份内联 `String(format:)`）。
    ///
    /// 诚实纪律：`nil` → `--`（**绝不显示 0**）；`0.0 mm` 是合法值（"那天没下雨"），
    /// 由格式化器如实呈现，**不隐藏**、不冒充缺失。
    private func precipitationText(_ day: HistoricalDay) -> String {
        guard let sum = day.precipitationSum else { return "--" }
        return PrecipitationFormatter.text(fromMillimeters: sum)
    }

    // MARK: - 加载

    private func load() async {
        phase = .loading
        // 近 7 日 = [today-7, today-1]（Archive API 数据有 ~5 天滞后，往前多留余量）。
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        guard let end = calendar.date(byAdding: .day, value: -6, to: now),
              let start = calendar.date(byAdding: .day, value: -13, to: now) else {
            phase = .failure
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let startString = formatter.string(from: start)
        let endString = formatter.string(from: end)
        dateRange = (startString, endString)

        // 诊断：archive 链路上报（纯追加，不改失败隔离）。
        await LinkHealthRecorder.shared.recordAttempt(.archive, at: Date())
        do {
            let historical = try await archiveService.fetch(latitude: latitude,
                                                            longitude: longitude,
                                                            startDate: startString,
                                                            endDate: endString)
            await LinkHealthRecorder.shared.recordSuccess(.archive, at: Date())
            phase = .loaded(historical)
        } catch {
            await LinkHealthRecorder.shared.recordFailure(.archive, at: Date(),
                                                          message: error.localizedDescription)
            phase = .failure
        }
    }
}

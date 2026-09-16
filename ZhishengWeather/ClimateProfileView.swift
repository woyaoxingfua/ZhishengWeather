//
//  ClimateProfileView.swift
//  ZhishengWeather（主 App target）
//
//  个人气候档案页：展示去年今日、近 5 年 / 10 年同日统计与 10 年 mini 柱状图。
//  纯 SwiftUI 自绘图形，不引入图表依赖。
//  用户进入本页时才触发网络请求，不随主屏刷新自动拉取。
//

import SwiftUI

/// 个人气候档案页。
@MainActor
struct ClimateProfileView: View {

    let city: City
    /// 今年今日最高温（来自主天气快照），用于计算差值。
    let currentYearHigh: Double?
    /// 取数服务（预览/测试可注入 Stub）。
    var service: ClimateProfileProviding = ClimateProfileService()

    /// 页面状态。
    @State private var phase: Phase = .loading

    enum Phase {
        case loading
        case loaded(ClimateProfile)
        case failure
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                loadingView
            case .loaded(let profile):
                content(profile)
            case .failure:
                failureView
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("气候档案")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - 加载状态

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(Theme.accent)
            Text("正在获取气候档案…")
                .font(.system(size: Theme.FontSize.metric))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var failureView: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 32))
                .foregroundStyle(Theme.secondaryText)
            Text("气候档案获取失败")
                .font(.system(size: Theme.FontSize.metric, weight: .medium))
                .foregroundStyle(Theme.primaryText)
            Button("重试") {
                Task { await load() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 内容

    private func content(_ profile: ClimateProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                lastYearCard(profile)
                fiveYearCard(profile)
                tenYearChart(profile)

                Text(dataSourceNotice)
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func lastYearCard(_ profile: ClimateProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("去年今日")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            if let lastYear = profile.sameDateLastYear, let high = lastYear.tempMax {
                let highText = temperatureText(high)
                let deltaText: String = {
                    guard let current = currentYearHigh else { return "" }
                    return "（今天 \(temperatureText(current))℃，\(deltaString(current - high))）"
                }()
                Text("最高 \(highText)℃\(deltaText)")
                    .font(.system(size: Theme.FontSize.metric))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                Text("暂无有效数据")
                    .font(.system(size: Theme.FontSize.metric))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private func fiveYearCard(_ profile: ClimateProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("近 5 年同日平均最高")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            if let average = profile.fiveYearAverageHigh {
                let deltaText = profile.fiveYearHighDelta.map { "（较今年 \(deltaString($0))）" } ?? ""
                Text("\(String(format: "%.1f", average))℃\(deltaText)")
                    .font(.system(size: Theme.FontSize.metric))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                Text("样本不足")
                    .font(.system(size: Theme.FontSize.metric))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private func tenYearChart(_ profile: ClimateProfile) -> some View {
        let snapshots = profile.sameDateLast10Years ?? []
        let values = chartRange(for: snapshots)
        return VStack(alignment: .leading, spacing: 10) {
            Text("近 10 年同日最高温")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.primaryText)

            if snapshots.isEmpty {
                Text("暂无数据")
                    .font(.system(size: Theme.FontSize.metric))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                GeometryReader { proxy in
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(snapshots.sorted(by: { $0.year < $1.year })) { snapshot in
                            bar(snapshot, values: values, availableHeight: proxy.size.height)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .frame(height: 160)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private func bar(_ snapshot: DailyClimateSnapshot,
                     values: (min: Double, max: Double),
                     availableHeight: CGFloat) -> some View {
        let span = max(values.max - values.min, 1)
        let drawingHeight = max(availableHeight - 16, 1)

        return VStack(spacing: 2) {
            if let maxTemp = snapshot.tempMax {
                let barHeight = CGFloat((maxTemp - values.min) / span) * drawingHeight
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(colors: [Color(red: 0.35, green: 0.62, blue: 0.90),
                                                Color(red: 0.95, green: 0.56, blue: 0.20)],
                                       startPoint: .bottom, endPoint: .top)
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: max(barHeight, 4))
            } else {
                Spacer()
                    .frame(maxWidth: .infinity)
            }
            Text(String(snapshot.year % 100))
                .font(.system(size: 9))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    /// 计算 10 年样本的最低/最高温，用于归一化柱高。
    private func chartRange(for snapshots: [DailyClimateSnapshot]) -> (min: Double, max: Double) {
        let highs = snapshots.compactMap(\.tempMax)
        guard let min = highs.min(), let max = highs.max() else { return (0, 1) }
        return (min, max)
    }

    // MARK: - 加载

    private func load() async {
        phase = .loading
        let today = Date()
        do {
            let profile = try await service.fetch(city: city,
                                                  today: today,
                                                  now: today,
                                                  currentYearHigh: currentYearHigh)
            phase = .loaded(profile)
        } catch {
            phase = .failure
        }
    }

    // MARK: - 格式化

    private func temperatureText(_ celsius: Double) -> String {
        "\(Int(celsius.rounded()))"
    }

    /// 温差字符串，始终带符号，例如 "+7℃"、"−5.6℃"、"±0℃"。
    private func deltaString(_ delta: Double) -> String {
        let sign = delta > 0 ? "+" : (delta < 0 ? "−" : "±")
        return "\(sign)\(String(format: "%.1f", abs(delta)))℃"
    }

    /// 资料来源声明：沿用 HistoricalWeatherView 的“再分析资料，非实况观测”并补 IFS 说明。
    private var dataSourceNotice: String {
        "再分析资料，非实况观测；默认模型含 IFS，可能与 ERA5 有差异"
    }
}

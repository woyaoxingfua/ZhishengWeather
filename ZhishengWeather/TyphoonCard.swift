//
//  TyphoonCard.swift
//  ZhishengWeather（主 App target）
//
//  台风卡（**主屏装配入口**）：活跃台风列表 + 详情（路径线 + 强度 + 官方预报）。
//
//  ── 装配契约 ──────────────────────────────────────────────────────
//  · 状态由 `TyphoonCardModel` 提供（`@Observable`），本视图**只渲染，不判定**；
//  · 四态（`.idle` / `.none` / `.active` / `.unavailable`）
//    **全部**必须渲染出**可见内容**，**绝不允许**空白页或无限转圈。
//
//  ── 🔴 空态的硬要求（任务书明令）────────────────────────────────────
//  **没有台风时要如实显示「当前无活跃台风」，绝不显示空白或编造。**
//  故 `.none` 分支渲染**确定的文字**；`.unavailable` 分支渲染**另一套**
//  文字（「取不到」+ 重试）。两者**绝不共用一句话** —— 共用就把
//  「取不到」说成了「没有」，那是内容错误（见 `TyphoonCardModel` 文件头）。
//
//  ── 坐标序 ────────────────────────────────────────────────────────
//  本视图展示的经纬度全部来自 `TyphoonTrackPoint.longitude`/`.latitude`
//  （**经度在前**，由 Core mapper 保证）。此处**只做展示**，
//  绝不做任何二次换算 —— 换算是Core 的职责，视图层重算一遍就多一处
//  能写反的地方。
//

import SwiftUI

/// 台风卡（列表 + 详情）。
///
/// ⚠️ **本类型带类型级 `@MainActor`**（本仓纪律：每个 `struct ... : View` 都带）。
@MainActor
struct TyphoonCard: View {

    /// 状态容器（四态、详情、年份选择的唯一真源）。
    let model: TyphoonCardModel

    /// 当前年份（**注入**，视图不读 `Date()`；单测可固定）。
    var currentYear: Int

    /// 本卡折叠态（初值读持久化；点标题行右侧按钮翻转）。
    @State private var isCollapsed: Bool = CardVisibilityStore.isCollapsed(.typhoon)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            // 折叠态：只保留标题行，年份选择器与四态内容全部不渲染。
            if !isCollapsed {
                yearPicker
                content
            }
        }
        .padding(12)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: Theme.cornerRadius,
                                         style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(Theme.divider, lineWidth: 0.5)
        )
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "tornado")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("台风路径")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Spacer(minLength: 0)
            if model.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
            }
            CardCollapseButton(card: .typhoon, isCollapsed: isCollapsed, onToggle: toggleCollapse)
        }
    }

    // MARK: - 折叠切换

    /// 翻转折叠态：落库 + 改本地状态（动画与图标统一由 `CardCollapseButton` 驱动）。
    private func toggleCollapse() {
        let next = CardCollapseButton.toggleCollapsed(.typhoon)
        withAnimation(.easeInOut(duration: 0.15)) {
            isCollapsed = next
        }
    }

    // MARK: - 年份选择

    /// 年份选择（nil = 当前活跃台风；其余为历史年份）。
    ///
    /// ⚠️ 选项来自 `TyphoonCardModel.selectableYears`（下界1950 = 实测可回溯年份）。
    private var yearPicker: some View {
        Picker("台风年份", selection: Binding(
            get: { model.selectedYear ?? 0 },
            set: { newValue in
                Task { await model.load(year: newValue == 0 ? nil : newValue) }
            }
        )) {
            // 0 是「当前活跃台风」的哨兵值（nil 的Picker 载体）。
            Text("当前").tag(0)
            ForEach(TyphoonCardModel.selectableYears(currentYear: currentYear), id: \.self) {
                Text("\(String($0))年").tag($0)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - 四态内容

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            // `.idle` 只在首次加载前出现（`isLoading` 独立显示）。
            Text("尚未加载")
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.secondaryText)
        case .none:
            // 🔴 硬要求：如实显示「当前无活跃台风」，**绝不空白、绝不编造**。
            emptyState(icon: "checkmark.circle",
                       title: "当前无活跃台风",
                       detail: "中央气象台台风网当前未发布进行中的台风。")
        case .active(let summaries):
            listView(summaries)
        case .unavailable(let message):
            // 🔴 与 `.none` **必须是不同的文案**（「取不到」≠「没有」）。
            emptyState(icon: "exclamationmark.triangle",
                       title: "台风数据取不到",
                       detail: message)
        }
    }

    // MARK: - 列表

    private func listView(_ summaries: [TyphoonSummary]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(summaries) { summary in
                Button {
                    Task { await model.loadDetail(for: summary) }
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.displayName)
                                .font(.system(size: Theme.FontSize.condition,
                                              weight: .semibold))
                                .foregroundStyle(Theme.primaryText)
                            // ⚠️ 中文名可能缺失（实测早年台风为 null）→ 如实显示英文名，
                            // 绝不显示空白（那会被读成"加载中"）。
                            if let english = summary.englishName, english != summary.displayName {
                                Text(english)
                                    .font(.system(size: Theme.FontSize.caption))
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                        Spacer(minLength: 0)
                        if let number = summary.number {
                            Text(number)
                                .font(.system(size: Theme.FontSize.caption))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .buttonStyle(.plain)
            }
            detailSection
        }
    }

    // MARK: - 详情

    @ViewBuilder
    private var detailSection: some View {
        if model.detailFailed {
            // ⚠️ 取不到详情：如实显示，**不留空白**。
            Text("台风路径详情取不到")
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.secondaryText)
        } else if let track = model.detail {
            VStack(alignment: .leading, spacing: 10) {
                currentSummary(track)
                TyphoonMapCard(track: track)
                forecastSection(track)
                attributionNote
            }
        }
    }

    /// 当前强度摘要（路径 + 预报）。
    private func currentSummary(_ track: TyphoonTrack) -> some View {
        let latest = track.latestPoint
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(track.summary.displayName) · 当前实况")
                .font(.system(size: Theme.FontSize.condition, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            if let latest {
                // ⚠️ 每个字段都可能缺测（逐字段 nil）→ 逐项判空，
                // 缺的那项**不显示**（而不是显示 0 / "0"）。
                HStack(spacing: 10) {
                    if let intensity = latest.intensity {
                        metric("强度", intensity.displayName)
                    }
                    if let pressure = latest.pressureHPa {
                        metric("气压", "\(Int(pressure)) hPa")
                    }
                    if let wind = latest.maxWindSpeedMS {
                        metric("风速", "\(Int(wind)) m/s")
                    }
                }
                if let motion = latest.motion {
                    Text("移动：\(motion.displayName)"
                         + (latest.motionSpeedKmh.map { " · \(Int($0)) km/h" } ?? ""))
                        .font(.system(size: Theme.FontSize.caption))
                        .foregroundStyle(Theme.secondaryText)
                }
                // 风圈（实测最多 3 层；如实用km）。
                if !latest.windCircles.isEmpty {
                    let circles = latest.windCircles.compactMap { circle -> String? in
                        guard let radius = circle.maxRadiusKm else { return nil }
                        return "\(circle.displayName) \(Int(radius)) km"
                    }
                    if !circles.isEmpty {
                        Text("风圈：" + circles.joined(separator: " · "))
                            .font(.system(size: Theme.FontSize.caption))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                // 发布时间（实测下标 12 的北京时间文本；**仅展示**，不参与计算）。
                if let issued = latest.beijingTimeText {
                    Text("发布：\(issued)")
                        .font(.system(size: Theme.FontSize.footnote))
                        .foregroundStyle(Theme.secondaryText)
                }
            } else {
                // ⚠️ 有台风但**一个路径点都没解出来** → 必须说清楚，
                // 绝不让用户以为"图上什么都没有"。
                Text("该台风暂无可解析的路径点")
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    /// 官方预报（BABJ）。
    ///
    /// ⚠️ 实测**历史台风没有预报**（下标 11 为 null）→ 此时显示
    /// 「无官方预报」，**绝不**编造一条。
    private func forecastSection(_ track: TyphoonTrack) -> some View {
        let forecasts = track.latestForecast
        return VStack(alignment: .leading, spacing: 4) {
            Text("官方预报（中央气象台）")
                .font(.system(size: Theme.FontSize.metric, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            if forecasts.isEmpty {
                Text("无官方预报")
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                // ⚠️ 实测时效**不固定**（可能 8 个，也可能只剩 1 个）→ 逐条列出。
                ForEach(Array(forecasts.enumerated()), id: \.offset) { _, point in
                    HStack(spacing: 8) {
                        Text(point.leadHours.map { "\($0) 小时" } ?? "时效未知")
                            .font(.system(size: Theme.FontSize.caption))
                            .foregroundStyle(Theme.primaryText)
                        if let intensity = point.intensity {
                            Text(intensity.displayName)
                                .font(.system(size: Theme.FontSize.caption))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Spacer(minLength: 0)
                        if let pressure = point.pressureHPa {
                            Text("\(Int(pressure)) hPa")
                                .font(.system(size: Theme.FontSize.footnote))
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            }
        }
    }

    /// 数据说明（**如实告知延迟与来源性质**）。
    private var attributionNote: some View {
        Text("数据来源：中央气象台台风网，实测约有 3 小时延迟；该接口为网站前端数据、非承诺的开放 API。")
            .font(.system(size: Theme.FontSize.footnote))
            .foregroundStyle(Theme.secondaryText)
    }

    // MARK: - 小工具

    /// 一个「标签 + 值」小格。
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
            Text(value)
                .font(.system(size: Theme.FontSize.metric))
                .foregroundStyle(Theme.primaryText)
        }
    }

    /// 空态（**必须有可见文字**，绝不留空白）。
    private func emptyState(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: Theme.FontSize.condition))
                .foregroundStyle(Theme.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: Theme.FontSize.metric))
                    .foregroundStyle(Theme.primaryText)
                Text(detail)
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
    }
}
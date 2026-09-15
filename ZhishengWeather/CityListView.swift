//
//  CityListView.swift
//  ZhishengWeather（主 App target）
//
//  F-B 城市列表页（PRD §3.6 线框）：
//  拖动排序（.onMove）/ 左滑删除（.onDelete）/ 点选切换 / 选中 ✓ / 每行最近温度 / 底部提示。
//
//  纪律：
//  - 仅剩 1 项时删除动作给出"至少保留一个城市"提示且不执行（AC-B11 / F-B-9，
//    目录层 CityDirectory.remove 也有 no-op 双保险）。
//  - 每行温度取自 VM 会话缓存 snapshotsByCity（AC-B16），无则 "--"（冷启动）。
//  - 排序 / 删除 / 切换全部经 VM 落盘（PRD §3.4：仅显式操作时写共享容器）。
//

import SwiftUI

/// 城市列表页。
/// @MainActor：SwiftUI 只对 body 推断主 actor 隔离，init 与辅助成员
/// 默认非隔离，触碰 @MainActor 的 ViewModel/搜索模型会挂编译（CI 实测）。
/// SwiftUI 本就在主 actor 上构建/更新视图，整体标注是官方推荐模式。
@MainActor
struct CityListView: View {

    /// 共享的视图模型（目录状态 + 动作）。
    let viewModel: WeatherViewModel

    /// 搜索页状态机（进入搜索页时惰性创建，provider 注入生产实现）。
    @State private var searchModel: CitySearchModel

    /// "至少保留一个城市"提示的瞬时可见性。
    @State private var showMinimumHint: Bool = false
    /// 提示自动消失任务。
    @State private var minimumHintTask: Task<Void, Never>?

    init(viewModel: WeatherViewModel) {
        self.viewModel = viewModel
        _searchModel = State(initialValue: CitySearchModel(provider: GeocodingService()))
    }

    var body: some View {
        List {
            ForEach(viewModel.directory.cities) { city in
                row(city)
            }
            .onMove { offsets, toOffset in
                viewModel.moveCities(fromOffsets: offsets, toOffset: toOffset)
            }
            .onDelete { offsets in
                handleDelete(offsets)
            }
            .listRowBackground(Theme.surface)
            .listRowSeparatorTint(Theme.divider)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("城市管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    CitySearchView(searchModel: searchModel,
                                   onPick: { city in
                                       Task { await viewModel.addAndSelect(city) }
                                   })
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
                .accessibilityLabel("添加城市")
            }
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
        }
        .safeAreaInset(edge: .bottom) {
            footer
        }
    }

    // MARK: - 城市行

    /// 单行：名称 + 国家/省份 + 最近温度 + 选中 ✓。
    private func row(_ city: City) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(city.name)
                        .font(.system(size: Theme.FontSize.metric, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    if city.isCurrentLocation {
                        Image(systemName: "location.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.accentSecondary)
                    }
                }
                Text(subtitle(for: city))
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // AC-B16：会话内"最近一次已知温度"，无则 "--"（冷启动）。
            Text(temperatureText(for: city))
                .font(.system(size: Theme.FontSize.metric, weight: .medium))
                .foregroundStyle(Theme.accent)
                .lineLimit(1)

            if viewModel.directory.selectedID == city.id {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("当前选中")
            }

            // A2-6：收藏星标按钮（☆/★）。点击只切换收藏，不触发选中。
            Button {
                viewModel.toggleFavorite(city.id)
            } label: {
                Image(systemName: city.isFavorite == true ? "star.fill" : "star")
                    .font(.system(size: 14))
                    .foregroundStyle(city.isFavorite == true ? Color(red: 0.95, green: 0.78, blue: 0.24) : Theme.secondaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(city.isFavorite == true ? "取消收藏" : "收藏")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await viewModel.select(city.id) }
        }
    }

    // MARK: - 删除

    /// 左滑删除：仅剩 1 项时给出提示且不执行（AC-B11）。
    private func handleDelete(_ offsets: IndexSet) {
        guard viewModel.directory.cities.count > 1 else {
            triggerMinimumHint()
            return
        }
        let ids = offsets.compactMap { index -> String? in
            guard viewModel.directory.cities.indices.contains(index) else { return nil }
            return viewModel.directory.cities[index].id
        }
        Task {
            for id in ids {
                await viewModel.remove(id)
            }
        }
    }

    /// "至少保留一个城市"提示：显示 2 秒后自动消失。
    /// 注意：方法名不能与 @State 属性 `showMinimumHint` 同名（CI 实测会触发
    /// invalid redeclaration），故方法用 trigger 前缀区分。
    private func triggerMinimumHint() {
        minimumHintTask?.cancel()
        showMinimumHint = true
        minimumHintTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            showMinimumHint = false
        }
    }

    // MARK: - 底部提示

    private var footer: some View {
        VStack(spacing: 4) {
            if showMinimumHint {
                Text("至少保留一个城市")
                    .font(.system(size: Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.accentSecondary)
            } else {
                Text("拖动排序 · 左滑删除 · 点击切换")
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Theme.background)
    }

    // MARK: - 取值

    /// 副标题：country · admin1（nil 安全，绝不渲染 "null"，AC-B20）；
    /// 两者都缺 → IANA 时区或 "--"。
    private func subtitle(for city: City) -> String {
        var parts: [String] = []
        if let country = city.country { parts.append(country) }
        if let admin1 = city.admin1 { parts.append(admin1) }
        if parts.isEmpty, let timeZone = city.timeZoneIdentifier {
            parts.append(timeZone)
        }
        return parts.isEmpty ? "--" : parts.joined(separator: " · ")
    }

    /// 「23°」或「--」（AC-B16）。
    private func temperatureText(for city: City) -> String {
        guard let snapshot = viewModel.snapshotsByCity[city.id] else { return "--" }
        return "\(Int(snapshot.temperature.rounded()))°"
    }
}

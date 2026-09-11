//
//  CitySearchView.swift
//  ZhishengWeather（主 App target）
//
//  F-B 搜索页（PRD §3.6 线框）：输入框 + 四态渲染（idle/loading/results/empty/failure）。
//
//  纪律：
//  - 结果行 nil 安全：admin1 缺 → 只显示 country；两者都缺 → 显示经纬度；
//    **绝不出现 "null"**（AC-B20）。
//  - 空态与失败态**措辞区分**（AC-B19 vs AC-B17）：
//    empty = "未找到匹配城市"（搜索成功但无命中）；failure = "网络不可用，搜索失败" + 重试。
//  - 点选结果行 → onPick（VM addAndSelect）+ pop 返回。
//

import SwiftUI

/// 城市搜索页。
/// @MainActor：同 CityListView——SwiftUI 仅 body 推断主 actor，
/// init/辅助成员需整体标注才能合法触碰 @MainActor 的 CitySearchModel。
@MainActor
struct CitySearchView: View {

    /// 搜索状态机（由列表页构造并注入 provider）。
    let searchModel: CitySearchModel
    /// 点选回调（VM 侧 addAndSelect）。
    let onPick: (City) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            content
            Spacer(minLength: 0)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("添加城市")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 输入框

    private var searchField: some View {
        TextField("输入城市名，如：杭州", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .submitLabel(.search)
            .autocorrectionDisabled()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .onChange(of: searchText) { _, newValue in
                searchModel.queryChanged(newValue)
            }
    }

    // MARK: - 四态渲染

    @ViewBuilder
    private var content: some View {
        switch searchModel.phase {
        case .idle:
            Text("输入城市名开始搜索")
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 16)
                .padding(.top, 24)

        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Theme.accent)
                Text("正在搜索…")
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 32)

        case .results(let cities):
            resultsList(cities)

        case .empty:
            // AC-B19：搜索成功但无命中，与失败态措辞严格区分。
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundStyle(Theme.secondaryText)
                Text("未找到匹配城市")
                    .font(.system(size: Theme.FontSize.metric, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                Text("换个名字试试，或检查输入是否正确")
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)

        case .failure:
            // AC-B17：网络/服务失败 + 重试。
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 32))
                    .foregroundStyle(Theme.secondaryText)
                Text("网络不可用，搜索失败")
                    .font(.system(size: Theme.FontSize.metric, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                Button {
                    searchModel.retry()
                } label: {
                    Text("重试")
                        .font(.system(size: Theme.FontSize.metric, weight: .semibold))
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Theme.accent, in: Capsule())
                }
                .accessibilityLabel("重新搜索")
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
        }
    }

    // MARK: - 结果列表

    private func resultsList(_ cities: [City]) -> some View {
        List(cities) { city in
            Button {
                onPick(city)
                dismiss()
            } label: {
                resultRow(city)
            }
            .buttonStyle(.plain)
            .listRowBackground(Theme.surface)
            .listRowSeparatorTint(Theme.divider)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// 结果行：名称 + country·admin1（nil 安全拼接）+ 经纬度。
    private func resultRow(_ city: City) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.accentSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(city.name)
                    .font(.system(size: Theme.FontSize.metric, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(subtitle(for: city))
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(String(format: "%.2f, %.2f", city.latitude, city.longitude))
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: - 取值

    /// 副标题：country · admin1（nil 安全）；两者都缺 → "--"（绝不渲染 "null"，AC-B20）。
    private func subtitle(for city: City) -> String {
        var parts: [String] = []
        if let country = city.country { parts.append(country) }
        if let admin1 = city.admin1 { parts.append(admin1) }
        return parts.isEmpty ? "--" : parts.joined(separator: " · ")
    }
}

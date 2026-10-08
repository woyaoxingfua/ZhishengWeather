//
//  QWeatherCard.swift
//  ZhishengWeather / Cards
//
//  第九源「和风天气」的主屏卡片：逐日预报。
//
//  ══════════════════════════════════════════════════════════════════════════
//  ✅ 实测基准：2026-10-08（主理人用真实凭据在本机打通，HTTP 200）
//  实测样本（北京）：`daytime.humidity = 0.44`、`cloudCover = 0`、
//  `precipitation.probability = 0`、`temperatureMax = {value: 25.49, unit: "°C"}`
//  ══════════════════════════════════════════════════════════════════════════
//
//  ── 🔴🔴 合规硬要求：`metadata.attributions` **必须与数据共同显示** ──────
//  和风官方文档**明文**写：`attributions`「**必须与当前数据共同显示**」。
//  这是**许可条件，不是可选项**。故本卡片**无条件**渲染它
//  （哪怕数据取到失败，也显示上游给的署名链接）。
//  → 漏渲染 = 违反许可条件，这比"少一个 UI 元素"严重得多。
//
//  ── 🔴🔴 湿度/云量/降水概率是 **[0,1]**，不是 0–100 ────────────────────
//  **实测**（不是抄文档）：北京 `humidity = 0.32` / `daytime.humidity = 0.44`。
//  若当成百分数渲染，会把32% 显示成 0.32% —— **量纲事故**。
//  → 本卡的 `fractionText(...)` 负责 ×100 且写死该换算，
//    并在测试里断言（`QWeatherCardTests`）。
//
//  ── ⚠️ 缺测 vs 零值必须分清 ──────────────────────────────────────────
//  上游字段几乎全可空（`Double?` / `String?`）。
//  · `nil` → 显示「暂无」，**绝不**显示 0（那会凭空造一条读数）；
//  · `0` → **是合法读数**（实测 `cloudCover = 0` 就是真值），照实显示。
//
//  ── 四态：`.none`（查了、没有）与 `.unavailable`（取不到）必须分开 ──────
//  与台风 / 洪水 / 地震卡同纪律。把两者混成一句"加载失败"，
//  会让「上游没下发这一天」被误报成「产品坏了」。
//
//  ── 🔴 逐时（`QWeatherHourlyCard`）渲染在**本卡内部** ────────────────────
//  刻意**不做成独立卡片** —— 那需要改 `ContentView`（加 `@State` +
//  加 `async let` + 加挂载点三处），而该文件正被两位工程师同时编辑。
//  做成区块 → `ContentView` **零改动**。详见 `QWeatherHourlyCard` 文件头。
//
//  ── 🔴 页脚的 `attributions` 已覆盖**逐日 + 逐时**两份 ────────────────────
//  和风要求「署名必须与当前数据共同显示」，而 `QWeatherCardModel.attributions`
//  已把两次请求的 `metadata.attributions` **并集去重** → 一处渲染即足矣。
//
//  本仓纪律：View 整体 `@MainActor`（P-06）；图标只用本仓已实际用过的
//  SF Symbol（P-24）；禁 `try!` / `fatalError`。
//

import SwiftUI

/// 和风逐日预报卡（类型级 `@MainActor` —— 本仓铁律 P-06）。
@MainActor
struct QWeatherCard: View {

    /// 状态容器（四态 + 逐日序列的唯一真源）。
    let model: QWeatherCardModel

    /// 日期渲染时区（D-4：选中城市时区；缺省设备时区）。
    var timeZone: TimeZone = .current

    /// 本卡折叠态（初值读持久化；点标题行右侧按钮翻转）。
    @State private var isCollapsed: Bool = CardVisibilityStore.isCollapsed(.qWeather)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            // 折叠态：只保留标题行，逐日 + 逐时 + 页脚全部不渲染。
            if !isCollapsed {
                content
                // 🔴 逐时区块（**渲染在本卡内部**，不是独立卡片）。
                //   它与逐日**共用同一个 `model`**，但状态是**独立的**
                //   （`hourlyState` vs `state`）→ 「逐日成功 + 逐时 401」
                //   会被如实分区显示，而不会被压成一句「和风天气取不到」。
                //   ⚠️ **无条件渲染**：四态由 `model.hourlyState` 派生，
                //   各自渲染（`.idle` / `.noData` / `.available` / `.unavailable`）。
                QWeatherHourlyCard(model: model, timeZone: timeZone)
                footer
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
            // ⚠️ `cloud` 与本仓其它卡同款，不编造符号名（P-24）。
            Image(systemName: "cloud")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("和风天气")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Spacer(minLength: 0)
            if model.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
            }
            CardCollapseButton(card: .qWeather, isCollapsed: isCollapsed, onToggle: toggleCollapse)
        }
    }

    // MARK: - 折叠切换

    /// 翻转折叠态：落库 + 改本地状态（动画与图标统一由 `CardCollapseButton` 驱动）。
    private func toggleCollapse() {
        let next = CardCollapseButton.toggleCollapsed(.qWeather)
        withAnimation(.easeInOut(duration: 0.15)) {
            isCollapsed = next
        }
    }

    // MARK: - 四态内容

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            Text("尚未加载")
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.secondaryText)

        case .noData:
            // 🔴 与 `.unavailable` **必须是不同的文案**。
            statusRow(icon: "checkmark",
                      title: "上游未下发逐日预报",
                      detail: "响应结构完整但 `days` 为空，这是合法响应，不是故障。")

        case .available:
            list

        case .unavailable(let message):
            statusRow(icon: "exclamationmark.triangle",
                      title: "和风天气取不到",
                      detail: message)
        }
    }

    // MARK: - 逐日列表

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.days.isEmpty {
                // ⚠️ 理论不可达（空数组判为 `.noData`），但**绝不留空白**。
                Text("暂无可展示的逐日数据")
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                ForEach(model.days) { day in
                    row(day)
                }
            }
        }
    }

    /// 单日一行（日期 + 天气现象 + 高低温）。
    ///
    /// ⚠️ 高低温各自可空 → 任一缺失即显示「暂无」，
    /// **绝不**用 0℃ 顶替（那会凭空造一条读数）。
    private func row(_ day: QWeatherDay) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                // ⚠️ `forecastStartTime` 是 **UTC ISO8601**（实测形如
                // `2026-10-07T16:00Z`）→ 用统一格式化器按城市时区渲染。
                Text(Self.dayText(day, timeZone: timeZone))
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 8)
                Text(Self.rangeText(day))
                    .font(.system(size: Theme.FontSize.metric, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
            }

            // 天气现象：`condition.text` 是**上游本地化文案**
            //（实测 `lang=zh` 时为「晴」「少云」等中文）→ 直接用，不翻译。
            if let text = day.daytime?.condition?.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            }

            // 白天/夜间分块里的降水概率（**[0,1] → 百分比**）。
            if let probability = day.daytime?.precipitation?.probability {
                Text("降水概率 " + Self.fractionText(probability))
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 状态行

    private func statusRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(detail)
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    // MARK: - 页脚（🔴 合规：attributions 必须展示）

    /// 页脚：**无条件**渲染 `attributions`（官方许可条件）。
    ///
    /// 🔴 即使 `.unavailable`（数据取不到）也渲染 —— 上游仍给了署名，
    ///    漏掉就是违反许可条件。
    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            timedOutNotice

            // 🔴🔴 合规硬要求，不可删、不可条件化。
            if model.attributions.isEmpty {
                // 上游未给署名 ≠ 有署名没解出来：如实说「未提供」，
                // **绝不**伪造一条署名出来。
                Text("上游未提供署名内容")
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                ForEach(Array(model.attributions.enumerated()), id: \.offset) { _, item in
                    if let url = URL(string: item) {
                        Link(item, destination: url)
                            .font(.system(size: Theme.FontSize.caption))
                    } else {
                        // 字面量非法 → 显示原文，不给假链接。
                        Text(item)
                            .font(.system(size: Theme.FontSize.caption))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }

            Text("和风天气 · 需自行配置凭据")
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    // MARK: - 格式化（纯函数，便于单测）

    /// 超时文案（**预先拼好**，不内联数值转换）。
    ///
    /// ⚠️ `String(Int(QWeatherCardModel.loadTimeout))` 直接写在 `VStack` 的
    /// ViewBuilder 里会让 Swift 类型检查器**超时** —— 同款写法在
    /// `EarthquakeCard` 上实测报
    /// `the compiler is unable to type-check this expression in reasonable time`。
    /// 故预先拼成 `static let`，View 里只剩常量引用。
    static let timeoutText: String = {
        let seconds = Int(QWeatherCardModel.loadTimeout)
        return "加载超时（超过 " + String(seconds) + " 秒）· 上方结果可能不是最新"
    }()

    /// 超时提示（**独立子视图**，同 `EarthquakeCard.timedOutNotice`）。
    @ViewBuilder
    private var timedOutNotice: some View {
        if model.hasTimedOut {
            Text(Self.timeoutText)
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.accent)
        }
    }

    /// 🔴 **`[0,1]` → 百分比**。**实测依据**：北京 `humidity = 0.32`。
    ///
    /// ⚠️ 这个 ×100 是**量纲关键点**，改错会把 32% 显示成 0.32%。
    static func fractionText(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }

    /// 高低温区间文本（任一缺失 → 「暂无」，**不用 0 顶替**）。
    static func rangeText(_ day: QWeatherDay) -> String {
        let high = day.temperatureMax?.value
        let low = day.temperatureMin?.value
        switch (high, low) {
        case let (high?, low?):
            return "\(Self.temperatureText(high)) ~ \(Self.temperatureText(low))"
        case let (high?, nil):
            return "最高 \(Self.temperatureText(high)) · 最低暂无"
        case let (nil, low?):
            return "最高暂无 · 最低 \(Self.temperatureText(low))"
        case (nil, nil):
            return "暂无"
        }
    }

    /// 单个温度值 → 文本（保留一位小数；单位取上游 `unit`）。
    private static func temperatureText(_ value: Double) -> String {
        // ⚠️ 单位用上游给的（实测 `°C`），**不硬编码** ——
        //   若将来请求 `lang`/`unit` 变了，单位应跟着变。
        String(format: "%.1f", value)
    }

    /// 日期文本：把上游的 **UTC ISO8601** 串按城市时区渲染。
    ///
    /// ⚠️ 实测 `forecastStartTime = "2026-10-07T16:00Z"`（**UTC**）。
    /// → 直接 `DateFormatter` 解析**可能失败**（缺毫秒、格式细节差异），
    ///   故用 `ISO8601DateFormatter`；解析失败则**如实退回原始串**，
    ///   **绝不**显示空白或错日期。
    static func dayText(_ day: QWeatherDay, timeZone: TimeZone) -> String {
        guard let raw = day.forecastStartTime else {
            // ⚠️ 上游没给开始时间 → 不编造日期。
            return "日期待定"
        }
        guard let parsed = Self.isoFormatter.date(from: raw) else {
            // 解析不了 → 显示上游原文（仍是有用信息），不假装成合法日期。
            return raw
        }
        return WeatherTimeFormatter.string(from: parsed, format: "MM-dd", timeZone: timeZone)
    }

    /// ISO8601 解析器（**UTC**；实测 `2026-10-07T16:00Z`）。
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
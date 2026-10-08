//
//  QWeatherHourlyCard.swift
//  ZhishengWeather / Cards
//
//  第九源「和风天气」**逐时区块** —— 渲染在 `QWeatherCard` **内部**。
//
//  ══════════════════════════════════════════════════════════════════════════
//  ✅ 实测基准：2026-10-09（主理人用真实凭据打通，`?hours=24` → HTTP 200）
//  实测样本：`humidity = 0.33`、`cloudCover = 0`、
//  `precipitation = {amount:{value:0,unit:"mm"}, intensity:{…}, type:"none", probability:0}`、
//  `temperature = {value: 26.01, unit: "°C"}`
//  ══════════════════════════════════════════════════════════════════════════
//
//  ── 🔴 为什么叫「Card」却是**区块**而不是独立卡片 ────────────────────────
//  它**不是**一张独立卡片，而是 `QWeatherCard` 内部的一段。
//  这个选择是**为了零改动**：
//  · 若做成独立卡片 → `ContentView` 需要加 `@State` + 加 `async let` + 加挂载点
//    **三处**改动，而 `ContentView` 正被**两位工程师同时编辑**
//    → 冲突概率极高，且合并成本全落在别人身上；
//  · 做成区块 → `ContentView` **一行都不用改**（`QWeatherCard(model:timeZone:)`
//    与 `qWeatherModel.load(latitude:longitude:)` 的签名都没变，
//    逐时由 `QWeatherCardModel.load` 内部并发拉取）。
//  → 这也让「逐日失败但逐时成功」能被**如实分区显示**（两个独立失败域）。
//
//  ── 🔴🔴 湿度 / 降水概率是 **[0,1]**，不是 0–100 ────────────────────────
//  **实测**：逐时 `humidity = 0.33`。
//  若当成百分数渲染，会把 33% 显示成 0.33% —— **量纲事故**。
//  → `fractionText(...)` 负责 ×100，与逐日卡**同一个函数**
//    （`QWeatherCard.fractionText`，单一真源，两处不各写一遍）。
//
//  ── ⚠️ 缺测 vs 零值必须分清 ──────────────────────────────────────────
//  · `nil` → 显示「暂无」，**绝不**显示 0（那会凭空造一条读数）；
//  · `0` → **是合法读数**（实测 `cloudCover = 0`、`probability = 0` 就是真值），
//    照实显示。
//
//  ── 四态：`.noData`（查了、没有）与 `.unavailable`（取不到）必须分开 ───
//  与逐日卡同纪律。把两者混成一句「加载失败」，会让「上游没下发这一小时」
//  被误报成「产品坏了」。
//
//  ── 🔴 `attributions` 的渲染在**逐日卡的页脚**（唯一一处）────────────
//  和风要求署名「与当前数据共同显示」，而 `QWeatherCardModel.attributions`
//  已把逐日 + 逐时两份 `metadata.attributions` **并集去重**，
//  故本区块**不重复渲染**署名（重复渲染不是错，但会让用户看到两遍同一串链接，
//  反而像出了 bug）。合规义务由页脚**一处**履行足矣。
//
//  本仓纪律：View 整体 `@MainActor`（P-06）；图标只用本仓已实际用过的
//  SF Symbol（P-24）；禁 `try!` / `fatalError`。
//  🔴 **所有长字符串拼接 + 数值转换都预提成 `static func` / `static let`**
//  （见下方「格式化」段）—— 内联进 ViewBuilder 会触发
//  `the compiler is unable to type-check this expression in reasonable time`，
//  且报错行号指向**外层容器**而非真正复杂的表达式（本仓踩过，`EarthquakeCard`）。
//

import SwiftUI

/// 和风逐时区块（类型级 `@MainActor` —— 本仓铁律 P-06）。
@MainActor
struct QWeatherHourlyCard: View {

    /// 状态容器（与逐日卡**共用同一个**，故两条链路的失败域天然隔离）。
    let model: QWeatherCardModel

    /// 时刻渲染时区（D-4：选中城市时区；缺省设备时区）。
    var timeZone: TimeZone = .current

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .padding(.top, 8)
        // 🔴 分隔线：不画会与逐日列表糊成一块；画 0.5pt 用 `divider`色，
        //    与卡片外框描边同款（`QWeatherCard` 外框即用同一色/线宽）。
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 0.5)
                .padding(.horizontal, -12)
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            // ⚠️ `clock` 是本仓已实际用过的 SF Symbol（不编造符号名，P-24）。
            Image(systemName: "clock")
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.accentSecondary)
            Text(Self.headerTitle)
                .font(.system(size: Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 四态内容

    @ViewBuilder
    private var content: some View {
        switch model.hourlyState {
        case .idle:
            Text("尚未加载")
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.secondaryText)

        case .noData:
            // 🔴 与 `.unavailable` **必须是不同的文案**。
            Self.statusRow(icon: "checkmark",
                           title: "上游未下发逐时预报",
                           detail: "响应结构完整但 `hours` 为空，这是合法响应，不是故障。")

        case .available:
            strip

        case .unavailable(let message):
            Self.statusRow(icon: "exclamationmark.triangle",
                           title: "和风逐时取不到",
                           detail: message)
        }
    }

    // MARK: - 逐时序列（横向滚动）

    /// 横向滚动条（24 条竖排会把卡片撑到半屏高，故横向）。
    ///
    /// ⚠️ `.horizontal` + `showsIndicators: false` 与本仓
    ///   `EnsembleUncertaintyCard` 同款（已实际编译过，不是编造的用法）。
    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(model.hours) { hour in
                    column(hour)
                }
            }
        }
    }

    /// 单小时一列：时刻 / 天气现象 / 温度 / 降水概率。
    ///
    /// ⚠️ **全部文本走 `Self.*` 静态函数**（不在 ViewBuilder 里做
    ///   字符串拼接与数值转换）—— 理由见文件头。
    private func column(_ hour: QWeatherHour) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.hourText(hour, timeZone: timeZone))
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.secondaryText)

            // 天气现象：`condition.text` 是**上游本地化文案**
            //（实测 `lang=zh` 时为「晴」「多云」等中文）→ 直接用，不翻译。
            if let text = hour.condition?.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                // ⚠️ 缺测 → **显示「暂无」而不是留空白**（空白会被读成「没数据」）。
                Text("暂无")
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            }

            Text(Self.temperatureText(hour))
                .font(.system(size: Theme.FontSize.metric, weight: .medium))
                .foregroundStyle(Theme.primaryText)

            // 降水概率（**[0,1] → 百分比**）。
            // ⚠️ `0` 是合法读数（实测 `probability = 0`）→ **照实显示 0%**，
            //   只在 `nil`（上游没给）时才显示「暂无」。
            Text(Self.precipitationText(hour))
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(width: 64, alignment: .leading)
    }

    /// 状态行（**static**：无实例状态依赖，且避免在 ViewBuilder 里展开
    /// 嵌套 ViewBuilder 造成的类型检查超时）。
    @ViewBuilder
    private static func statusRow(icon: String,
                                  title: String,
                                  detail: String) -> some View {
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

    // MARK: - 格式化（纯函数，便于单测）

    /// 区块标题（**预提成 `static let`**，不内联字符串拼接）。
    static let headerTitle: String = "和风逐时预报（未来 24 小时）"

    /// 缺测占位文案（**单一真源**：三处都用它，避免各写各的）。
    static let missingText: String = "暂无"

    /// 小时时刻文本：把上游的 **UTC ISO8601** 串按城市时区渲染为 `HH:mm`。
    ///
    /// ⚠️ 实测 `forecastTime = "2026-10-08T15:00Z"`（**UTC**）。
    ///   → 用 `ISO8601DateFormatter` 解析；**解析失败则如实退回原始串**，
    ///     **绝不**显示空白或错时刻（同 `QWeatherCard.dayText` 的纪律）。
    ///
    /// - Parameters:
    ///   - hour: 单小时领域模型。
    ///   - timeZone: 渲染时区（选中城市时区）。
    /// - Returns: `HH:mm`；无时刻 → 「时刻待定」；解析失败 → 上游原文。
    static func hourText(_ hour: QWeatherHour, timeZone: TimeZone) -> String {
        guard let raw = hour.forecastTime, !raw.isEmpty else {
            // ⚠️ 上游没给时刻 → **不编造**。
            return "时刻待定"
        }
        guard let parsed = isoFormatter.date(from: raw) else {
            return raw
        }
        return WeatherTimeFormatter.string(from: parsed, format: "HH:mm", timeZone: timeZone)
    }

    /// 温度文本（保留一位小数；缺测 → 「暂无」，**不用 0 顶替**）。
    ///
    /// ⚠️ 单位**不写进本函数**：本仓的逐日卡同样只显示数值、单位由
    ///   `QWeatherQuantity.unit` 承载并已在别处说明；逐时列宽仅 64pt，
    ///   塞入 `°C` 会挤压时刻文本。
    static func temperatureText(_ hour: QWeatherHour) -> String {
        guard let value = hour.temperature?.value else { return missingText }
        return String(format: "%.1f°", value)
    }

    /// 降水概率文本（**[0,1] → 百分比**，复用逐日卡的 `fractionText` 单一真源）。
    ///
    /// 🔴 `0` → 显示 `0%`（**合法读数**，实测就是 0）；`nil` → 「暂无」。
    ///   绝**不**把 `nil` 渲染成 0% —— 那是凭空造一条读数。
    static func precipitationText(_ hour: QWeatherHour) -> String {
        guard let probability = hour.precipitation?.probability else { return missingText }
        return QWeatherCard.fractionText(probability)
    }

    /// ISO8601 解析器（**UTC**；实测 `2026-10-08T15:00Z`）。
    ///
    /// ⚠️ 与 `QWeatherCard.isoFormatter` 是**两个实例**而非抽公共单例：
    ///   `ISO8601DateFormatter` 不是线程安全的 `Sendable` 类型，
    ///   而 `QWeatherCard` 那个是 `private`（跨文件不可见）。
    ///   抽到Core 会给 Widget 也拖进一个格式化器（而 Widget 不用它），
    ///   收益不抵成本。故此处**照抄一份**，并在两处都注明同步修改。
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

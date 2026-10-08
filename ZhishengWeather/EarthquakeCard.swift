//
//  EarthquakeCard.swift
//  ZhishengWeather / Cards
//
//  第十源 **USGS 地震**的主屏卡片：附近有感地震。
//
//  ═══════════════════════════════════════════════════════════════════════
//  实测基准：2026-10-08（主理人当次真实 curl 探针）
//  官方文档：https://earthquake.usgs.gov/fdsnws/event/1/
//  ═══════════════════════════════════════════════════════════════════════
//
//  ── 为什么「附近无地震」必须是一等公民状态 ──────────────────────────────
//  实测：**北京 300 km / 30 天 / M2.5+ 返回 0 条**（另用 `/count` 端点交叉
//  验证过，确认是**真的没地震**，不是参数写错）。也就是说，
//
//  **对绝大多数用户、绝大多数时刻，这张卡显示的就是「附近没有地震」。**
//
//  → 若把「没有」渲染成空白、或与「取不到」共用一句文案，用户会以为
//  **App 坏了**。故 `.none`（查过了、没有）与 `.unavailable`（取不到）
//  是**两套必须分开的文案**（与台风卡 `.none` / 洪水卡 `.noData` 同纪律）。
//
//  ── 🔴 文案必须带上「查询口径」这个限定 ──────────────────────────────────
//  本源说的其实是「**300 km 内没有 M2.5 以上的地震**」，**不是**
//  「300 km 内任何震动都没有」。把 `minmagnitude` / `maxradiuskm` /
//  回溯天数隐去不说，就是**内容错误**（微震与无感地震会被读者当成「没发生」）。
//  故 `.none` 文案逐字带上这三个数字，页脚亦复述一次。
//
//  ── 距离是**本应用算的**，不是上游给的 ───────────────────────────────────
//  USGS **不提供**任何距离字段；`EarthquakeEvent.distanceKm` 由本仓
//  `GeoDistance`（Haversine，R = 6371 km）算出 → 页脚**必须如实标注**，
//  否则用户会以为那是官方测距。
//
//  ── 震级量表不可横比（诚实警告，见 `EarthquakeEvent` 文件头）────────────
//  上游 `magType` 实测有 `mb` / `md` / `ml` / `mww` 等，测的不是同一个物理量。
//  → 卡片按**上游给定数值**展示与分级，但**不宣称**「震级越高能量越大」
//  跨量表成立；页脚写明「按上游给定震级」。
//
//  ── 震中描述是**英文原文**，本应用不做机器翻译 ──────────────────────────
//  实测 `place` 形如 `"92 km N of Ruteng, Indonesia"`。翻译会引入错地名，
//  故**原样展示** + 用文案说明这是 USGS 原文。
//
//  本仓纪律：View 整体 `@MainActor`（P-06）；图标只用本仓已实际用过的
//  SF Symbol（P-24，不编造符号名）；禁 `try!` / `fatalError`。
//

import SwiftUI

/// 地震卡（类型级 `@MainActor` —— 本仓铁律 P-06：每个 `struct ... : View` 都带）。
@MainActor
struct EarthquakeCard: View {

    /// 状态容器（四态的唯一真源）。
    let model: EarthquakeCardModel

    /// 日期渲染时区（D-4：选中城市时区；缺省设备时区）。
    var timeZone: TimeZone = .current

    /// 最多展示多少条（实测端点 `limit = 20`）。
    ///
    /// ⚠️ 按数据长度截取，**不写死 20 当契约** —— 端点改 `limit` 这里跟着变。
    private var visibleEvents: [EarthquakeEvent] {
        let all = model.availableEvents ?? []
        guard all.count > UsgsEarthquakeEndpoint.resultLimit else { return all }
        return Array(all.prefix(UsgsEarthquakeEndpoint.resultLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            footer
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
            // ⚠️ 图标只用**本仓已实际使用过**的 SF Symbol（P-24：不编造符号名）。
            // `exclamationmark.triangle` 与洪水卡 /台风卡同款。
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("附近地震")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Spacer(minLength: 0)
            if model.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
            }
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

        case .none:
            // 🔴 与 `.unavailable` **必须是不同的文案**
            // （「这一带没有达到口径的地震」≠「取不到」）。
            //⚠️ 文案**必须带上口径**：不写 M2.5 / 300 km / 30 天，
            // 读者会以为「任何震动都没有」。
            statusRow(icon: "checkmark",
                      title: "附近没有达到记录口径的地震",
                      detail: "所选位置 " + Self.radiusText
                          + "内、近 " + Self.lookbackText + "，M"
                          + Self.magnitudeThresholdText + " 及以上地震。\n"
                          + "这是该口径下没有记录，不代表该范围无任何震动。")

        case .available:
            list

        case .unavailable(let message):
            statusRow(icon: "exclamationmark.triangle",
                      title: "地震数据取不到",
                      detail: message)
        }
    }

    // MARK: - 事件列表

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            if visibleEvents.isEmpty {
                // ⚠️ 理论不可达（空数组判为 `.none`），但**绝不留空白**。
                Text("暂无可展示的地震记录")
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                ForEach(visibleEvents) { event in
                    row(event)
                }
            }
        }
    }

    /// 单条地震一行。
    ///
    /// ⚠️ `magnitude == nil` → 显示「震级未提供」，**绝不补0、绝不显示 M0.0**
    /// （那会把「没定级」说成「一场微震」）。
    private func row(_ event: EarthquakeEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(Self.magnitudeText(event.magnitude))
                    .font(.system(size: Theme.FontSize.metric, weight: .semibold))
                    .foregroundStyle(Self.levelColor(event.magnitudeLevel))
                if event.hasTsunamiFlag {
                    // ⚠️ 海啸风险是**事实性警示**，用强强调色 + 明确文案，
                    // 不做「淡化处理」（淡化会让人以为不重要）。
                    Text("海啸相关")
                        .font(.system(size: Theme.FontSize.caption, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                Spacer(minLength: 4)
                Text("距你 " + Self.distanceText(event.distanceKm))
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            }

            // ⚠️ 时刻用**城市时区**渲染（D-4），与全App 的时刻口径一致。
            Text(Self.timeText(event.time, timeZone: timeZone))
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.secondaryText)

            // ⚠️ 震中描述是**上游英文原文**，本应用不做机器翻译（翻译会引入错地名）。
            if let place = event.placeDescription, !place.isEmpty {
                Text(place)
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            }

            // 深度：nil → **不显示这一行**（缺测≠0 km）。
            if let depth = event.depthKm {
                Text("深度 " + Self.optionalNumber(depth) + " km")
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            }

            // PAGER 警报：nil 是**常态**（绝大多数事件没有 PAGER 产品）→ 不显示。
            if let alert = event.pagerAlert {
                Text(alert.displayName)
                    .font(.system(size: Theme.FontSize.caption, weight: alert.needsAttention ? .semibold : .regular))
                    .foregroundStyle(alert.needsAttention ? Theme.accent : Theme.secondaryText)
            }

            // 有感上报：nil = **没人上报**（常态，不是故障）→ 不显示这一行。
            if let felt = event.feltReportCount {
                Text("有感上报 " + String(felt) + " 人")
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            }

            // USGS 官方详情页（可点）。`detailURL` 字面量非法 → nil → 整行不显示。
            if let detailURL = event.detailURL {
                Link("查看 USGS 详情", destination: detailURL)
                    .font(.system(size: Theme.FontSize.caption))
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 状态行（.none / .unavailable 共用外壳，文案各自传入）

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

    // MARK: - 页脚

    /// 页脚：把**口径**与**两个"本应用自算/本应用口径"的限定**说清楚。
    ///
    /// ⚠️ 这一段是**诚实纪律的落点**，不可为了简洁删掉：
    /// · 「附近」是本应用自定的半径，不是官方概念；
    /// · 距离是本应用按 Haversine 算的，不是官方测距；
    /// · 震级按上游给定数值展示，不同量表之间不可横向比较。
    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("USGS 地震目录 · 免 Key")
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.secondaryText)
            if model.hasTimedOut {
                Text("加载超时（超过 " + String(Int(model.loadTimeout)) + " 秒）· 上方结果可能不是最新")
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.accent)
            }
            Text("口径：" + Self.radiusText + " / 近 " + Self.lookbackText
                 + " / M" + Self.magnitudeThresholdText + "+ · 距离为本应用按 Haversine 公式计算")
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    // MARK: - 格式化（纯函数，便于单测）

    /// 震级文本：`nil` → 「震级未提供」（**绝不**显示 M0.0）。
    static func magnitudeText(_ magnitude: Double?) -> String {
        guard let magnitude else { return "震级未提供" }
        return "M" + optionalNumber(magnitude)
    }

    /// 可选 Double → 字符串（`nil` → `缺测`，调用方已分流，这里是兜底）。
    private static func optionalNumber(_ value: Double) -> String {
        String(format: "%g", value)
    }

    /// 距离文本（km，一位小数；上游/本应用都不提供英里口径，故不换算）。
    static func distanceText(_ kilometers: Double) -> String {
        String(format: "%.0f km", kilometers)
    }

    /// 时刻文本（城市时区）。
    static func timeText(_ date: Date, timeZone: TimeZone) -> String {
        WeatherTimeFormatter.string(from: date, format: "yyyy-MM-dd HH:mm", timeZone: timeZone)
    }

    /// 半径文案（自「端点常量」派生，**不在文案里写死数字**）。
    private static var radiusText: String {
        String(Int(UsgsEarthquakeEndpoint.radiusKm)) + " km"
    }

    /// 最低震级文案（自「端点常量」派生）。
    private static var magnitudeThresholdText: String {
        String(format: "%g", UsgsEarthquakeEndpoint.minimumMagnitude)
    }

    /// 回溯天数文案（自「模型常量」派生）。
    private static var lookbackText: String {
        String(EarthquakeCardModel.lookbackDays) + " 天"
    }

    /// 分级 → 颜色（未知分级用 `secondaryText`，**不谎报强度**）。
    private static func levelColor(_ level: EarthquakeMagnitudeLevel?) -> Color {
        switch level {
        case .strong: return Theme.accent
        case .moderate: return Theme.primaryText
        case .minor: return Theme.secondaryText
        case nil: return Theme.secondaryText
        }
    }
}
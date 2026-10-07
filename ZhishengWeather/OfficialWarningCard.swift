//
//  OfficialWarningCard.swift
//  ZhishengWeather（主 App target）
//
//  **官方气象预警卡**（第六源 · 中国气象局 NMC）。
//
//  ═══════════════════════════════════════════════════════════════════════
//  四态（**缺一不可**，且 `.none` 与 `.stale` 语义严格对立）
//  ═══════════════════════════════════════════════════════════════════════
//  · `.none`（无预警）→ **整卡隐藏**，不留空白。
//  · `.active`（有预警）→ 按颜色**红 > 橙 > 黄 > 蓝**排序（由 Core 的
//    `OfficialWarningState.sorted` 负责，**本文件不重算**），
//    最多展示 **3 条** + 「还有 N 条」。
//  · `.stale`（**取数失败** 或 **数据超过 6 小时**）→ **显式显示**
//    「预警数据获取失败」/ 「预警数据已过期」，**绝不静默消失**。
//  · `.unavailable`（该源未启用）→ 显式说明。
//
//  ── 为什么 `.stale` 必须显式说出来（本文件存在的全部理由）──────────────
//  若把「取不到」画成「无预警」，用户会在**真正有红色预警时**看到一片平静。
//  灾害天气里这是**内容错误**，代价远高于"多显示一行提示"。
//  故本卡的四种状态都有**可见输出**，唯一会「消失」的是 `.none`
//  —— 而它只在**取数成功且上游确实为空**时出现（契约见
//  `NmcAlarmProviding` 文件头）。
//
//  ── 排序与「还有 N 条」的口径 ─────────────────────────────────────────
//  排序由 Core 的 `OfficialWarningState.sorted` 单点给出（本文件不重算，
//  口径两处漂移比没有文案更糟）。「还有 N 条」= 总数 − 展示数，**如实算**，
//  不用"等"字含糊过去。
//
//  ── 配色：复用 AQI 六档语义色，**不新造一套** ─────────────────────────
//  `color(for:)` 直接映射到 `AirQualityCard.color(for:)` 的既有档：
//  红 → `.medium`（红）、橙 → `.light`（橙）、黄 → `.moderate`（黄）、
//  蓝 → `.good`（绿？**不** —— 见下）。⚠️ 蓝**不复用** `.good`（绿）：
//  预警的「蓝」是最低档但**仍是预警**，用绿色会读成"一切正常"。
//  故蓝用 `Theme.accentSecondary`（与 UV 低档同源的强调色），与既有卡片
//  同源但**语义不冲突**。
//
//  ── 防御指南正文（第七源 weather.cn 补源，`item.defenseGuide`）──────────
//  默认**收起**：只显示颜色 + 类型 + 地区 + 发布时间；点条目展开防御指南。
//
//  ## 实测形态（2026-10-06 当次抓取，5 条详情逐条统计，**非引自文档**）
//  · 长度 **137~154 字符**（5/5 非空）；
//  · **换行 0 个**（`\n` 与 `\r` 计数均为 0）→ 上游是**单段**纯文本，
//    **不是**"上游大概率 `\n` 分段"的假设。故正文交给 `Text` 直接渲染；
//  · **无 HTML 残留**（正则扫 `<[^>]+>` 与 `&[a-zA-Z]+;` 均 0 命中）
//    → **刻意不写任何正则清洗**：没实测到残留就不做"想象中的清洗"，
//    凭空清洗会**改写官方原文**，那属内容错误。
//
//  ## 敏感内容纪律
//  正文是**官方原文**：只排版，**不改写、不摘要、不加自己编的建议**。
//  空/缺失时**如实显示**「暂无防御指南正文。」—— 既不静默隐藏，
//  也**绝不**编兜底文案（把"不知道"说成"有建议"是内容错误）。
//  故每条都**恒可点开**：无正文的条目也要能让用户看见"这条没有正文"。
//
//  ── 时钟 ─────────────────────────────────────────────────────────────
//  本文件**不调用 `Date()`**：`now` 由调用方注入（ContentView 传
//  `viewModel.lastUpdatedDate` 或 `TimelineView` 的 `context.date`）。
//  发布时刻按**选中城市时区**渲染（D-4 纪律）。
//

import SwiftUI

/// 官方预警卡（四态自持）。
///
/// ⚠️ **类型级 `@MainActor`** —— 与本仓所有 View 范式一致
/// （`DaylightCard` / `AirQualityCard` / `ContentView` 等均如此）。
/// 不标会编译不过：本卡的 `color(for:)` 要调 `AirQualityCard.color(for:)`，
/// 那是另一个 View 的 static 成员，继承了它的类型级隔离；
/// `issueTimeText` 要调类型级 `@MainActor` 的 `WeatherTimeFormatter`。
/// SwiftUI 的 `View` 本身也要求成员访问在主 actor，标注是诚实描述而非绕过。
@MainActor
struct OfficialWarningCard: View {

    /// 四态（由 `WeatherViewModel` / Core 的 `resolve` 派生）。
    let state: OfficialWarningState

    /// 判定 / 渲染用的「当前时刻」（**注入**，本文件不读系统时钟）。
    var now: Date

    /// 城市时区（D-4；由 `ContentView` 透传 `viewModel.selectedTimeZone`）。
    var timeZone: TimeZone = .current

    /// 最多展示的条数（其余折叠为「还有 N 条」）。
    var maxVisible: Int = 3

    /// 展开了「防御指南」的条目 id 集合（**按 id 而非下标**）。
    ///
    /// ⚠️ 用 `Set<String>` + `item.id` 而非 `Set<Int>`：
    /// 列表会随刷新变动（增删预警），按下标记住展开态会把A 预警的展开状态
    /// 套到 B 上 —— 与 `OfficialWarningItem.id` 存在的原因同款。
    @State private var expandedIDs: Set<String> = []

    var body: some View {
        // `.none` → 整卡隐藏（不留空白）；其余三态都有可见输出。
        if case .none = state {
            EmptyView()
        } else {
            card
        }
    }

    // MARK: - 布局

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch state {
            case .none:
                // **不可达**：`body` 已在此之前返回 `EmptyView`。
                // 这里保留分支只为让 `switch` 在类型上完备（编译器要求），
                // **不会**渲染出内容。
                EmptyView()
            case .active(let items):
                activeBody(items)
            case .stale(let reason):
                staleBody(reason)
            case .unavailable:
                noticeBody(icon: "bell.slash",
                           title: "未接入官方预警源",
                           detail: "当前构建未启用中国气象局预警链路。")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(headerColor)
            Text("官方预警")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 8)
            headerBadge
        }
    }

    /// 右上角徽标：显示**最高档颜色名**（`.active`）或状态词（其余两态）。
    @ViewBuilder
    private var headerBadge: some View {
        switch state {
        case .active(let items):
            if let top = items.first {
                Text("\(top.color.displayName)预警")
                    .font(.system(size: Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Self.color(for: top.color))
            }
        case .stale:
            Text("数据不可信")
                .font(.system(size: Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
        case .unavailable:
            Text("未启用")
                .font(.system(size: Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
        case .none:
            EmptyView()
        }
    }

    private var headerColor: Color {
        switch state {
        case .active(let items):
            return items.first.map { Self.color(for: $0.color) } ?? Theme.secondaryText
        case .stale, .unavailable, .none:
            return Theme.secondaryText
        }
    }

    /// `.active`：最多 `maxVisible` 条 + 「还有 N 条」。
    @ViewBuilder
    private func activeBody(_ items: [OfficialWarningItem]) -> some View {
        let visible = Array(items.prefix(maxVisible))
        let hidden = items.count - visible.count
        VStack(alignment: .leading, spacing: 8) {
            ForEach(visible) { item in
                row(item)
            }
            if hidden > 0 {
                Text("还有 \(hidden) 条预警")
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    /// 单条预警行：颜色圆点 + 类型 + 地点 + 发布时间（**默认收起**）。
    ///
    /// ## 为什么**每条都可点开**（哪怕没有正文）
    /// 正文缺失是一个**必须让用户看见的事实**（"这条没有防御指南" vs
    /// "这条有防御指南"是两种不同的风险认知）。若给无正文的条目去掉箭头、
    /// 做成不可点，用户永远看不到这个区别 —— 那就是**静默隐藏**。
    /// 故：箭头恒显示、恒可点，展开后**如实**显示"有正文"或"暂无正文"。
    /// 这样"缺失"永远可见，且**绝不**编兜底文案。
    private func row(_ item: OfficialWarningItem) -> some View {
        let raw = item.defenseGuide ?? ""
        let isExpanded = expandedIDs.contains(item.id)

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if isExpanded {
                    expandedIDs.remove(item.id)
                } else {
                    expandedIDs.insert(item.id)
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Self.color(for: item.color))
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(item.kind)预警")
                            .font(.system(size: Theme.FontSize.caption, weight: .semibold))
                            .foregroundStyle(Self.color(for: item.color))
                        // ⚠️ 地点缺失（标题没解析出行政区划）→ **不显示地点行**，
                        // 绝不显示空白或"未知地点"（原文已在 kind 里带了信息）。
                        if let region = item.region, !region.isEmpty {
                            Text(region)
                                .font(.system(size: Theme.FontSize.footnote))
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    Spacer(minLength: 8)
                    // ⚠️ 发布时间缺失 → **不显示时刻**（绝不拿 `now` 编一个出来）。
                    if let issuedAt = item.issuedAt {
                        Text(Self.issueTimeText(issuedAt, now: now, timeZone: timeZone))
                            .font(.system(size: Theme.FontSize.footnote))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.top, 3)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                defenseGuideBody(raw)
            }
        }
    }

    /// 展开后的**防御指南正文**（官方原文，逐字展示，**不改写、不摘要**）。
    ///
    /// ## 为什么用 `Text` + `.fixedSize(horizontal:false, vertical:true)`
    /// 实测正文形态（2026-10-06 当次抓取，5 条）：单段纯文本，
    /// 长度 **137~154 字符**，**换行 0 个**（`\n` / `\r` 计数均为 0），
    /// **无任何 HTML 标签或实体**（正则扫 `<[^>]+>` 与 `&[a-zA-Z]+;` 均 0 命中）。
    /// → 故本文件**不做任何正则清洗**：没实测到残留就不写"想象中的清洗"，
    ///   凭空加清洗反而会**改写官方原文**，那属内容错误。
    /// → 换行仍按纯文本语义交给 `Text`：若将来上游真的给了 `\n`，
    ///   `Text` 会如实分段显示，无需额外处理。
    ///
    /// ## 为什么 `.fixedSize(horizontal:false, vertical:true)`
    /// 缺了它，`ScrollView` 内的 `Text` 会在水平方向按 proposal 压缩、
    /// 高度按行数估算，长正文会被挤出可视区。放开 vertical 方向后，
    /// 高度由实际行数决定（外层再用 `.frame(maxHeight:)` 封顶 + 可滚）。
    @ViewBuilder
    private func defenseGuideBody(_ raw: String) -> some View {
        if raw.isEmpty {
            // ⚠️ "没取到"与"取到但为空"（上游偶发空串，已在 `enrich`
            // 按缺失处理）在这里汇合 → **如实说明缺内容**，
            // 绝不编一段兜底文案（把"不知道"说成"有建议"是内容错误）。
            Text("暂无防御指南正文。")
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
                .padding(.leading, 16)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("防御指南")
                    .font(.system(size: Theme.FontSize.footnote, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                ScrollView {
                    Text(raw)
                        .font(.system(size: Theme.FontSize.footnote))
                        .foregroundStyle(Theme.secondaryText)
                        .lineSpacing(2)
                        // ⚠️ `Text` 的默认行数限制并非"无限"，
                        // 显式给 `nil` = 不限行数（官方原文**不许截断**）。
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // ⚠️ 封顶 + 可滚动：正文再长也**撑不爆整张卡**。
                //   120pt 是**防御性上限**（实测 154 字符约 4~6 行足够显示完），
                //   不是"展示上限"—— 没有 `.lineLimit` 截断，永远显示全文。
                .frame(maxHeight: 120)
            }
            .padding(.leading, 16)
        }
    }

    /// `.stale`：**显式说明**，并区分两种成因（用户看到的文案不同）。
    @ViewBuilder
    private func staleBody(_ reason: OfficialWarningState.StaleReason) -> some View {
        switch reason {
        case .fetchFailed(let message):
            noticeBody(icon: "wifi.exclamationmark",
                       title: "预警数据获取失败",
                       detail: message.isEmpty ? "未能获取官方预警数据。" : message)
        case .dataTooOld(let latest, let age):
            noticeBody(icon: "clock.badge.exclamationmark",
                       title: "预警数据已过期",
                       detail: Self.staleDetail(latest: latest, age: age))
        }
    }

    /// 统一提示行（图标 + 标题 + 说明）。
    private func noticeBody(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: Theme.FontSize.footnote))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 格式化（`View` 的成员天然落在主 actor；纯静态逻辑，可直接单测）

    /// 分档语义色：复用 AQI 六档（`AirQualityCard.color(for:)`）。
    ///
    /// ⚠️ **蓝色不复用 `.good`（绿）** —— 理由见文件头：预警的蓝**仍是预警**，
    /// 用绿色会读成"一切正常"，那是**误导**。
    ///
    /// ⚠️ **不可标 `nonisolated`**：`AirQualityCard` 是 `View`，
    /// 它的 `static func color(for:)` 继承类型级 `@MainActor` 隔离，
    /// 本函数调它就必须在主actor 上。标了`nonisolated` CI 会报
    /// "call to main actor-isolated static method 'color(for:)'"。
    /// 「能被单测直接调」不需要 `nonisolated` —— 测试方法标 `@MainActor` 即可。
    static func color(for color: NmcAlarmColor) -> Color {
        switch color {
        case .red: return AirQualityCard.color(for: .medium)     // 红
        case .orange: return AirQualityCard.color(for: .light)   // 橙
        case .yellow: return AirQualityCard.color(for: .moderate) // 黄
        case .blue: return Theme.accentSecondary                  // 蓝（**非绿**）
        case .unspecified: return Theme.secondaryText            // 未知 = 中性灰
        }
    }

    /// 发布时间文案：1 小时内显示「X 分钟前」，否则显示**城市时区**的钟点。
    ///
    /// ⚠️ 未来时刻（`age < 0`，时区/时钟问题）**不**显示「-3 分钟前」这种
    /// 荒谬文案，改为显示钟点（让用户自己判断）。
    ///
    /// ⚠️ **刻意不是 `nonisolated`**：`WeatherTimeFormatter` 是类型级
    /// `@MainActor`（未加锁的 formatterCache），本函数调它就必然落在主actor 上。
    /// 若强行标 `nonisolated`，CI 报
    /// "call to main actor-isolated static method 'string(from:format:timeZone:)'
    /// in a synchronous nonisolated context"。
    /// 同文件 :335 的 `color(for:)` 同理（调 `AirQualityCard.color(for:)`，
    /// 那是 View 的 static 成员）。**对比**：同仓 `UVIndexCard` 的
    /// `uvText`/`visText` 能标 nonisolated，是因为它们只做纯字符串拼接、
    /// 不触碰任何 MainActor 成员 —— 隔离标注必须与实际依赖一致。
    static func issueTimeText(_ issuedAt: Date,
                                          now: Date,
                                          timeZone: TimeZone) -> String {
        let age = now.timeIntervalSince(issuedAt)
        if age >= 0, age < 3600 {
            let minutes = Int(age / 60)
            // ⚠️ `0` 分钟显示「刚刚」而不是「0 分钟前」—— 前者才是自然语言。
            return minutes <= 0 ? "刚刚" : "\(minutes) 分钟前"
        }
        return WeatherTimeFormatter.string(from: issuedAt,
                                           format: "HH:mm",
                                           timeZone: timeZone)
    }

    /// `.stale(.dataTooOld)` 的说明文案（**如实给出时长**，不写"很久"）。
    ///
    /// ⚠️ 能走到这里说明 `age > 6h`（或 `age < 0`，见下），
    /// 故文案里**必然**是"已超过 6 小时有效窗口" —— 不存在"仅 40 分钟就过期"
    /// 的表述（那会与判据自相矛盾）。
    nonisolated static func staleDetail(latest: Date?, age: TimeInterval) -> String {
        // latest == nil → **发布时间全部缺失**，无法判定新鲜度（不是"很旧"）。
        guard latest != nil else {
            return "预警发布时间缺失，无法确认数据是否仍然有效。"
        }
        guard age.isFinite, age > 0 else {
            // age ≤ 0（含负）→发布时间晚于当前时刻，属时钟/时区异常，
            // **如实这么说**，不谎报"已过期 N 小时"。
            return "预警发布时间晚于当前时刻，无法确认数据是否仍然有效。"
        }
        let hours = Int(age / 3600)
        if hours >= 1 {
            return "最新一条预警发布于 \(hours) 小时前，已超过 6 小时有效窗口。"
        }
        return "最新一条预警发布于 \(max(1, Int(age / 60))) 分钟前，已超过 6 小时有效窗口。"
    }
}
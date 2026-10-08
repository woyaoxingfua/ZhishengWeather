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
//  ── 🔴 区域化双源并列（2026-10-11 新增）────────────────────────────────
//  需求（主理人原话）：「区域化数据源就同一张卡里显示吧，然后主要数据选目标
//  地区比较好的，就是比如在国内，就大写和风稍微小写openmeto或者点一下就切换
//  到另一个数据源了。」拆成三件事：
//   ① **谁当主源** → `RegionalSourcePolicy`（Core 纯函数，单测钉住）：
//      国内以**和风**为主、海外以 **Open-Meteo**为主；
//   ② **两个源都显示** → 主源走**大字号**逐日列表，次源走**小字**摘要行；
//   ③ **点一下切换** → 点次源摘要即把它升为主（**会话内有效，不落盘**）。
//
//  ⚠️ **为什么切换不落盘**：本仓「绝不静默换源」纪律针对的是**系统行为**，
//    而这里是**用户明示的操作**。落盘会让「下次打开 App 默认源」变成一个
//    用户早已忘记的选择 —— 那才是静默。保持会话内可见可逆。
//
//  ── 🔴🔴 `attributions` 的渲染**不受本次改动影响**（合规硬要求）──────
//  和风官方明文：「必须与当前数据共同显示」。即使**当前主源是 Open-Meteo**，
//  本卡仍在渲染和风数据（次源），署名**照旧无条件渲染** —— 把署名改成
//  「只有和风当主源时才显示」等于让合规义务取决于用户点了哪个按钮。
//
//  本仓纪律：View 整体 `@MainActor`（P-06）；图标只用本仓已实际用过的
// SF Symbol（P-24）；禁 `try!` / `fatalError`。
//

import SwiftUI

/// 和风逐日预报卡（类型级 `@MainActor` —— 本仓铁律 P-06）。
@MainActor
struct QWeatherCard: View {

    /// 状态容器（四态 + 逐日序列的唯一真源）。
    let model: QWeatherCardModel

    /// 日期渲染时区（D-4：选中城市时区；缺省设备时区）。
    var timeZone: TimeZone = .current

    /// 🔴 **另一个数据源**（Open-Meteo，即本仓既有主源）的逐日预报（2026-10-11）。
    ///
    /// ⚠️ **它来自既有 `WeatherSnapshot`，本卡不自己发请求** ——
    ///   绝不新起一条 `OpenMeteoService` 链路（那会重复取数、重复计配额）。
    ///   为空（`[]` / nil）时次源摘要行**整段不渲染**（不留空槽）。
    var openMeteoDaily: [DailyForecast]? = nil

    /// 🔴 目标地区（决定「默认谁当主源」）。nil → 判不出来 → 如实走
    ///   `RegionalSourcePolicy.region(country:latitude:longitude:)` 的兜底。
    var country: String? = nil

    /// 目标坐标（`country` 缺失时用于粗判；见 `RegionalSourcePolicy` 类型注释）。
    var latitude: Double? = nil

    /// 目标经度（语义同 `latitude`）。
    var longitude: Double? = nil

    /// 本卡折叠态（初值读持久化；点标题行右侧按钮翻转）。
    @State private var isCollapsed: Bool = CardVisibilityStore.isCollapsed(.qWeather)

    /// 🔴 用户是否已**手动切换**过主源（会话内有效，**不落盘**；理由见文件头）。
    ///
    /// `nil` = 尚未切换 → 主源由地区裁定（`region`）。
    /// 非 nil = 用户点了次源摘要 → 该源升为主。
    @State private var manualPrimarySource: SourceID? = nil

    /// 生效的目标地区（纯函数裁定；视图不自己判）。
    private var region: WeatherRegion {
        RegionalSourcePolicy.region(country: country,
                                    latitude: latitude,
                                    longitude: longitude)
    }

    /// 🔴 当前**主源**（用户手动切换优先于地区裁定）。
    private var primarySource: SourceID {
        manualPrimarySource ?? RegionalSourcePolicy.defaultPrimarySource(for: region)
    }

    /// 次源（= 两个源里不是主源的那个）。
    private var secondarySource: SourceID {
        primarySource == .qWeather ? .openMeteoForecast : .qWeather
    }

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
                //   ⚠️ 逐时**只有和风有**（Open-Meteo 逐时在主屏「未来数小时」区块），
                //   故本区块始终属于和风，不随主源切换而隐藏。
                QWeatherHourlyCard(model: model, timeZone: timeZone)
                // 🔴 次源摘要（区域化双源的「另一个源」）——**无条件求值，
                //   内部按数据是否存在决定渲不渲染**。
                secondarySourceSection
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
            Text("天气预报")
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

    // MARK: - 四态内容（按主源分派）

    /// 🔴 主源内容：按 `primarySource` 分派到对应源的渲染。
    ///
    /// ⚠️ **既不是「和风优先」也不是「Open-Meteo 优先」**，而是**按地区裁定**
    ///   （`RegionalSourcePolicy`）+ 用户手动切换。这是本轮区域化的核心。
    /// ⚠️ 分派**只决定渲染哪一份**，**完全不改变取数**：和风照旧由
    ///   `QWeatherCardModel` 独立取（失败隔离不受影响），Open-Meteo 照旧
    ///   来自主屏既有快照。**绝不在这里发请求、绝不静默换源。**
    @ViewBuilder
    private var content: some View {
        if primarySource == .qWeather {
            qWeatherContent
        } else {
            openMeteoContent
        }
    }

    /// 和风侧四态（原有实现，**文案一字未改** —— 四态纪律不因区域化而松动）。
    @ViewBuilder
    private var qWeatherContent: some View {
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

    /// 🔴 Open-Meteo 侧（海外主源 / 国内次源）逐日内容。
    ///
    /// ⚠️ **四态同样分开**（本仓铁律，不因「这是另一个源」而豁免），且
    ///   **`nil` 与「取不到」是两件事**：
    ///   · `openMeteoDaily == nil`（主屏快照还没好）→ 「主源快照尚未就绪」。
    ///     **绝不**说成「Open-Meteo 取不到」—— 那会把「还没拿到」谎报成
    ///     「上游失败」，用户会去查网络，而问题在本屏加载时序。
    ///   · 空数组 → 「上游未下发逐日预报」（合法响应，非故障）。
    ///   · 有值 → 列表（**大字号**，主源位）。
    /// ⚠️ **绝不**在这里发请求：数据来自既有主屏快照（见 `openMeteoDaily` 注释）。
    @ViewBuilder
    private var openMeteoContent: some View {
        if let daily = openMeteoDaily {
            if daily.isEmpty {
                statusRow(icon: "checkmark",
                          title: "上游未下发逐日预报",
                          detail: "响应结构完整但逐日序列为空，这是合法响应，不是故障。")
            } else {
                openMeteoList(Array(daily.prefix(Self.openMeteoDayLimit)))
            }
        } else {
            statusRow(icon: "clock",
                      title: "主源快照尚未就绪",
                      detail: "本行数据取自主屏已加载的天气快照，快照就绪后自动显示。")
        }
    }

    /// Open-Meteo 逐日列表（**大字号 = 主源位**）。
    ///
    /// ⚠️ `Array(...prefix(...))` 而非 `.prefix(...).map { $0 }`：前者一步到位、
    ///   不引入闭包，也就不会和标准库 `map` 撞名（P-32 纪律）。
    private func openMeteoList(_ days: [DailyForecast]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(days) { day in
                openMeteoRow(day)
            }
        }
    }

    /// Open-Meteo 单日一行（日期 + 天气现象 + 高低温）。
    ///
    /// ⚠️ `DailyForecast.tempMax` / `tempMin` 是**非可选 Double**（缺测已在
    ///   Core mapper 之前被挡掉），故这里**没有**「暂无」分支 ——
    ///   但温度格式化仍走**同一个** `Self.rangeText(from:to:)`（单一真源，
    ///   避免两个源各写一份温度拼接而漂移）。
    /// ⚠️ WMO 码 → 中文走 `WMOCodeMapper.description(for:)`（既有单一真源，
    ///   与主屏 `heroSection` 同一函数），**绝不**在本卡另写码表。
    private func openMeteoRow(_ day: DailyForecast) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(Self.openMeteoDayText(day.date, timeZone: timeZone))
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 8)
                Text(Self.rangeText(from: day.tempMax, to: day.tempMin))
                    .font(.system(size: Theme.FontSize.metric, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
            }
            Text(WMOCodeMapper.description(for: day.weatherCode))
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.vertical, 2)
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

    // MARK: - 次源摘要（区域化双源的「另一个源」+ 点一下切换）

    /// 🔴 次源摘要行（**小字号 = 次源位**）+ **点一下把它升为主源**。
    ///
    /// ⚠️ **三个数据驱动分支，绝不留空槽**：
    ///   · 次源是 Open-Meteo 且快照未就绪 → 如实说「尚未就绪」（**不说**「取不到」）；
    ///   · 次源是 Open-Meteo 且有逐日 → 显示前 N 天概要 + 「点此切换为主源」；
    ///   · 次源是和风 → 用 `model.state` 的四态压缩成一行（`.available` 给概要，
    ///     其余三态给各自的**真实**原因，**不合并成一句「加载失败」**）。
    @ViewBuilder
    private var secondarySourceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 0.5)
                .padding(.vertical, 4)

            Text(Self.secondaryTitle(secondarySource))
                .font(.system(size: Theme.FontSize.footnote, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)

            Text(Self.rationaleText(region))
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            secondarySummary

            // 🔴 「点一下切换」入口。**始终可点**：即便次源当前无数据，
            //   也允许切换过去看它自己的空态（那是**如实信息**，
            //   而把入口藏起来等于替用户决定「不该看这个源」）。
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    manualPrimarySource = secondarySource
                }
            } label: {
                Text("点此将「" + Self.sourceName(secondarySource) + "」切换为主数据源")
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
    }

    /// 次源概要（**小字号**；数据形态差异大，故两个源各写一段）。
    @ViewBuilder
    private var secondarySummary: some View {
        if secondarySource == .openMeteoForecast {
            secondaryOpenMeteoSummary
        } else {
            secondaryQWeatherSummary
        }
    }

    /// 次源 = Open-Meteo 时的概要。
    @ViewBuilder
    private var secondaryOpenMeteoSummary: some View {
        if let daily = openMeteoDaily, !daily.isEmpty {
            Text(Self.secondaryOpenMeteoText(
                    Array(daily.prefix(Self.secondaryDayLimit)),
                    timeZone: timeZone))
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            // 🔴 nil 与「取不到」严格区分（同 `openMeteoContent` 的理由）。
            Text(openMeteoDaily == nil
                 ? "尚未就绪：等待主屏天气快照加载完成。"
                 : "上游未下发逐日预报（合法响应，非故障）。")
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 次源 = 和风时的概要（**四态压缩成一行，原因不失真**）。
    @ViewBuilder
    private var secondaryQWeatherSummary: some View {
        switch model.state {
        case .idle:
            Text("尚未加载。")
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
        case .noData:
            Text("上游未下发逐日预报（合法响应，非故障）。")
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
        case .available:
            Text(Self.secondaryQWeatherText(model.days, timeZone: timeZone))
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        case .unavailable(let message):
            // 🔴 取不到就把**原因**带出来（绝不压缩成「加载失败」）。
            Text("取不到：" + message)
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 页脚（🔴 合规：attributions 必须展示）

    /// 页脚：**无条件**渲染 `attributions`（官方许可条件）。
    ///
    /// 🔴 即使 `.unavailable`（数据取不到）也渲染 —— 上游仍给了署名，
    ///    漏掉就是违反许可条件。
    /// 🔴 **即使当前主源是 Open-Meteo 也照旧渲染**：本卡**始终**在展示和风
    ///   数据（作为次源），署名义务不因「用户点了哪个按钮」而消失。
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

            // 🔴 Open-Meteo 也在本卡显示数据（次源 / 海外主源）→
            //   **同样需要署名**（CC BY 4.0「appropriate credit」义务）。
            //   ⚠️ 这是**新增**的合规义务，不是可选项 —— 本轮让 Open-Meteo
            //   数据上了这张卡，就得把它一起署上。
            Text("Open-Meteo · " + Self.openMeteoCredit)
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    // MARK: - 次源文案（纯函数，预先拼好 —— 类型检查器友好）

    /// 次源 Open-Meteo 概要最多展示几天（**小字**区不宜过长）。
    static let secondaryDayLimit = 3

    /// 主源 Open-Meteo 逐日最多展示几天（与和风端点默认窗口对齐量级）。
    static let openMeteoDayLimit = 7

    /// Open-Meteo 署名（官网；CC BY 4.0 的可追溯credit）。
    static let openMeteoCredit = "open-meteo.com"

    /// 源 id → 用户可读名（**单一真源**：从 `SourceDirectory` 派生，不写死）。
    ///
    /// ⚠️ 查不到 → 回退成 `rawValue`（**如实显示 id**，不编一个名字）。
    /// `nonisolated`：只读 `SourceDirectory.all`（`let` 常量，无共享可变状态），
    /// 与 `MinutelyPrecipitationCard.probabilityLabel` 同款理由。
    nonisolated static func sourceName(_ id: SourceID) -> String {
        SourceDirectory.descriptor(for: id)?.displayName ?? id.rawValue
    }

    /// 次源小标题（「另一数据源：xxx」）。
    nonisolated static func secondaryTitle(_ id: SourceID) -> String {
        "另一数据源：" + sourceName(id)
    }

    /// 「为什么这样选源」→ 如实说明（Core 纯函数产出，视图不拼句子）。
    ///
    /// `nonisolated`：`RegionalSourcePolicy` 在 **Core**（纯函数、无隔离），
    /// 故本方法无需主 actor 隔离。
    nonisolated static func rationaleText(_ region: WeatherRegion) -> String {
        RegionalSourcePolicy.rationaleText(for: region)
    }

    /// 次源 = Open-Meteo 的概要文案（**预先拼好**，不在 ViewBuilder 里内插）。
    ///
    /// ⚠️ **刻意不加 `nonisolated`**：它调`WeatherTimeFormatter.string`，
    ///   而后者是**类型级 `@MainActor`**（缓存是未加锁共享可变状态，
    ///   见该文件「并发纪律」）。标`nonisolated` 会让编译器直接报错 ——
    ///   这正是 P-06b 说的「类型级隔离传染」，此处**从着它**才是对的。
    static func secondaryOpenMeteoText(_ days: [DailyForecast],
                                       timeZone: TimeZone) -> String {
        guard !days.isEmpty else { return "" }
        let parts: [String] = days.map { day in
            let label = openMeteoDayText(day.date, timeZone: timeZone)
            return label + " " + rangeText(from: day.tempMax, to: day.tempMin)
        }
        return parts.joined(separator: " · ")
    }

    /// 次源 = 和风的概要文案（**预先拼好**）。
    ///
    /// ⚠️ 同样**不加 `nonisolated`**：它调 `dayText(_:timeZone:)`，
    ///   那条路径经`WeatherTimeFormatter.parseISO8601`（也是 `@MainActor`）。
    static func secondaryQWeatherText(_ days: [QWeatherDay],
                                      timeZone: TimeZone) -> String {
        guard !days.isEmpty else { return "" }
        let parts: [String] = days.prefix(secondaryDayLimit).map { day in
            let label = dayText(day, timeZone: timeZone)
            return label + " " + rangeText(day)
        }
        return parts.joined(separator: " · ")
    }

    /// Open-Meteo 逐日的日期文本（**独立函数**：`dayText(_:timeZone:)` 收的是
    ///   和风的 `QWeatherDay`，两者**不是**同一个类型，**不可复用**）。
    ///
    /// ⚠️ 不加 `nonisolated`：经 `WeatherTimeFormatter`（`@MainActor`）。
    static func openMeteoDayText(_ date: Date, timeZone: TimeZone) -> String {
        WeatherTimeFormatter.string(from: date, format: "MM-dd", timeZone: timeZone)
    }

    /// 🔴 两个源**共用**的高低温格式化（**单一真源**）。
    ///
    /// ⚠️ 为什么拆出来：和风侧 `rangeText(_ day:)` 收的是 `QWeatherDay`
    ///   （字段可空 → 要「暂无」分支），本函数收两个标量（**非可选**，
    ///   领域模型已保证）。**共用同一份拼接逻辑**，避免两处各写一遍而漂移。
    /// `nonisolated`：纯 `String(format:)`，无隔离依赖（同 `probabilityLabel`）。
    nonisolated static func rangeText(from high: Double, to low: Double) -> String {
        temperatureText(high) + " ~ " + temperatureText(low)
    }

    /// 单个温度值 → 文本（**必须经此函数**，两源共用）。
    ///
    /// ⚠️ `nonisolated`：纯格式化，`String(format:)` 不碰任何隔离状态。
    nonisolated static func temperatureText(_ value: Double) -> String {
        //⚠️ 与既有和风侧**逐字一致**（一位小数），共用它避免两源漂移。
        String(format: "%.1f", value)
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

    /// 单个温度值 → 文本（保留一位小数）。
    ///
    /// ⚠️ **本文件里唯一的温度格式化实现**（`nonisolated`，见上方说明）。
    /// 和风侧与 Open-Meteo 侧**都调它** —— 本轮新增 Open-Meteo 渲染时
    /// 刻意**没有**再写第二份 `String(format: "%.1f")`（两份同款代码必然漂移）。
    ///
    /// ⚠️ 单位用上游给的（实测 `°C`），**不硬编码** ——
    ///   若将来请求 `lang`/`unit` 变了，单位应跟着变。
    nonisolated static func temperatureText(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// 日期文本：把上游的 **UTC ISO8601** 串按城市时区渲染。
    ///
    /// ⚠️ 实测 `forecastStartTime = "2026-10-07T16:00Z"`（**UTC**）。
    ///
    /// 🔴🔴 **本函数此前一直解析失败，只是从没有测试覆盖过**
    ///   （首次被测：CI run#37758888046 的逐时用例，同根因连带暴露本卡）。
    ///   原因：原来用的是本文件私有的 `ISO8601DateFormatter` +
    ///   `.withInternetDateTime`，而该选项**要求串里有秒**（`hh:mm:ss`），
    ///   实测的 `16:00Z` 是**无秒**的 → `date(from:)` 返回 nil
    ///   → 如实退回原始串 → **卡片上一直显示 `2026-10-07T16:00Z` 而不是 `10-08`**。
    ///   即：这条路径「看起来一直能跑」，实际一直在显示原始串。
    ///   → 现改为共用 Core 的容错解析器（多格式回退）。
    ///   解析失败仍**如实退回原始串**，**绝不**显示空白或错日期。
    static func dayText(_ day: QWeatherDay, timeZone: TimeZone) -> String {
        guard let raw = day.forecastStartTime else {
            // ⚠️ 上游没给开始时间 → 不编造日期。
            return "日期待定"
        }
        guard let parsed = WeatherTimeFormatter.parseISO8601(raw) else {
            // 解析不了 → 显示上游原文（仍是有用信息），不假装成合法日期。
            return raw
        }
        return WeatherTimeFormatter.string(from: parsed, format: "MM-dd", timeZone: timeZone)
    }
}
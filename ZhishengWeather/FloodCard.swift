//
//  FloodCard.swift
//  ZhishengWeather（主 App target）
//
//  河道流量（洪水）卡（**主屏装配入口**）：逐日流量序列 + 数据说明。
//
//  ── 装配契约 ──────────────────────────────────────────────────────
//  · 状态由 `FloodCardModel` 提供（`@Observable`），本视图**只渲染，不判定**；
//  · 四态（`.idle` / `.noData` / `.available` / `.unavailable(reason)`）
//    **全部**必须渲染出**可见内容**，**绝不允许**空白页。
//
//  ── 🔴 「这一带没有河道」与「取不到」是**两件事**（硬要求）───────────
//  · `.noData` → 「该坐标无河道流量数据」，是**合法业务结果**
//    （flood 端点实测存在 `daily` 键整块省略、HTTP 仍 200 的形态）；
//  · `.unavailable` → 「河道流量取不到」+ 原因 + 可重试。
//  两者**绝不共用一句话** —— 共用就把「取不到」说成了「没有」，那是内容错误
//  （同 `TyphoonCard` 的 `.none` / `.unavailable` 纪律）。
//
//  ── 🔴 `0.00` 是**真实读数**（断流），不是缺测 ─────────────────────
//  实测乌鲁木齐 (43.8,87.6) 断流时返回 `[0.00, 0.00, 0.00]`。
//  故：值非 nil 就照实显示 `0.00`；**只有 nil 才显示「缺测」**，
//  **绝不**把 nil 渲染成 0.00（那是凭空造一条断流读数）。
//
//  ── 🔴 「这是哪条河」**无法回答**，本轮把能回答的部分如实呈现 ─────────
//  主理人问「河道流量指的是哪里的河」。结论（官方文档 + 本机实测双重确认）：
//  **上游根本不返回河名** —— `daily` 块只有 `time` 与 `river_discharge`
//  两个键，含 name / river 的键 **0 个**。所以本卡**绝不编一个河名**。
//
//  能如实回答的是「数据取自哪儿」：响应**回显了网格中心坐标**
//  （实测请求 39.909,116.397 → 回显 39.925003,116.375，距离约 2~3 km）。
//  故页脚固定写清两件事：
//    ① 这是「5 km 网格内**最大**的那条河」，**不保证是你最近的那条**；
//    ② 数据取自距所选位置约 N km 的网格点（N 由回显坐标算出，取整公里）。
//
//  ── 🔴 「重合」与「不可知」必须分开 ───────────────────────────────────
//  上游没回显网格坐标 → 距离**不可知**，此时**不显示距离行**（而不是显示「约 0 km」）；
//  回显坐标与请求坐标完全重合 → 距离确实是 0，如实显示「网格与所选位置重合」。
//  把两者混同，就会对用户谎报数据的空间来源。
//
//  ── 量纲纪律（最容易错的一处）──────────────────────────────────────
//  `RiverDischargePoint.cubicMetresPerSecond` 单位是 **m³/s**（实测
//  `daily_units.river_discharge == "m³/s"`）。它**不是**水位（m）、
//  不是降水量（mm）、不是水量（m³）。故本页所有数值都带 `m³/s` 后缀，
//  且**不**与「当前水位」「警戒水位」混说 —— 本源不提供水位。
//
//  ── 坐标序 ────────────────────────────────────────────────────────
//  本视图**只展示**模型已给出的 `date` / `cubicMetresPerSecond`，
//  绝不做任何二次换算（换算是 Core mapper 的职责）。
//
//  ⚠️ 本类型带类型级 `@MainActor`（本仓纪律：每个 `struct ... : View` 都带，
//    见 docs/CI-pitfalls.md P-06）。
//

import Foundation
import SwiftUI

/// 河道流量卡（逐日 m³/s 序列）。
@MainActor
struct FloodCard: View {

    /// 状态容器（四态 + 逐日序列的唯一真源）。
    let model: FloodCardModel

    /// 日期渲染时区（D-4：选中城市时区；缺省设备时区）。
    var timeZone: TimeZone = .current

    /// 本卡折叠态（初值读持久化；点标题行右侧按钮翻转）。
    @State private var isCollapsed: Bool = CardVisibilityStore.isCollapsed(.flood)

    /// 序列最多展示多少天（**实测端点 `forecast_days = 7`**）。
    ///
    /// ⚠️ 这里**按数据长度截取**，不写死"7 天"当契约：
    /// 端点哪天改窗口，这里跟着变；写死则会出现"第 8 天被静默吞掉"。
    private var visiblePoints: [RiverDischargePoint] {
        // `Array(...prefix(...))` 而非 `.prefix(...).map { $0 }`：
        // 前者一步到位、不引入闭包，也就不会和标准库 `map` 撞名（P-32 纪律）。
        Array((model.discharge?.daily ?? []).prefix(FloodEndpoint.forecastDays))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            // 折叠态：只保留标题行，主体内容（列表 + 页脚）不渲染。
            if !isCollapsed {
                content
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
            // ⚠️ 图标只用**本仓已实际使用过**的 SF Symbol（P-24 纪律：
            // 不写"听起来应该有"的符号名）。`water.waves` 与潮汐卡同款。
            Image(systemName: "water.waves")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("河道流量")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Spacer(minLength: 0)
            Text("m³/s")
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
            if model.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
            }
            CardCollapseButton(card: .flood, isCollapsed: isCollapsed, onToggle: toggleCollapse)
        }
    }

    // MARK: - 折叠切换

    /// 翻转折叠态：落库 + 改本地状态（动画与图标统一由 `CardCollapseButton` 驱动）。
    private func toggleCollapse() {
        let next = CardCollapseButton.toggleCollapsed(.flood)
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
            // 🔴 与 `.unavailable` **必须是不同的文案**（「这一带没有河道」≠「取不到」）。
            statusRow(icon: "checkmark",
                      title: "该坐标无河道流量数据",
                      detail: "上游返回的逐日序列为空值，这是正常的地理事实，不是故障。")

        case .available:
            list

        case .unavailable(let message):
            statusRow(icon: "exclamationmark.triangle",
                      title: "河道流量取不到",
                      detail: message)
        }
    }

    // MARK: - 逐日列表

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ⚠️ 序列为空却判为 `.available` 在模型里**不可能**
            //（`isEffectivelyEmpty` 为真即走 `.noData`）。这里仍给可见文字，
            // 因为「绝不留空白」比「省一个分支」重要。
            if visiblePoints.isEmpty {
                Text("暂无可展示的逐日数据")
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                // `RiverDischargePoint` 是 `Identifiable`（`id` = 当地日期），
                // 故 ForEach 无需 `id:` 参数。
                ForEach(visiblePoints) { point in
                    row(point)
                }
            }
        }
    }

    /// 单日一行（日期 + 流量）。
    ///
    /// ⚠️ nil → 显示「缺测」，**绝不**显示 `0.00`（那会凭空造一条断流读数）。
    private func row(_ point: RiverDischargePoint) -> some View {
        HStack(spacing: 8) {
            Text(Self.dayText(point.date, timeZone: timeZone))
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 8)
            if let value = point.cubicMetresPerSecond {
                // ⚠️ `0` 是**合法读数**（断流），照实显示、不特殊处理。
                //
                // ⚠️ 刻意**不加** `.monospacedDigit()`：该修饰符在本仓
                // **无既有用例**，P-31（无编译器时「参考周围代码但没核实」
                // 是独立错误类）下不写未经核实的 API。等宽数字只是锦上添花，
                // 拿"可能编译不过"去换一个对齐效果，不划算。
                Text(String(format: "%.2f", value))
                    .font(.system(size: Theme.FontSize.metric, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
            } else {
                Text("缺测")
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    // MARK: - 页脚

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.hasTimedOut {
                Text(Self.timeoutText)
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.accentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // ⚠️ 序列里**可能混着缺测日**（实测 `FloodMapper` 对「时刻为 null」是跳过、
            // 对「值为 null」是**保留 nil**），故显式点明"最早有流量的那一天是哪天"——
            // 否则第一行显示「缺测」会被读成"这条数据坏了"。
            if let measured = model.firstMeasuredPoint {
                Text("序列中最早有流量的日期：" + Self.dayText(measured.date, timeZone: timeZone)
                     + "；标「缺测」者表示该日上游未提供数值（不是 0）")
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 🔴 语义边界（**硬要求**，理由见文件头「量纲纪律」）：
            // 必须说清「这是流量不是水位」，否则用户会拿它跟本地水尺比。
            Text("数值为日均河道流量（m³/s），非水位；本数据源不提供警戒水位，请以当地预警为准。")
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            // 🔴🔴 「这是哪条河」的如实回答（本轮新增，**硬要求**）：
            //   上游不返回河名 → 绝不编；只说「取自哪片网格」。
            // ⚠️ **无条件渲染**：这不是数据行，而是**能力边界**声明 ——
            //   即使某天上游改给了别的字段，「不保证是你最近的那条河」这句
            //   仍是用户必须知道的前提。放页脚而非条件里，是为了漏不掉。
            // ⚠️ **刻意不用 markdown 强调**（`Text` 不解析 `**`，会原样显示
            //   星号）：强调靠措辞（「最大」「不保证」），不靠标记。
            Text("这是所选位置 5 km 范围内流量最大的那条河的流量；上游不提供河名，"
                 + "且因网格分辨率有限，不保证是你最近的那条河。")
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            // 🔴 网格距离：**能算才算**（precomputed，ViewBuilder 里不内联换算，
            //   否则 Swift 类型检查器会超时——本仓在 `EarthquakeCard` / `QWeatherCard`
            //   上都实测踩过）。
            if let distanceText = Self.gridDistanceText(hasEchoedGridPoint: model.hasEchoedGridPoint,
                                                        distanceKilometers: model.gridDistanceKilometers) {
                Text(distanceText)
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("数据来源：Open-Meteo Flood API（免 Key）；内陆城市同样可能有值（如北京、拉萨实测均有）。")
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 小工具

    /// 超时文案（**预先拼好**，不内联数值转换）。
    ///
    /// ⚠️ 与 `QWeatherCard.timeoutText` 同款纪律：`String(Int(FloodCardModel.loadTimeout))`
    ///   直接写在 `VStack` 的 ViewBuilder 里会让 Swift 类型检查器**超时**
    ///   （本仓在 `EarthquakeCard` 上实测报
    ///   `the compiler is unable to type-check this expression in reasonable time`）。
    static let timeoutText: String = {
        let seconds = Int(FloodCardModel.loadTimeout)
        return "加载超时（超过 " + String(seconds) + " 秒）· 上方数据可能不是最新"
    }()

    /// 网格距离行文案；**不可知时返回 nil**（整行不渲染）。
    ///
    /// 🔴 三种情形必须分开（本函数就是那道闸门）：
    ///   · 未回显网格坐标 → **nil**（不显示这一行）。
    ///     绝不显示「约 0 km」—— 那会让「不知道」被读成「就在你脚下」。
    ///   · 距离为 0（坐标完全重合）→ 「数据网格与所选位置重合」。
    ///   · 其余 → 「数据取自距所选位置约 N km 的网格点」，N **取整公里**。
    ///
    /// ⚠️ **为什么取整**：实测偏移只有 2~3 km，显示 `2.4 km` 是**伪精度**
    ///   （上游网格是 5 km 分辨率，本身给不出米级精度）。
    /// ⚠️ **为什么必须说「由本应用计算」**：距离是本应用按 Haversine 算的，
    ///   **不是**上游测距 —— 不标注就是谎报出处（同 `EarthquakeCard` 纪律）。
    ///
    /// `nonisolated`：纯格式化、无共享状态，脱离类型级 `@MainActor` 以便直接单测
    /// （沿用 `MinutelyPrecipitationCard.probabilityLabel` 的既有做法）。
    /// ⚠️ 刻意**只吃标量**、不吃 `FloodCardModel`（那个是 `@MainActor` 类型，
    ///   传它进来就得加 `await`，测试里也得多套一层）。
    ///
    /// - Parameters:
    ///   - hasEchoedGridPoint: 上游是否回显了网格坐标。
    ///   - distanceKilometers: 请求点到网格点的距离（可缺 / 非有限）。
    /// - Returns: 页脚文案；**不可知** → nil（整行不渲染）。
    nonisolated static func gridDistanceText(hasEchoedGridPoint: Bool,
                                             distanceKilometers: Double?) -> String? {
        guard hasEchoedGridPoint, let distance = distanceKilometers, distance.isFinite else {
            // 上游没回显网格坐标 → **不可知**。整行不渲染。
            return nil
        }
        // 四舍五入到整公里。⚠️ 不用 `%.0f`：那对 0.4 会输出 "0"，
        //   与下面的重合分支撞车（两句不同的话，必须由**代码分支**区分，
        //   而不是让同一个格式化结果去碰运气）。
        let rounded = distance.rounded()
        if rounded < 1 {
            // 🔴 距离确实在 1 km 以内（含真 0）：说「重合」比说「约 0 km」诚实，
            //   且「约 0 km」在中文里读起来就是自相矛盾的伪精度。
            return "数据网格与所选位置重合（同一网格点）。"
        }
        let kilometers = Int(rounded)
        return "数据取自距所选位置约 " + String(kilometers)
            + " km 的网格点（距离由本应用按 Haversine 公式计算，非上游测距）。"
    }

    /// 状态行（**必须有可见文字**，绝不留空白）。
    private func statusRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
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
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// 「M月d日」（按传入时区；复用 Core 既有格式器）。
    private static func dayText(_ date: Date, timeZone: TimeZone) -> String {
        WeatherTimeFormatter.string(from: date, format: "M月d日", timeZone: timeZone)
    }
}
//
//  SatelliteCard.swift
//  ZhishengWeather（主 App target）
//
//  卫星云图卡（**主屏装配入口**）：风云四号真彩云图 + 观测时刻 + 像素校验说明 +
//  原图外链。状态全部由 `SatelliteCardModel` 提供，本视图**只渲染、不判定**。
//
//  ═══════════════════════════════════════════════════════════════════════
//  ── 装配契约 ──────────────────────────────────────────────────────
//  · 四态（`.idle` / 加载中 / `.loaded` / `.unavailable(reason)`）**全部**渲染出
//    **可见内容**，绝不允许空白页、绝不允许"空白地图"（无图时不画图）。
//  · 本卡**无条件挂载**在 `ContentView.mainScroll` 内（与 `RadarMapCard` /
//    `TyphoonCard` 同级、`ForEach(orderedVisibleSections)` 之前）——
//    **不占用 `HomeSection`**，避免老用户持久化顺序把它补到尾部。
//
//  ── 🔴 四态必须分开，绝不共用一句「加载失败」─────────────────────
//  `.unavailable` 的 `reason` 依据不同、含义不同（见 `SatelliteCardModel` 文件头）：
//   · 网络 / 保留窗口内全部时次缺失 → 「未找到可用时次」；
//   · 帧是 404 的 openresty HTML 错误页 → 「云图服务返回的不是图片」；
//   · 帧纯黑 → 「该时次云图为空白（夜间或无日照时段）」。
//  把三者混成一句「加载失败」= **内容错误**：用户在夜间看到「加载失败」
//  会以为产品坏了，而实际只是那一帧没有日照。
//
//  ── 🔴 为什么默认关闭（`isEnabled` 默认 false）────────────────────
//  云图是**整幅亚洲区域**的位图（实测 860×540，覆盖东经 48°–160°、
//  北纬 3°–66°），盖在地图上会把底图**完全遮住**。理由写在
//  `SatelliteCardModel.isEnabled` 的文档注释里（单一真源，本视图不重复论证）。
//  → 故本卡把开关**显式画给用户看**，并说明为什么默认关；
//  绝不在用户未开启时偷偷发起请求、也绝不在用户开启后还显示"为什么没有图"。
//
//  ── 加载触发：写在**卡内**，不写在 `ContentView` ──────────────────
//  · `.task(id: model.isEnabled)`：卡一出现 `isEnabled` 为 false → **直接返回、
//    不发任何请求**（这正是"默认关闭"的兑现）；用户拨开开关 → `id` 变化 →
//    触发唯一一次 `load()`。
//  · **刻意不绑城市 id**：云图产品**与选中城市无关**——
//    `SatelliteCardModel.load(now:)` 的入参只有时间，`SatelliteImageService`
//    的 URL 也只由**时戳**决定（`SatelliteImageEndpoint.productURL`）。
//    绑 `id: 城市 id` 会让每次切城都无谓重跑一次回溯探测
//    （最坏 48 步），与台风卡 `.task` **不绑 id** 的既有判据完全同款
//    （见 `ContentView` 里 `TyphoonCard` 上方那段注释）。
//
//  ── 时钟 ──
//  本视图**不调 `Date()`**：观测时刻来自模型注入的 `observationDate`（UTC 观测时刻），
//  按**选中城市时区**渲染（D-4 纪律：异地城市的钟点用设备时区渲染会说谎）。
//
//  ⚠️ 本类型带类型级 `@MainActor`（本仓纪律：每个 `struct ... : View` 都带，
//    见 docs/CI-pitfalls.md P-06）。
//

import Foundation
import SwiftUI
// ⚠️ `UIImage` 属于 **UIKit**，不由 SwiftUI 保证 re-export
// （同款判断见 `RadarMapCard.swift` 对 `UIScreen` 的注释）→ 显式引入，零成本。
// 本类型整体已标 `@MainActor`，故 `UIImage` 的隔离也满足。
import UIKit

/// 卫星云图卡（单帧真彩云图 + 观测时刻 + 校验说明 + 原图外链）。
@MainActor
struct SatelliteCard: View {

    /// 状态容器（四态、`image`、`observationDate`、`sourceURL`、
    /// `pixelValidation`、`isEnabled` 的**唯一真源**）。
    let model: SatelliteCardModel

    /// 时刻渲染时区（D-4：选中城市时区；缺省设备时区）。
    var timeZone: TimeZone = .current

    /// 云图画布高度（pt）。
    ///
    /// ⚠️ 实测帧恒为 **860×540**（`SatelliteFrameValidator` 文件头），
    /// 这里只约束**显示高度**、按比例缩放，**不做任何裁剪或重采样**。
    private let imageHeight: CGFloat = 180

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
        // ⚠️ 加载触发写在**卡内**（理由见文件头「加载触发」小节）。
        // `.task(id:)` 的 `id` 只需 `Equatable`，`Bool` 满足。
        .task(id: model.isEnabled) {
            // 默认关闭 → **不发任何请求**（"默认关闭"必须真的不下载）。
            guard model.isEnabled else { return }
            await model.load()
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "cloud")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("卫星云图")
                .font(.system(size: Theme.FontSize.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Spacer(minLength: 0)
            // `isLoading` 只驱动"正在加载"，**不参与**四态判定（与既有卡片同款）。
            if model.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
            }
            // 图层开关：默认关闭（理由见文件头），显式画给用户看。
            //
            // ⚠️ 刻意**不**用 `.labelsHidden()`：该修饰符在本仓无既有用例
            // （P-31：无编译器时只写本仓已验证的写法）。开关文字「显示云图」
            // 直接显示出来反而更清楚 —— 用户知道拨的是什么。
            Toggle("显示云图", isOn: Binding(
                get: { model.isEnabled },
                set: { newValue in model.isEnabled = newValue }
            ))
            .tint(Theme.accent)
        }
    }

    // MARK: - 四态内容

    @ViewBuilder
    private var content: some View {
        // 未开启 → 只说明"为什么默认关" + 怎么开，**不发请求、不画图**。
        if !model.isEnabled {
            // ⚠️ 图标只用**本仓已实际使用过**的 SF Symbol
            // （P-24纪律：不写"听起来应该有"的符号名）。
            statusRow(icon: "cloud",
                      title: "云图默认关闭",
                      detail: "风云四号真彩云图是整幅亚洲区域的位图，盖在地图上会完全遮住底图；"
                            + "而看回波、看预警都需要底图。拨动上方开关即可加载。")
        } else {
            switch model.state {
            case .idle:
                if model.isLoading {
                    statusRow(icon: "arrow.clockwise",
                              title: "正在取数",
                              detail: "正在回溯最近的可用时次（保留窗口日内有洞，最多回溯 48 帧）。")
                } else {
                    statusRow(icon: "cloud",
                              title: "尚未加载",
                              detail: "拨动上方开关后开始取数。")
                }
            case .loaded:
                // 🔴 `.loaded` 但 `image == nil` 在模型里**不可能**发生
                //（`load` 内已 `UIImage(data:)` 成功才写 `.loaded`）。
                // 这里仍逐字段判空并给出**可见文字**而不是空白 —— 视图不替模型
                // 兜底，但也不能因为"不可能"就留一个空白框。
                if let image = model.image {
                    imageArea(image)
                    loadedMeta
                } else {
                    statusRow(icon: "exclamationmark.triangle",
                              title: "云图未能显示",
                              detail: "该时次的字节已通过校验，但无法在屏幕上解码显示。")
                }
            case .unavailable(let reason):
                // 🔴 与其它三态**必须是不同的文字**（理由见文件头）。
                statusRow(icon: "exclamationmark.triangle",
                          title: "云图取不到",
                          detail: reason)
            }
        }
    }

    // MARK: - 云图画面

    /// 云图本体（等比缩放，**不裁剪**）。
    ///
    /// ⚠️ `resizable()` / `aspectRatio(contentMode:)` / `clipShape` 三者在本仓
    /// **无既有用例**（只有 `clipShape(RoundedRectangle(cornerRadius:))` 有），
    /// 属P-31「参考周围代码但没核实」的风险点，故在此写明依据：
    /// 三者均为 SwiftUI **iOS 13 起**的稳定公开 API（`Image` / `View` 修饰符），
    /// 非本仓自造、非臆造。若 CI 报不认，改回
    /// `.frame(maxWidth: .infinity, height: imageHeight)` 亦可（牺牲等比）。
    private func imageArea(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity)
            .frame(height: imageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 已加载态的元信息行：观测时刻 + 像素校验说明 + 原图外链。
    private var loadedMeta: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // ⚠️ `observationDate` 是 **UTC 观测时刻**，按时区渲染（D-4）。
                // 为 nil 时**不显示这一项**（而不是显示 "未知" 冒充有值）。
                if let observed = model.observationDate {
                    Text("观测 " + Self.timeText(observed, timeZone: timeZone))
                        .font(.system(size: Theme.FontSize.caption))
                        .foregroundStyle(Theme.primaryText)
                }
                Spacer(minLength: 0)
                if let url = model.sourceURL {
                    Link(destination: url) {
                        HStack(spacing: 3) {
                            Text("查看原图")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9))
                        }
                        .font(.system(size: Theme.FontSize.footnote))
                    }
                }
            }
            // 🔴 如实上报像素层**到底跑没跑**：`.unavailable` 时这句话是
            //「仅按数据量判定」，**不是**「云图有效」。把它显示出来，
            // 是因为"没判"与"判过了"是两件事，混起来就成了谎报。
            Text(model.pixelValidation.message)
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(pixelValidationColor)
        }
    }

    /// 像素校验说明的着色（**弱 = 已校验；强调 = 没校验**）。
    ///
    /// ⚠️ 刻意**不写** `foregroundStyle(cond ? a : b)`：本仓 `foregroundStyle`
    ///   有 `Color` / `HierarchicalShapeStyle` / `DynamicHierarchicalShapeStyle`
    ///   多个重载，条件表达式传参在无编译器环境下有类型推断歧义风险
    ///   （P-31）。先落成一个**显式标注返回类型**的计算属性，最省事。
    private var pixelValidationColor: Color {
        model.pixelValidation == .passed ? Theme.secondaryText : Theme.accentSecondary
    }

    // MARK: - 页脚

    /// 页脚：超时提示 + 来源说明（**两件都要说**，缺一件用户就会误判）。
    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.hasTimedOut {
                Text("加载超时（超过 \(Int(SatelliteCardModel.loadTimeout)) 秒）· 上方结果可能不是最新时次")
                    .font(.system(size: Theme.FontSize.footnote))
                    .foregroundStyle(Theme.accentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("数据来源：中央气象台风云四号真彩卫星；整幅覆盖亚洲区域，非选中城市局部图。")
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 小工具

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

    /// 「MM-dd HH:mm」（按传入时区；复用 Core 既有格式器）。
    private static func timeText(_ date: Date, timeZone: TimeZone) -> String {
        WeatherTimeFormatter.string(from: date, format: "MM-dd HH:mm", timeZone: timeZone)
    }
}
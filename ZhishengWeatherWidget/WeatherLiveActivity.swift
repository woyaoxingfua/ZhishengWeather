//
//  WeatherLiveActivity.swift
//  ZhishengWeatherWidget（Widget target）
//
//  实时活动（ActivityKit）的 **UI 渲染端**：`WeatherLiveActivity` 提供
//  `ActivityConfiguration(for:)`，系统据此渲染锁屏横幅与灵动岛。
//
//  为什么必须有本文件（**缺它 = 确定性缺陷**）：
//  App 侧 `Activity.request` 能成功启动活动，但系统会到 **Widget Bundle 里**
//  找与该活动属性类型匹配的 `ActivityConfiguration`。Bundle 里没有它 →
//  活动处于「已启动、无 UI 可渲染」状态：不报错、不崩溃、用户永远看不到内容，
//  CI 也全绿（本地编译断言抓不到）。故本文件是实时活动闭环的**必要一半**。
//
//  版面分配（iOS 17 SDK 的确定形态，不用 16.1 早期旧闭包签名）：
//    · 锁屏横幅 `content`：左「城市名 + 现象」/ 右「温度大字」，底部一行更新时间；
//    · `DynamicIsland` 展开态：`.leading` 城市名 + 现象、`.trailing` 温度大字、
//      `.bottom` 更新时间；
//    · 收起态 `compactLeading` 温度、`compactTrailing` 现象；
//    · `minimal` 只留温度（最小圆环位最窄，只放一个值）。
//  `center` 区不占用：展开态左右两侧已有城市与温度，中心留白避免与前置摄像头
//  区域打架。
//
//  纪律：
//  - **诚实渲染**：`context.state` 字段为 nil 就渲染如实的占位（「—」/「暂无数据」），
//    **绝不**用假数据把空态填满；城市名缺失时渲染「—」，**不编造城市名**、
//    也不在代码里写死任何城市。
//  - **每个视图一个 struct**：版面不塞成一坨，各视图配中文 docstring。
//  - 只 import ActivityKit / SwiftUI / WidgetKit —— **不引 UIKit**。
//  - 禁 `!` / `try!` / `as!` / `fatalError`；取值一律走可空解析。
//

import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - 实时活动定义

/// 天气实时活动：`ActivityConfiguration` 的提供者。
///
/// `WeatherActivityAttributes` 来自 Core（主 App 与 Widget 双 target 共享），
/// 保证「启动端」与「渲染端」看到的是同一份契约。
struct WeatherLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WeatherActivityAttributes.self) { context in
            // 锁屏横幅 / 非灵动岛机型的展示位。
            WeatherLiveActivityLockScreenView(content: WeatherLiveActivityContent(state: context.state))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WeatherLiveActivityExpandedLeadingView(content: WeatherLiveActivityContent(state: context.state))
                }

                DynamicIslandExpandedRegion(.trailing) {
                    WeatherLiveActivityExpandedTrailingView(content: WeatherLiveActivityContent(state: context.state))
                }

                DynamicIslandExpandedRegion(.bottom) {
                    WeatherLiveActivityExpandedBottomView(content: WeatherLiveActivityContent(state: context.state))
                }
            } compactLeading: {
                WeatherLiveActivityCompactLeadingView(content: WeatherLiveActivityContent(state: context.state))
            } compactTrailing: {
                WeatherLiveActivityCompactTrailingView(content: WeatherLiveActivityContent(state: context.state))
            } minimal: {
                WeatherLiveActivityMinimalView(content: WeatherLiveActivityContent(state: context.state))
            }
        }
    }
}

// MARK: - 文案解析（nil → 诚实占位，唯一真源）

/// 实时活动的可渲染文案：把 `ContentState` 的可空字段解析成**可安全上屏的字符串**。
///
/// 占位口径（诚实纪律的唯一真源，各视图只准读这里）：
/// 城市名 / 温度 → 「—」（版面窄，短占位）；现象 → 「暂无数据」；
/// 更新时间 → 「暂无更新时间」。**任何分支都不产生假数据。**
struct WeatherLiveActivityContent {

    /// 窄版面用的短占位符（城市名、温度）。
    private static let shortPlaceholder: String = "—"

    /// 描述类字段的占位符（现象）。
    private static let emptyTextPlaceholder: String = "暂无数据"

    /// 城市名（nil → 「—」；**绝不编造城市名**）。
    let cityName: String

    /// 温度文案（nil → 「—」）。
    let temperatureText: String

    /// 天气描述文案（nil → 「暂无数据」）。
    let conditionText: String

    /// 更新时间整行文案（nil → 「暂无更新时间」；有值时带「更新于」前缀）。
    let updatedAtLine: String

    /// 按占位口径解析动态内容。
    ///
    /// - Parameter state: 实时活动的动态内容（字段全部可空）。
    init(state: WeatherActivityAttributes.ContentState) {
        self.cityName = state.cityName ?? WeatherLiveActivityContent.shortPlaceholder
        self.temperatureText = state.temperatureText ?? WeatherLiveActivityContent.shortPlaceholder
        self.conditionText = state.conditionText ?? WeatherLiveActivityContent.emptyTextPlaceholder
        if let updatedAtText = state.updatedAtText {
            self.updatedAtLine = "更新于 \(updatedAtText)"
        } else {
            self.updatedAtLine = "暂无更新时间"
        }
    }
}

// MARK: - 锁屏横幅

/// 锁屏横幅视图：左「城市名 + 现象」，右「温度大字」，底部一行更新时间。
struct WeatherLiveActivityLockScreenView: View {

    let content: WeatherLiveActivityContent

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(content.cityName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)

                Text(content.conditionText)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Text(content.updatedAtLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(content.temperatureText)
                .font(.system(size: 30, weight: .bold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }
}

// MARK: - 灵动岛：展开态

/// 灵动岛展开态·左区：城市名 + 现象。
struct WeatherLiveActivityExpandedLeadingView: View {

    let content: WeatherLiveActivityContent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(content.cityName)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)

            Text(content.conditionText)
                .font(.system(size: 12))
                .lineLimit(1)
        }
    }
}

/// 灵动岛展开态·右区：温度大字。
struct WeatherLiveActivityExpandedTrailingView: View {

    let content: WeatherLiveActivityContent

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(content.temperatureText)
                .font(.system(size: 22, weight: .bold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }
}

/// 灵动岛展开态·底区：更新时间一行（左对齐，与上方左区同一视觉列）。
struct WeatherLiveActivityExpandedBottomView: View {

    let content: WeatherLiveActivityContent

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Text(content.updatedAtLine)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }
}

// MARK: - 灵动岛：收起态与最小态

/// 灵动岛收起态·左槽：温度（最该被一眼看到的值）。
struct WeatherLiveActivityCompactLeadingView: View {

    let content: WeatherLiveActivityContent

    var body: some View {
        Text(content.temperatureText)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
    }
}

/// 灵动岛收起态·右槽：现象（左槽温度的补充信息）。
struct WeatherLiveActivityCompactTrailingView: View {

    let content: WeatherLiveActivityContent

    var body: some View {
        Text(content.conditionText)
            .font(.system(size: 12))
            .lineLimit(1)
    }
}

/// 灵动岛最小态：只留温度（该位置最窄，仅容纳一个短值）。
struct WeatherLiveActivityMinimalView: View {

    let content: WeatherLiveActivityContent

    var body: some View {
        Text(content.temperatureText)
            .font(.system(size: 11, weight: .semibold))
            .minimumScaleFactor(0.7)
            .lineLimit(1)
    }
}

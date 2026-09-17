//
//  WidgetCopy.swift
//  Core / Logic  [App + Widget 共用]
//
//  小组件各状态的**中文文案单一真源**（仿 `FaultDomain.message(for:)`）。
//
//  为什么需要（ARCH §8.2 理由 3）：旧实现让四个视图各自用 `== .unavailable`
//  拼状态句（Small / Medium / Large / Accessory 各一份）。一旦状态模型演化
//  （或如本轮新增来源 / 空因），**四处真源必然漂移**，且 `==` 比较**静默落到
//  else** → 编译通过、CI 全绿、真机文案错（P-18）。故把面向用户的句子全部
//  收进本文件（纯函数、CI 可单测），视图只做取值与渲染。
//
//  文案口径（ARCH §13 七态表）沿用项目现有口吻：「暂无数据」「共享数据不可用」
//  「可能已过期」，每条空态都给**下一步做什么**，绝不出现「出错了」。
//
//  实现纪律：`switch` 一律作用在**解包后**的 `WidgetEmptyReason` 上（避免对
//  `Optional` 枚举做裸 case 匹配 —— 那在类型推断上不必要地依赖编译器行为），
//  且**穷尽**该枚举、不留 `default`（新增空因时编译器会直接指出漏改处）。
//
//  时刻格式化的**边界**：Core 的 `WeatherTimeFormatter` 整体 `@MainActor`
//  （缓存是不变式），而 Widget 视图计算属性在 Xcode 15.4 下**非隔离**
//  （CI-pitfalls P-06）→ 从非隔离上下文调主 actor 成员是硬编译错误。
//  故本文件**不碰 DateFormatter**：`updateText` 接收**已格式化**的 "HH:mm"
//  （由 Widget 侧 `WidgetTimeFormatter` 产出），只负责**措辞**（单一真源仍在
//  本文件）。这是对 ARCH §18 `updateText(resolution, timeZone)` 的**有意偏差**，
//  理由如上（避免把 @MainActor 依赖引入非隔离视图路径）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 小组件文案（纯函数，无状态、无 IO、无时钟）。
enum WidgetCopy {

    // MARK: - 城市名

    /// 视图取名唯一入口：实例目标城市优先，回退快照 location（placeholder 预览路径）。
    /// - Parameter resolution: 收敛值。
    /// - Returns: 展示城市名；两者皆无 → nil（视图负责兜底占位符）。
    static func cityText(resolution: WidgetEntryResolution) -> String? {
        resolution.city?.name ?? resolution.payload?.snapshot.location.name
    }

    // MARK: - 现象位

    /// 现象位文案（§13 表 `conditionText` 列）。
    ///
    /// 有载荷 → 复用既有 `WMOCodeMapper.description(for:)`（**不新增映射**）；
    /// 无载荷 → 按空因给**如实**且可区分的一句话（「没取过数」「取不到」
    /// 「该城市没有数据」对用户含义不同，绝不混为一谈）。
    /// - Parameter resolution: 收敛值。
    /// - Returns: 非空中文短句。
    static func conditionText(resolution: WidgetEntryResolution) -> String {
        if let snapshot = resolution.payload?.snapshot {
            return WMOCodeMapper.description(for: snapshot.weatherCode)
        }
        // 兜底：有载荷已在上面返回；无载荷必有空因（不变式见 WidgetEntryResolution）。
        guard let reason = resolution.emptyReason else { return "暂无数据" }
        switch reason {
        case .noCity:
            return "暂无数据"
        case .noCachedData:
            return "暂无数据"
        case .sharedContainerDown:
            return "共享数据不可用"
        case .fetchFailed:
            return "未能获取天气"
        case .cityHasNoData:
            return "该城市暂无天气数据"
        }
    }

    // MARK: - 时间位

    /// 时间位文案（§13 表 `updateText` 列）。
    /// - Parameters:
    ///   - resolution: 收敛值。
    ///   - timeText: **已格式化**的 "HH:mm"（载荷存在时由调用方提供）；nil = 无载荷。
    /// - Returns: 「更新于 HH:mm」/ 追加「· 已过期」；无载荷时复述状态句
    ///   （`cityHasNoData` 例外：§13 表给「—」，返回空串由视图不渲染）。
    static func updateText(resolution: WidgetEntryResolution, timeText: String?) -> String {
        if let timeText {
            return resolution.status == .stale ? "更新于 \(timeText) · 已过期" : "更新于 \(timeText)"
        }
        guard let reason = resolution.emptyReason else { return "暂无数据" }
        guard reason != .cityHasNoData else { return "" }
        return conditionText(resolution: resolution)
    }

    // MARK: - 可操作提示

    /// 可操作提示行（§13 表 `hintText` 列）。
    ///
    /// 纪律：**只**在空态出现（有载荷 → nil，见 `WidgetEntryResolution` 不变式），
    /// 故渲染提示行不会改变数据路径的布局。
    /// Accessory 族（锁屏）空间小，可不渲染本行（§13 注）。
    /// - Parameter resolution: 收敛值。
    /// - Returns: 中文提示句；有载荷 → nil（无需提示）。
    static func hintText(resolution: WidgetEntryResolution) -> String? {
        guard let reason = resolution.emptyReason else { return nil }
        switch reason {
        case .noCity:
            return "点按小部件，选择要显示的城市"
        case .noCachedData:
            return "打开主 App 取数后自动显示"
        case .sharedContainerDown:
            return "请在主 App 中打开一次天气"
        case .fetchFailed:
            return "请检查网络后重试"
        case .cityHasNoData:
            return "换一个城市试试"
        }
    }
}

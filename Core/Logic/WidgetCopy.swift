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
//  ⚠️ **提示行的硬规则**（判据只有一条，动任何提示行前必须逐条过）：
//
//      凡是提示用户去做一个「在当前分发渠道上**无法**改变该状态」的动作，
//      就是错的文案 —— 自问「**照做，这个状态会不会变好？**」，答「不会」的必须改。
//
//  为什么本项目的这条规则格外要紧：本产品的分发渠道是**未签名侧载**，entitlements
//  不生效 → App Group 容器**永不可用** → 一切「去开主 App / 等主 App 写数据」类的
//  提示**都不可能生效**（主 App 写的是它自己的隔离容器，小组件永远读不到）。
//  已被这条规则判掉、**禁止写回**的历史文案：
//    - `.noCachedData`：原「打开主 App 取数后自动显示」
//    - `.sharedContainerDown`：原「请在主 App 中打开一次天气」
//
//  ⚠️ 这条规则的**适用边界**（别把它读成「永远不许提主 App」）：
//  它管的是「**状态是否由 App Group 决定**」—— 容器类状态（`.noCity` /
//  `.noCachedData` / `.sharedContainerDown`）在侧载上**永不可变**，故提主 App 无效。
//  **定位授权不属于此类**：定位**不是** entitlement 门禁能力（PRD §4.7.2），
//  「允许定位」是用户**真能改变**的状态 → 相关提示可以、也应该给出真实动作。
//  也就是说：判据始终是「照做会不会变好」，而不是「句子里有没有 App 两个字」。
//
//  逐条判定（改文案时逐行复核；结论写在此处，避免每次重新推理）：
//    - `.noCity`：**能**改善——长按→编辑→选一个具体城市是侧载上**唯一**能绕开容器的
//      路径（内置 34 城目录直接命中，见 `WidgetCityCatalog`）。
//      ⚠️「点按小部件」**不能**改善：点按只会打开主 App（未签名时容器仍读不到）。
//    - `.noCachedData`：**能自愈**——该态只出现在 `snapshot`（`allowNetwork == false`）
//      的瞬时 / 预览渲染，随后 timeline 的 L1 会自行取回 → 用户**无需动作**。
//    - `.sharedContainerDown`：**能自愈**，同上一行。且该态的前置条件是「城市**已**解析」
//      （无城市时走的是 `.noCity`），再让用户「选城市」等于让他重做刚做过的事，是错的建议。
//    - `.fetchFailed`：**能**改善——确为断网时检查网络有效；自动重试由 timeline 承担。
//    - `.cityHasNoData`：**能**改善——与 `.noCity` 同为选城路径。
//    - `.locationNotAuthorized`：**能**改善——定位授权**不受** entitlement 门禁
//      （是本产品侧载渠道上少数真能改变的状态之一）。故提示给「先允许定位」；
//      另加「再重新添加小组件」：小组件层级的授权问句是系统在**添加组件时**才给的，
//      用户一旦拒绝，只有重新添加才能让它再问一次（设置里没有「小组件」子项）。
//    - `.locationUnavailable`：**能**改善——该态是「已授权但本轮拿不到」（Apple：
//      系统只在组件可见后的一小段时间内提供定位），故**不**叫用户去授权（他已授权），
//      而给「改选具体城市」这条真实出路（内置目录路径不依赖容器）。
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
        case .locationNotAuthorized:
            return "定位未授权"
        case .locationUnavailable:
            return "位置暂时不可用"
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
    ///
    /// ⚠️ 每一行都必须满足文件头的**提示行硬规则**（「照做，状态会不会变好」）；
    /// 尤其**禁止**任何「去开主 App」类的措辞 —— 未签名侧载上它不可能生效。
    /// - Parameter resolution: 收敛值。
    /// - Returns: 中文提示句；有载荷 → nil（无需提示）。
    static func hintText(resolution: WidgetEntryResolution) -> String? {
        guard let reason = resolution.emptyReason else { return nil }
        switch reason {
        case .noCity:
            // 侧载上**唯一**能真正改变该状态的动作：编辑实例、选一个具体城市。
            // 「点按小部件」不算 —— 点按只打开主 App，容器仍不可用（见文件头硬规则）。
            return "长按小组件 → 编辑，选择城市"
        case .noCachedData, .sharedContainerDown:
            // 二者都只出现在快照路径（`allowNetwork == false`）的瞬时 / 预览渲染：
            // 城市已解析、只是这一路不联网 → **会自愈**，故如实说明并**不**索取任何
            // 用户动作（用户在侧载渠道上也做不到）。
            return "稍候将自动获取"
        case .fetchFailed:
            return "请检查网络后重试"
        case .cityHasNoData:
            return "换一个城市试试"
        case .locationNotAuthorized:
            // 未获资格（宿主 App 从未授权 / 用户拒绝了小组件的定位）→ 授权是
            // **真能**改变该状态的动作（定位不受 entitlement 门禁，与 App Group 不同）；
            // 「再重新添加小组件」是因为小组件那一次授权问句只在添加时出现，
            // 设置里没有「小组件」子项，故重新添加是让它再问一次的唯一入口。
            return "先允许定位，再重新添加小组件"
        case .locationUnavailable:
            // 已授权但本轮拿不到（Apple：系统只在组件可见后的一小段时间内提供定位）
            // → 用户**已**授权，再叫他去授权是错处方；改选具体城市是真实可行的出路。
            return "可改选具体城市试试"
        }
    }
}

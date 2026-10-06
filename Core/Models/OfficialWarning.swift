//
//  OfficialWarning.swift
//  Core / Models  [App + Widget 共用]
//
//  **官方气象预警**领域模型 + 取数状态四态（第六源 · 中国气象局 NMC）。
//
//  ── 为什么单独成模型、而不塞进 `WeatherSnapshot` ────────────────────────
//  预警**不属于** `WeatherFieldKey` 域，且它是**列表**（一个城市可同时有
//  多条、颜色各异），与 `AirQuality` / `MarineConditions` 的
//  「单值要素」形状不同。故：
//   · 不进 `WeatherSnapshot` / `SharedWeatherPayload` → **Widget 载荷契约零改动**；
//   · 不占用 `WeatherFieldKey` → 不参与逐字段降级与 EV-1
//     （详见 `SourceDescriptor` 里本源 `requiredFields` 诚实留空的注释）。
//
//  ── 语义纪律：四态**缺一不可**，且「取不到」绝不等于「没有」 ────────────
//  这是本文件存在的**全部理由**。若把「取数失败」画成「无预警」，
//  用户会在**真正有灾害预警时**看到一片平静 —— 那是**内容错误**，
//  且在灾害天气里代价极高。故：
//   · `.none`（真的没有预警）→ 整卡**隐藏**，不留空白；
//   · `.active`（有预警）→ 按颜色排序展示；
//   · `.stale`（**取数失败** 或 **数据超过 6 小时**）→ **显式说明**，
//     绝不静默消失（宁可显示"不知道"，也不谎报"安全"）；
//   · `.unavailable`（该源未启用）→ 显式说明被关闭。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 一条官方预警（已由 mapper 解析、归一）。
struct OfficialWarningItem: Equatable, Sendable, Identifiable {

    /// 稳定标识（取自 `alertid`；缺失时由 mapper 合成一个**确定性**兜底串）。
    ///
    /// ⚠️ 用 `alertid` 而非数组下标：列表顺序会随刷新变动，
    /// 用下标会让 SwiftUI 在刷新后**错认行**（把A 预警的内容渲染到 B 上）。
    var id: String

    /// 行政区划展示串（省 / 市 / 区；缺级自动跳过）。
    ///
    /// ⚠️ **可为 nil** = 标题没解析出行政区划（如省级直发预警）。
    /// nil ≠ 「没有地点」，故 UI 不得据此说"本地无预警"（见类型注释纪律）。
    var region: String?

    /// **市段**原文（如 `泉州市`、`大兴安岭地区`；解析失败 → nil）。
    ///
    /// 这是**按城市筛选的唯一比对对象**。刻意**不用**「整串包含」匹配：
    /// 全国有多个「鼓楼区」「城关区」，用包含匹配会让
    /// `鼓楼区` 同时命中 `福州市鼓楼区` 与 `南京市鼓楼区` ——
    /// 那会把**别处的预警**挂到本城市头上（内容错误，见 mapper 注释）。
    var cityName: String?

    /// **行政区划码**（`alertid` 前 6 位，如 `350604`；上游无 `alertid` → nil）。
    ///
    /// 实测该码为国标 GB/T 2260 行政区划码，且与标题解析结果**逐条一致**
    /// （8/8 交叉验证命中）。用作按城市筛选时的**第二道精确核**。
    /// ⚠️ **不参与展示**：它是我们对上游编码体系的**推断**，
    /// 万一上游哪天改编码，展示一个错的码比不展示更糟。
    var administrativeCode: String?

    /// 预警类型（如 `大风`、`大雾`、`森林火险`）。
    ///
    /// 标题解析失败时由 mapper 回落到 `NmcAlarmMapper.unknownKind`，
    /// **绝不**为空 —— 空会让卡片上出现半截句子。
    var kind: String

    /// 颜色等级（决定排序与配色）。
    ///
    /// 标题解析失败 → `.unspecified("")`（**排最后**，绝不当成蓝/低危）。
    var color: NmcAlarmColor

    /// 发布时间（由 `issuetime` 的墙钟串 + 调用方给的时区解析）。
    ///
    /// ⚠️ **可为 nil**：`issuetime` 缺失 / 格式未识别 / **调用方未注入时区**时
    /// 如实留nil，绝不拿 `now` 编一个发布时间（那会让"7 小时前发布的预警"
    /// 看起来刚刚发布）。
    var issuedAt: Date?

    /// 详情页地址（`url` 相对路径已拼成绝对；上游缺失 / 路径异常 → nil）。
    var detailURL: URL?

    /// 原始标题（**始终保留**：解析失败时它是唯一可展示的内容）。
    var rawTitle: String

    // MARK: - 第七源（weather.cn）补源字段
    //
    //  以下三个字段**全部可选、且默认 nil** —— 这是**刻意**的：
    //  ① 第六源（NMC）**根本提供不了**它们，故主源条目天然为 nil，
    //     UI 必须能区分"没有正文"与"有正文"（见下方各字段注释）；
    //  ② 给了默认值 → 既有用 `OfficialWarningItem(...)` 构造的
    //     **41 条既有测试一个字都不用改**（Swift 的成员构造器
    //     会给有默认值的参数补上默认值）。
    //
    //  ⚠️ 这三个字段**不参与** `OfficialWarningState` 的新鲜度判定
    //  （见 `freshnessWindow`）—— 它们是**补充信息**，不是时效信号。

    /// ⚠️ **防御指南正文**（第七源 `ISSUECONTENT`；NMC 源**恒无**）。
    ///
    /// 实测形态：`<机构><日期><时分>发布<类型><颜色>预警信号：<正文>
    /// （预警信息来源：国家预警信息发布中心）`，实测 5/5 **恒非空**
    /// （81~147 字符）。
    ///
    /// ⚠️ **可为 nil 有两种截然不同的成因，UI 不得混为一谈**：
    ///   · 该源未启用 / 取数失败 → nil（**"不知道"**）；
    ///   · 取到了但正文为空 → 也nil（上游偶发空串）。
    /// 两者都**不**等于"这条预警没有防御指南"。
    var defenseGuide: String? = nil

    /// ⚠️ **预警详情页有效期**（第七源 `RELIEVETIME`）。
    ///
    /// ⚠️⚠️ **语义未确，禁止当"已解除"展示**：实测 5 条里**4 条**
    /// 恰为 `ISSUETIME + 12h`（另 1 条为 `+4h6m` 精确同刻），
    /// 这个规律更像**有效期**而非"实际解除时刻"。
    /// 故字段名取 `detailExpiresAt`（有效期）而非 `relievedAt`（已解除），
    /// 且**不**参与任何"预警是否已失效"的判定。
    ///
    /// 实测 5/5 **恒非空**；NMC 源**恒无**。
    var detailExpiresAt: Date? = nil

    /// 预警颜色的**英文名**（第七源 `YJYC_EN`；实测 `Yellow` / `Blue`）。
    ///
    /// ⚠️ **只是 `color` 的旁注，不是替代**：`color` 仍是排序与配色的
    /// 唯一依据（`severityRank`），本字段仅供需要英文的场景使用。
    ///
    /// ⚠️ **刻意不取** `NAMEEN` 当英文标题：实测它是**汉语拼音**
    /// （`zhaosu yilihasake xinjiang` / `huian quanzhou fujian`），
    /// **不是英文** —— 拿它当"多语言标题"是把拼音冒充英文（内容错误）。
    /// 真正的英文标题在本通道**拿不到**（`YJTYPE_EN` 实测 5/5 恒空串）。
    var englishColorName: String? = nil
}

// MARK: - 四态

/// 官方预警取数状态（**四态**，`none` 与 `stale` 语义严格对立）。
enum OfficialWarningState: Equatable, Sendable {

    /// 无预警（**真的没有**，取数成功且列表为空）→ UI 整卡隐藏。
    case none

    /// 有预警（已按颜色排序：红 > 橙 > 黄 > 蓝）。
    case active([OfficialWarningItem])

    /// **数据不可信**：取数失败，或最新一条已超过 `freshnessWindow`。
    /// ⚠️ 携带 `reason` 是为了**如实区分**两种成因（用户看到的文案不同）。
    case stale(reason: StaleReason)

    /// 该源未启用（用户手动停用 / 未接入）→ UI 显式说明，不静默。
    case unavailable

    /// `.stale` 的成因（**两种必须能被区分**，故单列而非并成一串文案）。
    enum StaleReason: Equatable, Sendable {
        /// 取数失败（网络 / 解码 / 非 2xx）。
        case fetchFailed(String)
        /// 取到了数据，但**最新一条已过期**（超过新鲜度窗口）。
        case dataTooOld(latest: Date?, age: TimeInterval)
    }
}

extension OfficialWarningState {

    /// 新鲜度窗口：超过则判`.stale`。
    ///
    /// 6 小时的依据：预警是**逐条发布、逐条取消**的短时效信息，
    /// 超过半个工作日仍在屏上的预警大概率已失效；且实测当日全161 条
    /// `issuetime` **均在当日内**（无跨日残留）→ 6 小时窗口不会误伤真实数据。
    static let freshnessWindow: TimeInterval = 6 * 3600

    /// 由「取数结果 + 注入的 `now`」派生四态（**纯函数**，`now` 必须注入）。
    ///
    /// - Parameters:
    ///   - items: 取到的预警条目（可能为空 —— **空列表不等于取数成功**，
    ///     成功与否由调用方用「是否走到这里」表达：抛错即失败，见下）。
    ///   - latestIssuedAt: 最新一条的发布时间（无条目 → nil）。
    ///   - now: 判定时刻（**由调用方注入**，本函数不读系统时钟）。
    /// - Returns: 四态之一。
    ///
    /// ⚠️ **调用方契约（关键）**：只有**取数成功**（HTTP 2xx + 解码成功）才应
    /// 调用本函数；取数失败必须走 `.stale(.fetchFailed)`。
    /// 这条契约之所以重要：若失败也调用本函数并传空数组，
    /// 结果会是 `.none` —— 也就是**把"取不到"说成"没有预警"**，
    /// 那恰是本文件存在的理由所要消灭的缺陷。
    static func resolve(items: [OfficialWarningItem],
                         latestIssuedAt: Date?,
                         now: Date) -> OfficialWarningState {
        guard !items.isEmpty else { return .none }
        // ⚠️ 有条目但**全部没有发布时间**（`issuetime` 全缺）→ 无法判新鲜度。
        //   此时**不**谎报新鲜（也不谎报过期）：归 `.stale`，理由如实写"无法判定"。
        guard let latest = latestIssuedAt else {
            return .stale(reason: .dataTooOld(latest: nil, age: 0))
        }
        let age = now.timeIntervalSince(latest)
        // ⚠️ `age < 0`（发布时间晚于 now，多半是时区/时钟问题）**不**当过期处理，
        //   而是**如实归为无法判定的陈旧** —— 宁可说"不确定"，不谎报新鲜。
        guard age >= 0, age <= freshnessWindow else {
            return .stale(reason: .dataTooOld(latest: latest, age: age))
        }
        return .active(sorted(items))
    }

    /// 按颜色排序（红 > 橙 > 黄 > 蓝），**稳定**排序保证同色保持原有顺序。
    ///
    /// ⚠️ 排序键**只有颜色**一项：同色内按发布时间倒序（新的在前），
    /// 这样同色级里最新的那条一定排第一（用户最该先看到的那条）。
    static func sorted(_ items: [OfficialWarningItem]) -> [OfficialWarningItem] {
        // 用下标数组而非 `enumerated().sorted`：后者的闭包参数是对
        // `(offset: Int, element: T)` 元组的解构写法，Swift 对多语句闭包的
        // 元组解构推断较脆（这是本仓"照着抄但没核"最容易翻车的地方之一）。
        // 显式走下标 → 编译期形状一眼可辨。
        var indexed = items.indices.map { (index: $0, item: items[$0]) }

        indexed.sort { lhs, rhs in
            let lhsRank = lhs.item.color.severityRank
            let rhsRank = rhs.item.color.severityRank
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            // 同色：新的在前（nil 发布时间排最后 —— 缺数据不该抢占首位）。
            switch (lhs.item.issuedAt, rhs.item.issuedAt) {
            case let (left?, right?):
                if left != right { return left > right }
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            case (nil, nil):
                break
            }
            // 完全同序 → 保持原序（稳定），不引入随机性。
            return lhs.index < rhs.index
        }

        return indexed.map(\.item)
    }
}
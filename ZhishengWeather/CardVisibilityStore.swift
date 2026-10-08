//
//  CardVisibilityStore.swift
//  ZhishengWeather（主 App target）
//
//  **附加卡片**的显示 / 折叠 / 排序（2026-10-08 新增）。
//
//  ═══════════════════════════════════════════════════════════════════════
//  为什么需要它（用户诉求：「一长串下来有点麻烦缺少主次」）
//  ═══════════════════════════════════════════════════════════════════════
//  主屏现在**无条件挂载** 8 张附加卡（雷达 / UV / 预警 / 台风 / 卫星 /
//  河道流量 / 地震 / 和风）。它们当初**刻意绕过了** `HomeSection` 机制
//  ——理由是「不占用 HomeSection，避免影响老用户持久化顺序」。
//
//  🔴 **那个理由成立，但后果是用户无法关闭任何一张** —— 8 张卡强制显示，
//  首屏被拉得极长、完全没有主次之分。本文件补上这块**缺失的能力**。
//
//  ── 与 `HomeSection` 的分工（**两者并存，不互相取代**）────────────────
//  · `HomeSection` 管的是**可排序区块**（逐时 / 逐日 / 空气 / 月相 …），
//    它的顺序表本身就是「顺序 + 隐藏」的合体（`[String]` 子集排列）。
//  · 本文件管的是**附加卡片**——它们**不进入** `ForEach(orderedVisibleSections)`，
//    渲染位置在它之前（各自独立），所以需要**另一套**可见性状态。
//  · 两套状态**分别持久化、互不干扰**：动这张卡片不会打乱逐时/逐日的顺序。
//
//  ── 存储设计：**完全照抄 `HomeSection` 的成熟手法**（不另创框架）──────
//  · `[String]` 存 rawValue；读取时对未知标识**丢弃**、对缺失卡片**补齐回默认位**
//    → **新版本新增的卡片天然出现在默认位置**（不会出现"新卡隐身"）。
//  · store 是实例依赖，读写绑**同一个实例**（单测注入独立 suite 隔离）。
//  · 主 App 本地 `UserDefaults`，**不进共享容器**（小组件不感知这些卡片，
//    与 `HomeSection` 的 AC-A2-23 决策一致）。
//
//  ── 🔴 「折叠」与「隐藏」是两件不同的事，别混 ──────────────────────────
//  · **隐藏** = 这张卡不出现、不取数（用户在设置页关掉）。
//  · **折叠** = 卡还在、但只占一行摘要，**并且停止取数**
//    （折叠的语义是"我暂时不关心"，那就**不该继续耗流量与电量**）。
//    ⚠️ 这个取舍是刻意的：若折叠仍取数，用户为了省流量折叠反而更费。
//    代价是「折叠中」期间看不到该卡的最新值 —— 这是用户自己的选择。
//
//  本仓纪律：类型级 `@MainActor`；禁 `try!` / `fatalError` / `as!`。
//

import Foundation

// MARK: - 卡片标识

/// 主屏**附加卡片**的标识（顺序 = 默认展示顺序）。
///
/// ⚠️ **与 `HomeSection` 是两个独立枚举**，刻意不合并：
/// 二者的渲染路径不同（附加卡在 `ForEach` 之外各自独立挂载）、
/// 持久化键也不同，合并会让"卡片顺序"与"区块顺序"互相污染。
enum MainCard: String, CaseIterable, Identifiable, Sendable {
    case radar          // 降水雷达地图
    case uv             // UV 指数
    case warning        // 官方预警
    case typhoon        // 台风路径
    case satellite      // 卫星云图
    case flood          // 河道流量
    case earthquake     // 附近地震
    case qWeather       // 和风天气

    /// Identifiable（ForEach 用）。
    var id: String { rawValue }

    /// 面向用户的中文名（设置页列表用）。
    var displayName: String {
        switch self {
        case .radar: return "降水雷达"
        case .uv: return "紫外线指数"
        case .warning: return "官方预警"
        case .typhoon: return "台风路径"
        case .satellite: return "卫星云图"
        case .flood: return "河道流量"
        case .earthquake: return "附近地震"
        case .qWeather: return "和风天气"
        }
    }

    /// 一句话说明（设置页副标题；**如实**写它的数据来源与限制）。
    var detailText: String {
        switch self {
        case .radar: return "降水回波地图"
        case .uv: return "当前档位与防晒建议"
        case .warning: return "气象部门发布的预警信号"
        case .typhoon: return "台风路径与官方预报"
        case .satellite: return "风云卫星云图（默认关闭）"
        case .flood: return "河道流量（m³/s）"
        case .earthquake: return "附近有感地震"
        case .qWeather: return "和风天气逐日预报（需凭据）"
        }
    }

    /// 🔴 **是否允许被隐藏**（`false` = 用户不可关掉）。
    ///
    /// ⚠️ 目前**全部允许隐藏**：这 8 张都是"附加信息"，
    /// 而天气 App 的骨架（逐时 / 逐日 / 实况）在 `HomeSection` 那条线上，
    /// 不受本文件影响 → 全部关掉后用户仍能看到核心预报。
    var allowsHiding: Bool { true }

    /// UserDefaults 存储键（主 App 本地，**非共享容器**）。
    static let storageKey = "zs.weather.mainCards"
}

// MARK: - 顺序 / 隐藏 / 折叠 存储

/// 附加卡片的可见性管理（读写绑注入的 store）。
///
/// ⚠️ **三个正交维度**（各自独立持久化）：
/// · `order`   —— 展示顺序（`[String]`，补齐回默认位）
/// · `hidden`  —— 隐藏集合（不显示、不取数）
/// · `collapsed` —— 折叠集合（显示为一行摘要、**不取数**）
@MainActor
struct CardVisibilityStore {

    /// 读写共用的存储实例（构造时一次性选定，任何分支都不得绕开）。
    private let defaults: UserDefaults

    /// - Parameter defaults: 读写共用的存储（App 用 `.standard`；单测注入独立 suite）。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: 顺序

    /// 读取展示顺序（**全量**，含被隐藏/折叠的卡 —— 它们仍在顺序表里）。
    ///
    /// 读取失败 / 存了未知标识 / 数量对不上 → 回默认顺序
    /// （防旧数据把新卡裁掉，与 `HomeSection.current()` 同款防御）。
    func order() -> [MainCard] {
        guard let raw = defaults.stringArray(forKey: MainCard.storageKey) else {
            return MainCard.allCases
        }
        let saved = raw.compactMap(MainCard.init(rawValue:))
        // 去重（半写/重复写入的防御）
        var seen = Set<MainCard>()
        let deduped = saved.filter { seen.insert($0).inserted }
        // 补齐：新版本新增的卡追加到尾部（**新卡天然出现**，不会隐身）
        let missing = MainCard.allCases.filter { !deduped.contains($0) }
        let result = deduped + missing
        guard Set(result).count == MainCard.allCases.count else {
            return MainCard.allCases
        }
        return result
    }

    /// 保存展示顺序（全量，含已隐藏项）。
    func saveOrder(_ order: [MainCard]) {
        defaults.set(order.map(\.rawValue), forKey: MainCard.storageKey)
    }

    // MARK: 隐藏

    /// 读取隐藏集合。
    func hidden() -> Set<MainCard> {
        guard let raw = defaults.stringArray(forKey: key(".hidden")) else { return [] }
        return Set(raw.compactMap(MainCard.init(rawValue:)))
    }

    /// 保存隐藏集合。
    func saveHidden(_ hidden: Set<MainCard>) {
        // ⚠️ 只存**允许隐藏**的那些：不可隐藏的卡不落库，
        // 避免"曾经可隐藏"的陈旧数据把它错误地藏起来。
        let persistable = hidden.filter(\.allowsHiding)
        defaults.set(persistable.map(\.rawValue).sorted(), forKey: key(".hidden"))
    }

    /// 该卡当前是否**不显示**。
    ///
    /// 🔴 `allowsHiding == false` 的卡**永远返回 false**（用户关不掉）。
    func isHidden(_ card: MainCard) -> Bool {
        guard card.allowsHiding else { return false }
        return hidden().contains(card)
    }

    // MARK: 折叠

    /// 读取折叠集合。
    func collapsed() -> Set<MainCard> {
        guard let raw = defaults.stringArray(forKey: key(".collapsed")) else { return [] }
        return Set(raw.compactMap(MainCard.init(rawValue:)))
    }

    /// 保存折叠集合。
    func saveCollapsed(_ collapsed: Set<MainCard>) {
        defaults.set(collapsed.map(\.rawValue).sorted(), forKey: key(".collapsed"))
    }

    /// 该卡当前是否**折叠**。
    ///
    /// ⚠️ **隐藏的卡不算折叠**（它压根不显示，问它折不折没有意义）。
    func isCollapsed(_ card: MainCard) -> Bool {
        guard !isHidden(card) else { return false }
        return collapsed().contains(card)
    }

    // MARK: 变更（供 UI 直接调用）

    /// 切换隐藏状态；返回**变更后的**隐藏集合。
    @discardableResult
    func toggleHidden(_ card: MainCard) -> Set<MainCard> {
        guard card.allowsHiding else { return hidden() }
        var current = hidden()
        if current.contains(card) { current.remove(card) } else { current.insert(card) }
        saveHidden(current)
        // 🔴 隐藏后必须**同时清掉折叠态**：否则用户取消隐藏时会看到一张
        // 莫名其妙折起来的卡（状态自相矛盾）。
        var folded = collapsed()
        if folded.contains(card) {
            folded.remove(card)
            saveCollapsed(folded)
        }
        return current
    }

    /// 切换折叠状态；返回**变更后的**折叠集合。
    @discardableResult
    func toggleCollapsed(_ card: MainCard) -> Set<MainCard> {
        var current = collapsed()
        if current.contains(card) {
            current.remove(card)
        } else {
            current.insert(card)
            // 折叠一张**已隐藏**的卡没有意义 → 先取消隐藏，让用户看得见折叠效果。
            var hiddenNow = hidden()
            if hiddenNow.contains(card) {
                hiddenNow.remove(card)
                saveHidden(hiddenNow)
            }
        }
        saveCollapsed(current)
        return current
    }

    /// 上移一位（已在首位则不动）。
    func moveUp(_ card: MainCard) {
        var list = order()
        guard let index = list.firstIndex(of: card), index > 0 else { return }
        list.swapAt(index, index - 1)
        saveOrder(list)
    }

    /// 下移一位（已在末位则不动）。
    func moveDown(_ card: MainCard) {
        var list = order()
        guard let index = list.firstIndex(of: card), index < list.count - 1 else { return }
        list.swapAt(index, index + 1)
        saveOrder(list)
    }

    /// 「全部隐藏」：把**允许隐藏**的卡全藏起来。
    ///
    /// 🔴 不可隐藏的卡**不动**（本仓目前 8 张全部允许隐藏，
    /// 但保留这个分支是为了将来加"必选卡"时不必改逻辑）。
    func hideAll() {
        saveHidden(Set(MainCard.allCases.filter(\.allowsHiding)))
        // 全藏后折叠态无意义 → 一并清掉，避免下次"恢复"时状态自相矛盾。
        saveCollapsed([])
    }

    /// 恢复默认（清三个键）。
    func reset() {
        defaults.removeObject(forKey: MainCard.storageKey)
        defaults.removeObject(forKey: key(".hidden"))
        defaults.removeObject(forKey: key(".collapsed"))
    }

    // MARK: Private

    /// 子键拼接（集中一处，避免三处手拼字符串写错）。
    private func key(_ suffix: String) -> String {
        MainCard.storageKey + suffix
    }

    // MARK: - 生产默认实例（static便捷 API 的薄壳）

    /// 生产默认实例（App 本地标准 UserDefaults）。
    private static let shared = CardVisibilityStore()

    static func order() -> [MainCard] { shared.order() }
    static func hidden() -> Set<MainCard> { shared.hidden() }
    static func collapsed() -> Set<MainCard> { shared.collapsed() }
    static func isHidden(_ card: MainCard) -> Bool { shared.isHidden(card) }
    static func isCollapsed(_ card: MainCard) -> Bool { shared.isCollapsed(card) }
    static func toggleHidden(_ card: MainCard) { shared.toggleHidden(card) }
    static func toggleCollapsed(_ card: MainCard) { shared.toggleCollapsed(card) }
    static func moveUp(_ card: MainCard) { shared.moveUp(card) }
    static func moveDown(_ card: MainCard) { shared.moveDown(card) }
    static func hideAll() { shared.hideAll() }
    static func reset() { shared.reset() }
}
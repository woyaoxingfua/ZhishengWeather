//
//  CityDirectory.swift
//  Core / Logic  [App + Widget 共用]
//
//  F-B 多城市：城市目录的纯值逻辑。
//  所有列表操作的裁定规则集中于此，无 IO、无时钟（禁内部 Date()）、无 UIKit，
//  保证 AC-B15 的全部用例可纯单测。
//
//  纪律：`[City]` 数组顺序 = 展示顺序（D-2）；不变式：列表中至多一个
//  `isCurrentLocation == true` 的项；列表至少保留一个城市（AC-B11）。
//

import Foundation

/// 城市目录的纯值逻辑。
struct CityDirectory: Equatable, Sendable {

    /// 城市列表（数组顺序即展示顺序）。
    private(set) var cities: [City]
    /// 当前选中城市 id；nil 仅出现在空目录的瞬态，正常不变式下必有选中项。
    private(set) var selectedID: String?

    /// 内部构造（VM 从共享容器载入时用）。
    /// - Parameters:
    ///   - cities: 持久化的城市数组。
    ///   - selectedID: 持久化的选中 id；缺失或不指向列表内任何项时回退第一项。
    init(cities: [City], selectedID: String?) {
        self.cities = cities
        if let selectedID, cities.contains(where: { $0.id == selectedID }) {
            self.selectedID = selectedID
        } else {
            self.selectedID = cities.first?.id
        }
    }

    /// AC-B1 首次安装：[北京] + 选中北京。
    /// - Returns: 初始目录。
    static func initial() -> CityDirectory {
        CityDirectory(cities: [City.beijingDefault], selectedID: City.beijingDefault.id)
    }

    // MARK: - 定位 upsert

    /// 定位结果 upsert（AC-B2 / Q5 / AC-B3）。
    ///
    /// 规则（ARCH-FB §2.3 + CI 实测裁定修正，优先级从高到低）：
    /// 1. `location.isFallback == true`（定位被拒/失败/超时）→ 不新增"当前位置"，no-op；
    /// 2. **已有"当前位置"项 → 一律就地更新**（坐标与规范化 id 同步；选中 id 若指向
    ///    旧 id 则跟随）。即使新 id 与某手动城市重合，"当前位置"项也要跟随用户真实
    ///    坐标（Q5 的"视为同一城市"仅在**尚无**当前位置项时适用——否则用户移动到
    ///    已收藏的城市后，当前位置项会滞留旧坐标）；
    /// 3. 无"当前位置"项且规范化 id 命中已有城市 → 不新增、不改动（Q5）；
    /// 4. 无"当前位置"项且未命中 → 列表尾部新增一项"当前位置"。
    ///    不变式：列表中至多一个 `isCurrentLocation == true` 的项。
    ///
    /// - Parameter location: 定位结果。
    /// - Returns: 是否发生了变更（调用方据此决定是否落盘）。
    @discardableResult
    mutating func upsertCurrentLocation(_ location: LocationInfo) -> Bool {
        // 规则 1：定位被拒 / 失败 / 超时 → no-op。
        guard !location.isFallback else { return false }

        let newID = City.makeID(latitude: location.latitude, longitude: location.longitude)

        // 规则 2：已有"当前位置"项 → 一律就地更新（优先级最高，见 doc 注释）。
        if let index = cities.firstIndex(where: { $0.isCurrentLocation }) {
            // id 与坐标完全一致 → 无变化。
            guard cities[index].id != newID
                    || cities[index].latitude != location.latitude
                    || cities[index].longitude != location.longitude else { return false }
            let oldID = cities[index].id
            cities[index].id = newID
            cities[index].latitude = location.latitude
            cities[index].longitude = location.longitude
            if selectedID == oldID {
                selectedID = newID
            }
            return true
        }

        // 规则 3：无"当前位置"项，id 命中已有城市（手动城市重合，Q5）→ no-op。
        if cities.contains(where: { $0.id == newID }) {
            return false
        }

        // 规则 4：列表尾部新增（保持至多一项不变式）。
        let city = City(name: "当前位置",
                        latitude: location.latitude,
                        longitude: location.longitude,
                        isCurrentLocation: true)
        cities.append(city)
        return true
    }

    // MARK: - 增 / 切 / 删 / 排

    /// 添加搜索结果（AC-B5 / AC-B8）。
    /// id 已存在 → 不新增、直接切换选中，返回 false；否则追加 + 切换，返回 true。
    /// - Parameter city: 搜索结果构造的城市。
    /// - Returns: 是否发生了新增。
    @discardableResult
    mutating func add(_ city: City) -> Bool {
        if cities.contains(where: { $0.id == city.id }) {
            selectedID = city.id
            return false
        }
        cities.append(city)
        selectedID = city.id
        return true
    }

    /// 切换选中（AC-B12）。id 不存在 → no-op 返回 false。
    /// - Parameter id: 目标城市 id。
    /// - Returns: 是否切换成功。
    @discardableResult
    mutating func select(_ id: String) -> Bool {
        guard cities.contains(where: { $0.id == id }) else { return false }
        selectedID = id
        return true
    }

    /// 删除（AC-B10 / AC-B11）。
    /// 仅剩 1 项时 no-op 返回 false（"至少保留一个城市"）；
    /// 删除的是当前选中项 → 自动选中剩余**展示序第一项**（= 视觉首行）。
    /// - Parameter id: 要删除的城市 id。
    /// - Returns: 是否发生了删除。
    @discardableResult
    mutating func remove(_ id: String) -> Bool {
        guard cities.count > 1 else { return false }
        guard let index = cities.firstIndex(where: { $0.id == id }) else { return false }
        let wasSelected = (selectedID == id)
        cities.remove(at: index)
        // D-1 连带修复：自动选中取**展示序**首项。`displayCities` 是读取时派生，
        // 此处刚删完已反映最新顺序；用 `cities.first` 会在置顶时把 ✓ 跳到非顶行。
        if wasSelected, let first = displayCities.first {
            selectedID = first.id
        }
        return true
    }

    /// 拖动排序（AC-B9）；排序不影响选中项。
    /// - Parameters:
    ///   - fromOffsets: 被拖动行原索引集。
    ///   - toOffset: 目标偏移。
    mutating func move(fromOffsets: IndexSet, toOffset: Int) {
        cities.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    /// 展示序拖动（D-1 连带修复，A2-6 星标置顶后）。
    ///
    /// `offsets` / `toOffset` 均为 **`displayCities` 的展示序下标**（SwiftUI
    /// `.onMove` 给的正是展示序），故**不能**直接作用到存储序 `cities`
    /// ——置顶后二者错位，会拖动到错误城市。本方法先把展示序解析成 id 序列，
    /// 在 id 序列上执行与 `Array.move(fromOffsets:toOffset:)` 相同的移动，
    /// 再按新展示序重排 `cities`（对象原样复用，仅调整顺序）。
    ///
    /// 置顶稳定性由 `displayCities` 的"读取时排序"保证：收藏项恒被重新置顶，
    /// 故组内拖动生效、跨"收藏/非收藏"边界的拖动会被置顶规则回吸（与 pinned 语义一致）。
    /// `selectedID` 不受影响（AC-B9）。
    /// - Parameters:
    ///   - fromOffsets: 展示序中被拖动行的原索引集。
    ///   - toOffset: 展示序中的目标偏移。
    mutating func moveDisplay(fromOffsets: IndexSet, toOffset: Int) {
        let reorderedIDs = Self.moved(displayCities.map(\.id),
                                      fromOffsets: fromOffsets,
                                      toOffset: toOffset)
        // 按 id 重建：保证"数量守恒"不变式，避免重复 id 导致的静默丢项。
        var byID: [String: City] = [:]
        for city in cities { byID[city.id] = city }
        let reordered = reorderedIDs.compactMap { byID[$0] }
        guard reordered.count == cities.count else { return }
        cities = reordered
    }

    /// 在 id 序列上执行"移动"（复刻 `Array.move(fromOffsets:toOffset:)` 语义）。
    ///
    /// 纯函数（无 IO / 无时钟），供 `moveDisplay` 复用与单测：取 `offsets` 处元素，
    /// 整体移除后插入到 `toOffset`（插入点需扣减"被移除且位于其前者"的个数）。
    /// - Parameters:
    ///   - ids: 原 id 序列。
    ///   - offsets: 被移动元素的下标集（越界项忽略）。
    ///   - toOffset: 目标偏移。
    /// - Returns: 移动后的 id 序列；`offsets` 全越界时原样返回。
    static func moved(_ ids: [String], fromOffsets offsets: IndexSet, toOffset: Int) -> [String] {
        let validOffsets = offsets.filter { ids.indices.contains($0) }.sorted()
        guard !validOffsets.isEmpty else { return ids }

        let moving = validOffsets.map { ids[$0] }
        var remaining = ids
        for index in validOffsets.reversed() {
            remaining.remove(at: index)
        }
        let removedBeforeDestination = validOffsets.filter { $0 < toOffset }.count
        let insertIndex = min(max(toOffset - removedBeforeDestination, 0), remaining.count)
        remaining.insert(contentsOf: moving, at: insertIndex)
        return remaining
    }

    // MARK: - 收藏星标（A2-6）

    /// 展示列表：收藏项置顶、组内保持原相对顺序（读取时稳定排序）。
    ///
    /// 裁定（ARCH-A2P1 §1.4）：**不改写 `cities` 与 `selectedID`** ——
    /// 若在 add/move 后重排持久化数组，会与 AC-B9"排序不影响选中"及拖动
    /// 语义冲突（非收藏项被反复拉回）。持久化数组保持用户操作意图，置顶
    /// 仅是展示层派生视图；`selectedID` 永不因置顶而漂移。
    /// - Invariant: 稳定排序保证同收藏态内相对顺序 = `cities` 原序（AC-A2-18）。
    var displayCities: [City] {
        let favorites = cities.filter { $0.isFavorite == true }
        let rest = cities.filter { $0.isFavorite != true }
        return favorites + rest
    }

    /// 展示序下标 → 城市 id（D-1 修复：删除必须按**展示序**解析）。
    ///
    /// SwiftUI `.onDelete` 给出的 `IndexSet` 是 **`displayCities` 展示序下标**；
    /// 置顶后展示序与存储序错位，若直接以该 offset 索引存储序 `cities` 会删错城市
    /// （真实数据丢失缺陷的根因）。故解析职责**下沉到 Core**，作为纯函数供视图与
    /// 单测共用——视图不再私藏一份"手工模拟"的解析逻辑，测试也不再与实现共享
    /// 同一套错误假设（P-18 同源盲区纪律）。
    /// - Parameter offsets: 展示序下标集（越界项忽略、不崩；空集 → 空数组）。
    /// - Returns: 按 offsets **升序**命中的城市 id 列表。
    func cityIDs(atDisplayOffsets offsets: IndexSet) -> [String] {
        let display = displayCities
        var ids: [String] = []
        for offset in offsets.sorted() where display.indices.contains(offset) {
            ids.append(display[offset].id)
        }
        return ids
    }

    /// 切换星标（nil/false → true；true → false）。
    /// id 不存在 → no-op。**只改字段，不重排数组**（置顶由 displayCities 派生）。
    /// - Parameter id: 目标城市 id。
    mutating func toggleFavorite(_ id: String) {
        guard let index = cities.firstIndex(where: { $0.id == id }) else { return }
        cities[index].isFavorite = !(cities[index].isFavorite ?? false)
    }

    /// 当前选中城市；选中 id 失效（如数据损坏）时为 nil。
    var selectedCity: City? {
        guard let selectedID else { return nil }
        return cities.first { $0.id == selectedID }
    }
}

// MARK: - widget 侧只读载入（F-C）

extension CityDirectory {

    /// widget 进程只读载入（F-C 专用；主 App 的落盘语义不适用）。
    ///
    /// 三态响应（与 App 侧 E-1 同源，差异仅在"不落盘"——widget 只读、
    /// 避免与主 App 写竞态；missing 的落盘职责在主 App，AC-B1 已保证）：
    ///   - `.loaded`  → `CityDirectory(cities:selectedID:)`（坏 selectedID 由既有规则回退第一项）；
    ///   - `.missing` → 内存 `initial()`，**不落盘**；
    ///   - `.corrupt` → 内存 `initial()`，**不落盘**（字节保全纪律在 widget 侧同样禁止覆盖写）。
    ///
    /// - Parameter store: 共享容器读取器（widget 进程内只使用其读路径）。
    /// - Returns: 可用于解析的目录（永不为空列表，见 `CityDirectory` 不变式）。
    static func loadReadOnly(from store: AppGroupStore) -> CityDirectory {
        switch store.loadCities() {
        case .loaded(let cities):
            return CityDirectory(cities: cities, selectedID: store.selectedCityID)
        case .missing, .corrupt:
            return CityDirectory.initial()
        }
    }
}

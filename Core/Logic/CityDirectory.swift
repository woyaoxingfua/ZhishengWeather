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
    /// 规则（ARCH-FB §2.3，写死避免实现歧义）：
    /// 1. `location.isFallback == true`（定位被拒/失败/超时）→ 不新增"当前位置"，no-op；
    /// 2. 规范化 id 命中已有城市：
    ///    - 该项是"当前位置"项 → 就地更新其坐标（名称保持"当前位置"，id 命中即不变）；
    ///    - 该项是手动城市 → 不新增、不改动（Q5：坐标几乎重合，视为同一城市）；
    /// 3. 未命中：已有"当前位置"项 → 就地更新该项（坐标与 id 同步更新，
    ///    选中 id 若指向旧 id 则跟随）；否则列表尾部新增一项"当前位置"。
    ///    不变式：列表中至多一个 `isCurrentLocation == true` 的项。
    ///
    /// - Parameter location: 定位结果。
    /// - Returns: 是否发生了变更（调用方据此决定是否落盘）。
    @discardableResult
    mutating func upsertCurrentLocation(_ location: LocationInfo) -> Bool {
        // 规则 1：定位被拒 / 失败 / 超时 → no-op。
        guard !location.isFallback else { return false }

        let newID = City.makeID(latitude: location.latitude, longitude: location.longitude)

        // 规则 2：规范化 id 命中已有城市。
        if let index = cities.firstIndex(where: { $0.id == newID }) {
            if cities[index].isCurrentLocation {
                // 命中"当前位置"项：id 相同，仅坐标可能有亚精度漂移，就地刷新。
                guard cities[index].latitude != location.latitude
                        || cities[index].longitude != location.longitude else { return false }
                cities[index].latitude = location.latitude
                cities[index].longitude = location.longitude
                return true
            } else {
                // 命中手动城市：视为同一城市，不新增、不改动。
                return false
            }
        }

        // 规则 3：未命中。
        if let index = cities.firstIndex(where: { $0.isCurrentLocation }) {
            // 已有"当前位置"项：就地更新（坐标变了 → 规范化 id 变）。
            let oldID = cities[index].id
            cities[index].id = newID
            cities[index].latitude = location.latitude
            cities[index].longitude = location.longitude
            if selectedID == oldID {
                selectedID = newID
            }
            return true
        } else {
            // 无"当前位置"项：列表尾部新增（保持至多一项不变式）。
            let city = City(name: "当前位置",
                            latitude: location.latitude,
                            longitude: location.longitude,
                            isCurrentLocation: true)
            cities.append(city)
            return true
        }
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
    /// 删除的是当前选中项 → 自动选中剩余列表第一项。
    /// - Parameter id: 要删除的城市 id。
    /// - Returns: 是否发生了删除。
    @discardableResult
    mutating func remove(_ id: String) -> Bool {
        guard cities.count > 1 else { return false }
        guard let index = cities.firstIndex(where: { $0.id == id }) else { return false }
        let wasSelected = (selectedID == id)
        cities.remove(at: index)
        if wasSelected, let first = cities.first {
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

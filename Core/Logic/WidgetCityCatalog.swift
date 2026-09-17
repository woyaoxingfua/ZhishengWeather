//
//  WidgetCityCatalog.swift
//  Core / Logic  [App + Widget 共用]
//
//  城市阶梯的**纯**逻辑：原始容器读取 / 合并去重保序 / 按 id 查找 / 坐标回填。
//
//  为什么放 Core（P-18 同源盲区纪律）：`ZhishengWeatherTests` 只依赖主 App target，
//  **Widget target 不进测试包** —— 逻辑若写在 Widget 里，CI 无法单测。故 Core 只处理
//  `City` 层的纯函数，Widget 侧只做 1 行 `map(WidgetCityEntity.make)`。
//
//  关键裁定（ARCH §7.1，优先级**写死**，实现与测试不得各自解读 —— P-13 纪律）：
//      0. selection.id == followAppID  → `.followApp` 分支（哨兵判定集中在
//         `WidgetCityResolver.mode(forEntityID:)`，本文件不重复判字符串）；
//      1. id 命中**容器**目录           → 容器城市（全量元数据）；
//      2. 否则命中**内置**目录          → 内置城市（全量元数据，C1 新增能力）；
//      3. 否则 id 可解析为**规范坐标**  → 坐标回填 City（用配置携带的 name）；
//      4. 否则                          → `.needsConfiguration`（不冒充、不默认）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 小组件实例的配置选择（`WidgetCityEntity` 在 Core 侧的值型投影）。
///
/// 与 `WidgetCityEntity` 同形（id / name / subtitle），但**不含** AppIntents 依赖，
/// 故可被 Core 纯逻辑与单测直接使用（Widget target 侧只做一层 `init`）。
struct WidgetCitySelection: Equatable, Sendable {

    /// `City.id`（"%.2f,%.2f"）或哨兵 id。
    var id: String
    /// 展示名（坐标回填时用于重建城市名）。
    var name: String
    /// 去歧义副标题（"中国 · 浙江"）；nil 安全（AC-B20：缺省绝不渲染 "null"）。
    var subtitle: String?
}

/// 共享容器的**原始**城市视图（供城市阶梯解析）。
///
/// ⚠️ 关键语义（幽灵北京修复点）：`cities` 必须是**原始容器**内容 ——
/// `.missing` / `.corrupt` → `[]`，**绝不**经 `CityDirectory.initial()` 兜底。
/// 旧实现用 `CityDirectory.loadReadOnly`（三态兜底 = `initial()` = 北京）导致
/// 未签名产物上小组件把「防御性北京」当成用户城市静默显示。
struct WidgetContainerSnapshot: Equatable, Sendable {

    /// 容器城市（原始读取；缺失 / 损坏 → 空数组）。
    var cities: [City]
    /// 容器里持久化的选中 id；无键 / 损坏 → nil。
    var selectedID: String?
    /// `AppGroupStore.isSharedContainerAvailable` 的探测结果（**注入**，不在此直接调用）。
    var containerAvailable: Bool
}

/// 城市目录的纯函数集合（无 IO、无时钟、无状态）。
enum WidgetCityCatalog {

    // MARK: - 原始容器读取（不注入 initial()）

    /// 容器城市读取结果 → **原始**城市数组。
    ///
    /// 三态映射（与 `CityDirectory.loadReadOnly` 的差别就在此处，是**修复**而非裁剪）：
    ///   - `.loaded(cities)` → `cities`（原样、保持顺序）；
    ///   - `.missing`        → `[]`（从未写入 ≠ 用户选了北京）；
    ///   - `.corrupt`        → `[]`（坏 JSON ≠ 用户选了北京；且**绝不**覆盖写，字节保全）。
    ///
    /// - Parameter result: `AppGroupStore.loadCities()` 的三态结果。
    /// - Returns: 原始容器城市（可为空数组，调用方不得再套任何默认城市）。
    static func rawCities(from result: AppGroupStore.CitiesLoadResult) -> [City] {
        switch result {
        case .loaded(let cities):
            return cities
        case .missing, .corrupt:
            return []
        }
    }

    // MARK: - 合并 / 查找 / 回填

    /// 配置界面可见城市：容器在前（保持 App 内顺序），内置中**未出现**的追加在末。
    ///
    /// 去重以 `City.id` 为准（含容器内部重复的防御性去重），**先出现者胜**
    /// （容器元数据优先，见 `city(forID:container:builtIn:)`）。
    /// - Parameters:
    ///   - container: 原始容器城市。
    ///   - builtIn: 内置城市目录（C1）。
    /// - Returns: 去重保序后的可见城市（可能为空数组，由调用方前置哨兵）。
    static func visibleCities(container: [City], builtIn: [City]) -> [City] {
        var seen: Set<String> = []
        var visible: [City] = []
        for city in container + builtIn {
            guard seen.insert(city.id).inserted else { continue }
            visible.append(city)
        }
        return visible
    }

    /// 按 id 查找城市：**容器优先**（全量元数据），其次内置；都未命中 → nil。
    /// - Parameters:
    ///   - id: 规范化坐标 id 或哨兵 id（哨兵由调用方先行短路）。
    ///   - container: 原始容器城市。
    ///   - builtIn: 内置城市目录。
    /// - Returns: 命中城市；未命中 → nil。
    static func city(forID id: String, container: [City], builtIn: [City]) -> City? {
        if let hit = container.first(where: { $0.id == id }) {
            return hit
        }
        return builtIn.first(where: { $0.id == id })
    }

    /// 规范坐标 id → City（"%.2f,%.2f" **往返稳定**才认）。
    ///
    /// 用途：升级前已配置的旧实例 / C2 搜索选中的城市，其 id 已携带坐标，
    /// 但未必在容器或内置目录里（如用户搜到的任意城市）—— 用坐标 + 配置携带的
    /// 展示名重建城市，直接进入 L1 取数（ARCH §10-3「合法坐标 id 但不在任何目录」）。
    ///
    /// 严格性：解析出的坐标**重新生成**规范 id 必须与入参**逐字相同**，
    /// 否则视为非规范串（如 `"1,2"` / `"30.250,120.170"`）；越界坐标同样拒绝。
    /// 这样「怪值」不会变成伪造坐标去取数（诚实纪律）。
    /// - Parameters:
    ///   - id: 疑似规范坐标 id。
    ///   - name: 重建城市的展示名（调用方提供；`entities(for:)` 场景下退化为 id 串）。
    /// - Returns: 回填城市；非规范坐标 → nil。
    static func city(fromCanonicalID id: String, name: String) -> City? {
        let parts = id.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let latitude = Double(parts[0]),
              let longitude = Double(parts[1]),
              (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude) else {
            return nil
        }
        guard City.makeID(latitude: latitude, longitude: longitude) == id else {
            return nil
        }
        return City(name: name,
                    latitude: latitude,
                    longitude: longitude,
                    isCurrentLocation: false)
    }
}

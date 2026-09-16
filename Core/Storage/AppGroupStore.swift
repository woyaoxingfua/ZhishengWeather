//
//  AppGroupStore.swift
//  Core / Storage  [App + Widget 共用]
//
//  App Group 共享容器的读写封装。
//
//  设计要点：
//  - `UserDefaults` **可注入**：生产传 App Group suite，测试传临时 suite
//    （测试 bundle 无 App Group 权限，硬编码真 group id 会静默失败）。
//  - 所有失败路径以 `do/catch` 或可选值兜底，绝不 `!` 强制解包 / `try!`。
//

import Foundation

/// App Group 共享容器的读写器。
final class AppGroupStore {

    // MARK: - 错误类型

    /// 共享容器写入相关错误。
    enum AppGroupStoreError: Error, Equatable {
        /// 写入后立即读回校验不一致（共享容器异常 / entitlement 缺失导致回落私有容器等）。
        case writeVerificationMismatch(key: String)
    }

    /// 主天气载荷的读取结果（本轮新增：**读失败必须可见**，不再静默成 nil）。
    ///
    /// 与 `CitiesLoadResult` 同款三分支语义，但用于**主载荷**：
    ///   - `missing`：键不存在（从未写入 / 已被清除）；
    ///   - `corrupt`：键存在但解码失败（坏 JSON / 形状不符 / 半截写入）
    ///     —— 必须让调用方（尤其 Widget）能区分「没有数据」与「数据坏了」；
    ///   - `loaded`：解码成功。
    enum PayloadLoadResult: Equatable, Sendable {
        case missing
        case corrupt
        case loaded(SharedWeatherPayload)
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// 初始化。
    /// - Parameter defaults: 可注入的 `UserDefaults`；默认使用 App Group suite。
    ///   若 `UserDefaults(suiteName:)` 返回 nil（如缺少 entitlement），
    ///   则回落到 `.standard`，保证不崩溃。
    init(defaults: UserDefaults? = UserDefaults(suiteName: AppGroup.identifier)) {
        self.defaults = defaults ?? .standard
    }

    /// 写入完整载荷（写后回读校验，不一致抛错防静默失败）。
    func save(_ payload: SharedWeatherPayload) throws {
        let data = try encoder.encode(payload)
        defaults.set(data, forKey: AppGroup.payloadKey)
        try verifyWritten(data, forKey: AppGroup.payloadKey)
    }

    /// 写后回读校验（防静默失败）：立即读回刚写入的 Data，不一致则抛错。
    private func verifyWritten(_ expected: Data, forKey key: String) throws {
        guard let read = defaults.data(forKey: key), read == expected else {
            WeatherLog.storage.error("写后回读校验失败 key=\(key, privacy: .public)")
            throw AppGroupStoreError.writeVerificationMismatch(key: key)
        }
    }

    /// 以给定时间戳写入快照。
    func save(snapshot: WeatherSnapshot, at date: Date) throws {
        try save(SharedWeatherPayload(snapshot: snapshot, updatedAt: date))
    }

    /// 读取完整载荷；不存在或解码失败时返回 nil。
    ///
    /// 便利封装（既有调用方零改动）；需要区分「缺失 / 损坏」的调用方请用
    /// `loadResult()`（Widget 正需要这个区分来如实标注）。
    func load() -> SharedWeatherPayload? {
        switch loadResult() {
        case .loaded(let payload):
            return payload
        case .missing, .corrupt:
            return nil
        }
    }

    /// 读取主载荷并**区分三态**（missing / corrupt / loaded）。
    ///
    /// 与 `load()` 的差别只在「可区分」：坏 JSON 不再只打印一句就返回 nil，
    /// 而是回 `.corrupt` 并以 `os.Logger` 记录，使 Widget 能显示
    /// 「共享数据不可用」而不是渲染空白（本轮要求 5/6）。
    /// - Returns: 三态读取结果。
    func loadResult() -> PayloadLoadResult {
        guard let data = defaults.data(forKey: AppGroup.payloadKey) else { return .missing }
        do {
            return .loaded(try decoder.decode(SharedWeatherPayload.self, from: data))
        } catch {
            WeatherLog.storage.error(
                "读取主载荷失败（键存在但解码失败）：\(String(describing: error), privacy: .public)")
            return .corrupt
        }
    }

    /// 仅读取快照。
    func loadSnapshot() -> WeatherSnapshot? {
        load()?.snapshot
    }

    /// 最近一次写入时间；无数据时为 nil。
    var updatedAt: Date? {
        load()?.updatedAt
    }

    /// 清除共享容器中的天气载荷。
    func clear() {
        defaults.removeObject(forKey: AppGroup.payloadKey)
    }

    // MARK: - 城市目录持久化（F-B，D-1：独立双 key，SharedWeatherPayload 零改动）

    /// 城市列表读取结果（F-B 核验裁定：「键缺失」与「坏 JSON」必须可区分）。
    ///
    /// - `missing`：键不存在（首次启动 / 未初始化）——调用方应初始化默认目录
    ///   并**立即落盘**（写入的是合法初始结构，不违反"不清数据"纪律）；
    /// - `corrupt`：键存在但 JSON 损坏（半截写入 / 形状不匹配）——调用方只允许
    ///   在内存中回退初始目录，**绝不覆盖写**（字节保全 / 防误伤 / 纪律一致）；
    /// - `loaded`：解码成功，直接采用。
    enum CitiesLoadResult: Equatable, Sendable {
        case missing
        case corrupt
        case loaded([City])
    }

    /// 读取城市列表，并区分「键缺失」与「JSON 损坏」。
    ///
    /// 本方法**绝不**清空 / 改写既有数据（PRD §3.4：不要因解码失败而清空用户数据）；
    /// 如何响应由调用方依据 `CitiesLoadResult` 决定，store 侧只读、只打日志。
    /// - Returns: 可区分的读取结果（见 `CitiesLoadResult` 文档）。
    func loadCities() -> CitiesLoadResult {
        guard let data = defaults.data(forKey: AppGroup.citiesKey) else { return .missing }
        do {
            return .loaded(try decoder.decode([City].self, from: data))
        } catch {
            print("[AppGroupStore] 解码城市列表失败（保留原字节，不覆盖写）：\(error)")
            return .corrupt
        }
    }

    /// 写入城市列表（仅用户显式操作时调用，PRD §3.4 时机约束）。
    /// 写后回读校验，不一致抛错防静默失败。
    /// - Parameter cities: 城市数组（数组顺序即展示顺序，D-2）。
    func saveCities(_ cities: [City]) throws {
        let data = try encoder.encode(cities)
        defaults.set(data, forKey: AppGroup.citiesKey)
        try verifyWritten(data, forKey: AppGroup.citiesKey)
    }

    /// 当前选中城市 id；无键时为 nil（未初始化语义）。
    ///
    /// 坏值处理（F-B 核验裁定，与坏 JSON 同一纪律）：若存有 id 但在目录中找不到
    /// 匹配项，`CityDirectory(cities:selectedID:)` 会回退到第一项，**无需也不应**
    /// 落盘覆盖 —— 保留原字节，等待用户下一次显式操作时自然修正。
    var selectedCityID: String? {
        defaults.string(forKey: AppGroup.selectedCityIDKey)
    }

    /// 写入选中城市 id（仅用户显式操作时调用）。
    /// 写后回读校验，不一致抛错防静默失败。
    /// - Parameter id: 目标城市 id。
    func saveSelectedCityID(_ id: String) throws {
        defaults.set(id, forKey: AppGroup.selectedCityIDKey)
        guard defaults.string(forKey: AppGroup.selectedCityIDKey) == id else {
            throw AppGroupStoreError.writeVerificationMismatch(key: AppGroup.selectedCityIDKey)
        }
    }

    // MARK: - 强刷待办标志（Widget 刷新按钮 → 主 App）

    /// 标记「有待处理的强刷请求」。由 Widget 刷新按钮 intent（主 App 进程内执行）
    /// 写入，独立 key，不污染 payload / cities 既有数据。
    func markPendingForceRefresh() {
        defaults.set(true, forKey: AppGroup.pendingForceRefreshKey)
    }

    /// 读取并清除强刷待办标志（read-then-clear，幂等：多次调用仅首个返回 true）。
    /// 主 App 在 scenePhase 回到前台时调用；返回 true 即触发强制刷新。
    /// - Returns: 是否存在待处理强刷请求。
    @discardableResult
    func consumePendingForceRefresh() -> Bool {
        let pending = defaults.bool(forKey: AppGroup.pendingForceRefreshKey)
        guard pending else { return false }
        defaults.removeObject(forKey: AppGroup.pendingForceRefreshKey)
        return true
    }

    // MARK: - 共享容器可用性探测

    /// App Group 共享容器是否真的可用。
    ///
    /// 注意：App Group entitlement 缺失时 `UserDefaults(suiteName:)` **依然返回非 nil 对象**，
    /// 只是落在本进程私有容器中 —— 表现为「主 App 能取数，小组件永远暂无数据」且零报错。
    /// 故此处用 `containerURL(forSecurityApplicationGroupIdentifier:)` 显式探测。
    static var isSharedContainerAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) != nil
    }
}

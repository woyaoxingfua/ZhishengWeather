//
//  NavigationPathStore.swift
//  ZhishengWeather（主 App target）
//
//  导航栈（`NavigationPath`）的落盘 / 恢复层。
//
//  ── 它要解决的问题 ────────────────────────────────────────────────────
//  `ContentView.navigation` 原本是 `@State`，而 `@State` 挂在**视图实例**上。
//  App 被切后台后若被系统回收、或视图因故重建，该状态即丢失 → 用户回到 App
//  时看到的是**首页**，而不是上次离开时所在的那一层。
//  本层把导航栈落盘，使「切后台再回来」能回到真实的返回路径。
//
//  ── 为什么用 App 本地 `UserDefaults.standard`（绝不经 App Group）──────
//  本项目走未签名 / 免签重签分发，entitlements 不生效 → 共享容器恒不可用
//  （判据见 `AppGroupStore.isSharedContainerAvailable`），写进共享容器等于
//  什么都没写。且小组件本就不感知这些页面，无需与之共享。
//
//  ── API 事实（Apple 官方文档核对，非推断）─────────────────────────────
//  · `NavigationPath` **本身只 `Conforms To: Equatable`，它不是 `Codable`**。
//    序列化能力挂在 `var codable: NavigationPath.CodableRepresentation?` 上，
//    而 `NavigationPath.CodableRepresentation` 才是 `Decodable/Encodable/Equatable`。
//    → 故本层用的是 `path.codable` + `NavigationPath.init(_:)` 这一对，
//    **不是** `JSONEncoder().encode(path)`（后者根本不存在，会编译失败）。
//  · `path.codable` 在**任一类型擦除元素不满足 `Codable`** 时为 `nil`
//    （文档原文），故本层对 nil 单列一条如实分支，绝不静默假装存成功。
//  · 部署目标 iOS 17.0 ≥ 该 API 的 iOS 16.0，无需 `@available`。
//
//  ── 纪律 ──────────────────────────────────────────────────────────────
//  - **单 key 单值**：整条导航栈是**一个** `CodableRepresentation`、落在**一个**
//    key 上（同 `AppDiagnosticsStore` 的形状）。
//  - **绝不抛错**：存 / 取全在 `do/catch` 内，任何失败都降级为**空路径**
//    （= 首页）并照常显示，绝不让 App 崩在启动路径上。
//  - **如实降级、不静默假装**：`.empty`（查过了，确实没有）与
//    `.unavailable`（取到了字节但用不了）是**两套不同的结论**，各有各的
//    记录方式；后者还会写进 `AppDiagnosticsStore`，用户可在设置页读到。
//  - **可注入**：`defaults` 可注入，单测用独立 suite，不污染 standard。
//

import Foundation
import SwiftUI

/// 导航栈落盘 / 恢复层（App 本地 `UserDefaults.standard`，绝不经 App Group）。
///
/// 全部调用点都在主 actor（`ContentView` 是 `@MainActor` 类型），故本类型标
/// `@MainActor`；`UserDefaults` 自身的读写即线程安全，无需额外同步。
@MainActor
final class NavigationPathStore {

    // MARK: - 常量

    /// 持久化键（**全仓唯一一个**导航栈键；整条栈是单值 `CodableRepresentation`）。
    ///
    /// 带 `.v1` 后缀：将来若换存储形状（如改存 `[CityRoute]` 数组），
    /// 换 key 而不是复用旧 key —— 旧字节会被自然遗弃，不会被新读取路径误解。
    static let key: String = "zs.weather.navigation.path.v1"

    /// 生产共享实例（App 本地 `.standard`）。
    static let shared: NavigationPathStore = NavigationPathStore()

    // MARK: - 依赖

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter defaults: 存储（App 用 `.standard`；
    ///   单测注入 `UserDefaults(suiteName:)` 以隔离）。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    // MARK: - 结论形状

    /// 一次恢复的**结论**。
    ///
    /// 🔴 `.empty` 与 `.unavailable` 是**两件不同的事**，绝不可合并成一句
    /// 「没有记录」：前者是「查过了，确实没有」（首次启动 / 上次就在首页，
    /// 属**正常初始态**），后者是「取到了字节但用不了」（结构变了 / 枚举
    /// 变了 / 字节损坏，属**降级**）。把降级说成「没有」，会让一个真实故障
    /// 在用户眼里消失。
    enum Outcome: Equatable {

        /// 成功恢复，栈深为 `depth`（`depth == 0` 是合法的空栈 = 首页）。
        case restored(depth: Int)

        /// **查过了，确实没有存过**（首次启动，或上次离开时就在首页）。
        ///
        /// 这**不是**失败：空路径本身就是合法的初始态。
        case empty

        /// **取到了字节但解不出来**（结构变了 / 枚举变了 / 字节损坏 /
        /// 栈内含不可编码元素）—— 已降级到空路径，如实上报而非静默假装。
        case unavailable(reason: String)
    }

    /// 恢复结果：路径本体 + 这次恢复到底是什么结论。
    struct RestoreResult: Equatable {

        /// 恢复出的路径（任何失败路径下都是**空路径**，即首页 —— 绝不崩）。
        let path: NavigationPath

        /// 本次恢复的结论（供调用方如实上报 / 单测断言）。
        let outcome: Outcome
    }

    // MARK: - 写（落盘）

    /// 把当前导航栈落盘（**永不抛出**：写失败只打印，不影响天气取数与导航）。
    ///
    /// - Parameter path: 当前 `NavigationPath`。
    func save(_ path: NavigationPath) {
        // 空路径 = 用户当前就在首页 → **不留字节**。
        // 副作用是好的：它让 `.empty` 保持「从未离开过首页 / 从未存过」的
        // 单一含义，不会与「存过一个空栈」混成同一件事。
        guard !path.isEmpty else {
            defaults.removeObject(forKey: Self.key)
            return
        }

        // ⚠️ `codable` 在**任一元素不满足 Codable** 时为 nil（Apple 文档原文）。
        // 本仓 `CityRoute` 已 `Codable`，正常不会走到这里；但真走到了就必须
        // **如实上报**（写进诊断记录），绝不能默默跳过让用户以为存成功了。
        guard let representation: NavigationPath.CodableRepresentation = path.codable else {
            let note = "导航栈含不可编码元素，本次未落盘（depth=\(path.count)）"
            print("[NavigationPathStore] \(note)")
            AppDiagnosticsStore.shared.record(source: .navigationPathRestore,
                                             succeeded: false,
                                             target: "save",
                                             message: note)
            return
        }

        do {
            let data: Data = try encoder.encode(representation)
            defaults.set(data, forKey: Self.key)
        } catch {
            // 写失败**保留既有字节**（同 `AppDiagnosticsStore` 纪律：
            // 坏数据留给下一次成功写入自然修正，绝不因一次失败清空历史状态）。
            let note = "写入导航栈失败（已忽略，保留原字节）：\(error)"
            print("[NavigationPathStore] \(note)")
            AppDiagnosticsStore.shared.record(source: .navigationPathRestore,
                                             succeeded: false,
                                             target: "save",
                                             message: note)
        }
    }

    // MARK: - 读（恢复）

    /// 恢复导航栈（**永不抛出**：任何失败路径都返回空路径 = 首页）。
    ///
    /// - Returns: 路径本体 + 本次恢复的结论（`.empty` / `.unavailable` 分开）。
    func restore() -> RestoreResult {
        // 「查过了，确实没有」—— 首次启动的正常路径，不是故障。
        guard let data: Data = defaults.data(forKey: Self.key) else {
            return RestoreResult(path: NavigationPath(), outcome: .empty)
        }

        do {
            let representation: NavigationPath.CodableRepresentation =
                try decoder.decode(NavigationPath.CodableRepresentation.self, from: data)
            let path = NavigationPath(representation)
            return RestoreResult(path: path, outcome: .restored(depth: path.count))
        } catch {
            // 「取到了字节但用不了」—— 这是**降级**，必须与 `.empty` 区分开，
            // 并落到诊断记录里，让它可被用户与后续排查看见。
            let note = "读取导航栈失败（已降级到首页，保留原字节）：\(error)"
            print("[NavigationPathStore] \(note)")
            AppDiagnosticsStore.shared.record(source: .navigationPathRestore,
                                             succeeded: false,
                                             target: "restore",
                                             message: note)
            return RestoreResult(path: NavigationPath(),
                                 outcome: .unavailable(reason: note))
        }
    }
}
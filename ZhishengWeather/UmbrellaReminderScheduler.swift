//
//  UmbrellaReminderScheduler.swift
//  ZhishengWeather（主 App target）
//
//  雨伞提醒的调度出口：把 Core 决策（UmbrellaReminderEngine.Decision）落为
//  本地通知（UNUserNotificationCenter）。
//
//  纪律：
//  - **副作用隔离**：调度通知绝不触碰 WeatherViewModel.state（失败仅打印），
//    与 loadAir / loadEnsemble 的失败隔离纪律同源。
//  - **固定标识 + 替换**：所有雨伞提醒共用一个 identifier；新的快照到来时
//    直接以同 id 重排（UNNotificationRequest 同 id 覆盖旧的 pending 通知），
//    无需手动 removePendingNotificationRequests——系统按 id 去重替换。
//  - **权限懒请求**：只在第一次真正要提醒时才申请通知权限（绝不启动即弹窗）；
//    拒绝后本会话不再重复申请（UserDefaults 记忆）。
//  - **可注入**：协议化 UNUserNotificationCenter 的能力面，单测注入 Spy；
//    单测不触碰真实系统通知中心。
//
//  iOS 17 AppIntents 注：本文件与 AppIntents 无关；见 AppShortcuts.swift。
//

import Foundation
import UserNotifications

/// 通知中心能力面（单测注入点；生产实现转发 UNUserNotificationCenter）。
protocol NotificationCentering: Sendable {
    /// 申请通知权限（alert + sound；badge 不需要）。
    /// - Returns: 是否获得授权。
    func requestAuthorization() async -> Bool

    /// 以固定 id 添加（同 id 旧 pending 请求会被系统替换）。
    /// - Parameters:
    ///   - identifier: 固定通知标识。
    ///   - title: 通知标题。
    ///   - body: 通知正文。
    ///   - trigger: 触发器（nil = 立即；本特性恒传时间间隔触发器）。
    func add(identifier: String, title: String, body: String,
             trigger: UNNotificationTrigger?) async throws
}

/// 生产实现：转发 UNUserNotificationCenter（不可用场景返回失败，由调用方吞掉）。
struct SystemNotificationCenter: NotificationCentering {

    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func add(identifier: String, title: String, body: String,
             trigger: UNNotificationTrigger?) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: identifier,
                                            content: content,
                                            trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)
    }
}

/// 雨伞提醒调度器（@MainActor：与 VM 同一隔离域，读写偏好无竞态）。
@MainActor
final class UmbrellaReminderScheduler {

    // MARK: - 常量（单一真源）

    /// 固定通知标识：同 id 重复 add 时系统自动替换 pending 通知（新快照顶掉旧提醒）。
    static let notificationIdentifier = "com.zhisheng.weather.umbrella"

    /// App 本地 UserDefaults 键：雨伞提醒开关（默认开；**不进 App Group**，与外观偏好同款纪律）。
    static let enabledDefaultsKey = "zs.weather.umbrellaReminderEnabled"

    /// App 本地 UserDefaults 键：通知权限曾被拒绝（本会话内不再重复弹窗申请）。
    private static let permissionDeniedDefaultsKey = "zs.weather.umbrellaPermissionDenied"

    // MARK: - 依赖

    /// 通知中心（生产 = SystemNotificationCenter；单测 = Spy）。
    private let center: NotificationCentering

    /// App 本地偏好（可注入，默认 standard；单测用独立 suite 隔离）。
    private let defaults: UserDefaults

    // MARK: - 初始化

    /// - Parameters:
    ///   - center: 通知中心实现。
    ///   - defaults: App 本地偏好存储（**非** App Group 共享容器）。
    init(center: NotificationCentering = SystemNotificationCenter(),
         defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
    }

    // MARK: - 开关（设置页读写）

    /// 雨伞提醒是否开启（缺省 → 开；与 AppearancePreference 的归一化纪律一致）。
    var isEnabled: Bool {
        if defaults.object(forKey: Self.enabledDefaultsKey) == nil { return true }
        return defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    /// 写入开关。
    /// - Parameter enabled: 目标状态。
    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
    }

    // MARK: - 调度（VM 主刷新成功后调用；副作用，绝不抛错、绝不触碰 state）

    /// 依决策调度（或替换）雨伞提醒。
    ///
    /// 全路径**静默降级**：开关关 / 无决策 / 权限拒绝 / 添加失败 → 仅打印，
    /// 绝不向调用方抛错（失败隔离纪律：通知是副产物，不是主链路）。
    ///
    /// - Parameters:
    ///   - decision: Core 决策结果（shouldFire == false 时为 no-op）。
    ///   - onsetDelay: 距降水起始的秒数（触发器用；由调用方以注入的 now 计算）。
    func scheduleIfDecided(_ decision: UmbrellaReminderEngine.Decision,
                           onsetDelay: TimeInterval) async {
        guard decision.shouldFire else { return }
        guard isEnabled else {
            print("[UmbrellaReminder] 提醒已关闭，跳过调度")
            return
        }
        // 权限懒请求：第一次真正要提醒时才申请；曾被拒 → 本会话静默跳过。
        if defaults.bool(forKey: Self.permissionDeniedDefaultsKey) {
            print("[UmbrellaReminder] 通知权限曾被拒绝，本会话不再申请")
            return
        }
        let granted = await center.requestAuthorization()
        if !granted {
            defaults.set(true, forKey: Self.permissionDeniedDefaultsKey)
            print("[UmbrellaReminder] 通知权限被拒，跳过调度")
            return
        }
        // 触发时刻 = max(1s, delay)（UNTimeIntervalNotificationTrigger 要求 > 0）。
        let delay = max(onsetDelay, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        do {
            // 固定 id：同一 id 的 pending 请求会被自动替换（新快照顶掉旧提醒）。
            try await center.add(identifier: Self.notificationIdentifier,
                                 title: decision.title,
                                 body: decision.body,
                                 trigger: trigger)
        } catch {
            print("[UmbrellaReminder] 通知调度失败（静默降级）：\(error.localizedDescription)")
        }
    }
}

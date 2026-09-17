//
//  WidgetLocationService.swift
//  ZhishengWeatherWidget（Widget target）
//
//  P1-C7「当前位置」的 `CLLocationManager` 外壳：**只负责取一次点**，
//  **不做任何判定**（「拿到 / 没资格 / 拿不到」怎么落到 UI，全部由 Core 的
//  `WidgetLocationResolver.outcome(fix:)` + `WidgetCopy` 决定）。
//
//  为什么放在 Widget target 而不是 `Core/`：Core 的纪律是**只 import Foundation**
//  （且 `qa-static-check.sh` SC-12 会盯 Core 的 import 集合），而取点必须依赖
//  `CoreLocation`。故「判定留在 Core（CI 可单测）+ 机制留在 Widget（CI 不可测）」，
//  与既有 `WeatherProviding` / `WidgetWeatherService` 的分层**同构**。
//
//  ⚠️ 使用范围（AC-C8 / AC-C17 / F-C-8）：本类型**只允许**被 timeline 路径
//  （`WeatherProvider`）使用。配置解析路径（`WidgetCityIntent.swift` 的任何方法
//  及其传递依赖）**禁止**引用它 —— 那等于让配置界面发起定位，违反「配置解析
//  纯本地读」这条硬禁令（且配置界面的执行预算极低，定位必然超时）。
//
//  ⚠️ 三条 Apple 约束（本文件的实现依据）：
//   1. 小组件扩展**不能**弹授权窗 —— 故本文件**绝不**调用
//      `requestWhenInUseAuthorization()`。授权的取得路径是：
//      宿主 App 请求「使用期间」授权（已有）→ 系统在**用户添加小组件时**额外
//      问一次「是否允许该小组件使用位置」。
//   2. 资格判据唯一：`CLLocationManager.isAuthorizedForWidgetUpdates`。
//      它为 false 时**立即**返回 `.notAuthorized` —— 不请求、不等待、不消耗预算。
//   3. 系统只在小组件可见后的一小段时间内提供定位更新；不可见一段时间后
//      就不再提供 → 「已授权但本轮拿不到」是**常态之一**，不是异常。
//
//  ⚠️ 绝不回落：本文件**没有**任何「失败 → 用北京（或任何城市）兜底」的分支。
//  主 App 的 `LocationProvider` 在拒绝 / 失败时回落 `.beijing`，那是**主 App 的
//  策略**；小组件照搬即等于把防御性默认城市冒充成用户的城市归属（幽灵北京）。
//
//  线程约定（与主 App `LocationProvider` 同源做法）：`CLLocationManager` 的委托
//  回调投递到**创建它的那个线程**的 run loop，故创建、`requestLocation()` 与全部
//  状态读写一律在**主线程**（`Task { @MainActor in ... }`）完成。
//  ⚠️ 本类型**有意不**整体标 `@MainActor`：那样它的 `init()` 也会变成主线程
//  隔离，而 `WeatherProvider(...)` 的**默认参数**是在非隔离上下文求值的
//  （`ZhishengWidgetBundle.swift` 里 `provider: WeatherProvider()`），
//  整体 @MainActor 会直接在那里编译失败。
//

import CoreLocation
import Foundation

/// 小组件侧定位取点器（每轮 timeline 至多一次取点，且有硬上限）。
final class WidgetLocationService: NSObject, WidgetLocationProviding, CLLocationManagerDelegate {

    // MARK: - 主线程专属状态

    /// 定位管理器；**懒建**（首次使用时在主线程创建 → 回调走主 run loop）。
    private var manager: CLLocationManager?
    /// 悬挂中的等待者（`withCheckedContinuation` 提供）。
    private var continuation: CheckedContinuation<WidgetLocationOutcome, Never>?
    /// 超时兜底任务（取消感知）。
    private var timeoutTask: Task<Void, Never>?

    // MARK: - WidgetLocationProviding

    /// 取一次当前位置；**有界**（超时 → `.unavailable`），**不抛错**。
    ///
    /// 三条出口（与 `WidgetLocationOutcome` 一一对应）：
    ///   · 未获资格 → 立即 `.notAuthorized`（零 IO、零等待）；
    ///   · 取到坐标 → `.located(latitude:longitude:)`；
    ///   · 超时 / 失败 → `.unavailable`。
    /// - Parameter budget: 硬上限（秒）；由 Core 的 `WidgetLocationResolver.fixBudget` 给出。
    /// - Returns: 本轮取点结果。
    func currentLocationFix(budget: TimeInterval) async -> WidgetLocationOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<WidgetLocationOutcome, Never>) in
            Task { @MainActor in
                let manager = self.manager ?? self.makeManager()

                // 资格判定（Apple 唯一判据）：没资格就**不**请求定位 —— 请求了也只会
                // 立刻 didFailWithError，白白消耗预算；更不会（也不能）弹授权窗。
                guard manager.isAuthorizedForWidgetUpdates else {
                    continuation.resume(returning: .notAuthorized)
                    return
                }

                self.continuation = continuation
                self.startTimeout(after: budget)
                manager.requestLocation()
            }
        }
    }

    // MARK: - 主线程实现

    /// 创建定位管理器（**主线程**）：保证委托回调走主 run loop。
    @MainActor
    private func makeManager() -> CLLocationManager {
        let manager = CLLocationManager()
        manager.delegate = self
        // 天气用千米级精度足够（省电、更快返回）；不需要导航级精度。
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        self.manager = manager
        return manager
    }

    /// 启动超时兜底（先取消上一个，防残留任务误触发）。
    @MainActor
    private func startTimeout(after seconds: TimeInterval) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // 超时 = 本轮拿不到定位（系统可能已停止为该组件提供更新）→ 如实收敛。
            self?.finish(.unavailable)
        }
    }

    /// 收敛本轮结果：取消超时、恢复等待者（**幂等**：只恢复一次）。
    @MainActor
    private func finish(_ outcome: WidgetLocationOutcome) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: outcome)
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let latitude = last.coordinate.latitude
        let longitude = last.coordinate.longitude
        Task { @MainActor in
            self.finish(.located(latitude: latitude, longitude: longitude))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 不细分错误类型：对小组件而言「没资格」已在上游拦掉，这里只剩
        // 「有资格但本轮拿不到」一种语义（超时 / 定位服务不可用 / 被拒）。
        Task { @MainActor in
            self.finish(.unavailable)
        }
    }
}

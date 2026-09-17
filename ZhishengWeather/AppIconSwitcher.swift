//
//  AppIconSwitcher.swift
//  ZhishengWeather（主 App target）
//
//  应用图标切换的**副作用出口**：把 Core 的纯映射（IconChoice → 备用图标名）
//  落为系统调用 `UIApplication.setAlternateIconName(_:completionHandler:)`。
//
//  纪律（对齐 UmbrellaReminderScheduler 的副作用隔离）：
//  - **仅 App target**：import UIKit 在 Widget 扩展不可用，本文件只挂主 App；
//    Core 的 IconChoice / IconChoicePreference 保持无 UIKit（纯逻辑、可共享单测）。
//  - **可注入**：系统调用面协议化（AlternateIconSetting），单测注入 Spy，
//    绝不在单测里触碰真实 UIApplication。
//  - **错误不静默**：completion 的 error 必须上抛为故障域短句（FaultDomain
//    风格），由设置页展示；iOS 系统自带「已更改图标」确认弹窗，**本侧绝不
//    再补一个自定义弹窗**（避免双重提示）。
//  - **持久化语义**：偏好写入发生在系统调用**成功之后**——若系统切换失败
//    而偏好已写，重启后 UI 显示的档位与实际图标将不一致。默认档无系统调用
//    （alternateIconName 已是 nil 时 setAlternateIconName(nil) 也会触发系统
//    弹窗），同值幂等短路。
//  - **store 单一**：注入的 `defaults` 同时构造出读写共用的
//    `IconChoicePreference`，`currentChoice()` 与 `apply(_:)` 走同一个 store。
//    读注入、写 standard 会让单测隔离变假（且生产因两边都是 standard 而
//    看不出来），属「注入缝只用了半条」，见 CI run 35206149080。
//

import UIKit

/// 备用图标设置能力面（单测注入点；生产实现转发 UIApplication）。
protocol AlternateIconSetting: Sendable {

    /// 调用系统切换备用图标（语义与 `UIApplication.setAlternateIconName` 一致：
    /// `nil` = 切回默认图标）。
    /// - Parameters:
    ///   - name: 备用图标资源名；`nil` = 默认图标。
    ///   - completion: 系统回调（主队列；失败携带 error）。
    func setAlternateIconName(_ name: String?, completion: @escaping (Error?) -> Void)
}

/// 生产实现：转发 UIApplication（App target 专属）。
struct SystemAlternateIconSetter: AlternateIconSetting {

    func setAlternateIconName(_ name: String?, completion: @escaping (Error?) -> Void) {
        UIApplication.shared.setAlternateIconName(name, completionHandler: completion)
    }
}

/// 应用图标切换器（@MainActor：与设置页同一隔离域，读写偏好无竞态）。
@MainActor
final class AppIconSwitcher {

    // MARK: - 依赖

    /// 系统调用实现（生产 = SystemAlternateIconSetter；单测 = Spy）。
    private let setter: AlternateIconSetting

    /// 档位持久化（**绑定注入的 store**，读与写同一实例）。
    ///
    /// 纪律：绝不在这里直接 `UserDefaults.standard`——那会让注入的
    /// `defaults` 只影响读、写仍落 standard，注入缝只剩半条。
    private let preference: IconChoicePreference

    // MARK: - 初始化

    /// - Parameters:
    ///   - setter: 系统调用实现。
    ///   - defaults: 档位存储（**非** App Group 共享容器）；同一个实例
    ///     同时用于读与写。
    init(setter: AlternateIconSetting = SystemAlternateIconSetter(),
         defaults: UserDefaults = .standard) {
        self.setter = setter
        self.preference = IconChoicePreference(defaults: defaults)
    }

    // MARK: - 读取（设置页初值）

    /// 当前档位（读系统 `alternateIconName` 与本地偏好的并集判定）：
    /// 系统记录优先（它是设备上的事实），系统无备用图标时回退本地偏好，
    /// 再回退默认档。三者未知串一律归一化为默认档。
    ///
    /// - Returns: 当前生效档位。
    func currentChoice() -> IconChoice {
        let systemName = UIApplication.shared.alternateIconName
        if let systemName {
            return IconChoice.resolve(alternateName: systemName)
        }
        return preference.choice()
    }

    // MARK: - 切换（设置页写入）

    /// 切换到目标档位。
    ///
    /// 流程：同档幂等短路 → 备用档调用系统 API → **成功后**写偏好 →
    /// 失败上抛故障域短句（不写偏好，保持 UI 与设备事实一致）。
    /// 默认档 = 调 `setAlternateIconName(nil)` 切回（若系统已是默认则已短路）。
    ///
    /// iOS 系统在切换成功时会弹自己的确认框，本侧**不再**补提示。
    ///
    /// - Parameter choice: 目标档位。
    /// - Returns: 成功为 nil；失败为面向用户的中文短句（FaultDomain 风格）。
    @discardableResult
    func apply(_ choice: IconChoice) async -> String? {
        // 幂等短路：目标档即当前档（以设备事实为准）时不做任何事，
        // 避免对默认档重复调用触发系统弹窗。
        guard choice != currentChoice() else { return nil }

        let targetName = choice.alternateIconName
        let error: Error? = await withCheckedContinuation { continuation in
            setter.setAlternateIconName(targetName) { error in
                continuation.resume(returning: error)
            }
        }
        if let error {
            // 错误绝不静默：收敛为短句给设置页展示（文案单一真源在本方法）。
            print("[AppIconSwitcher] 换图标失败：\(error.localizedDescription)")
            return "换图标失败（\(error.localizedDescription)），请稍后重试"
        }
        // 系统成功后才落偏好，保证「UI 显示档位 == 设备实际图标」。
        // 走注入实例（与 currentChoice 同一个 store），否则幂等判定下次会
        // 读到陈旧值，判成「当前档 ≠ 目标档」而重复触发系统切换弹窗。
        preference.setChoice(choice)
        return nil
    }
}

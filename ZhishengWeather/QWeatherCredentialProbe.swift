//
//  QWeatherCredentialProbe.swift
//  ZhishengWeather（主 App target）
//
//  设置页「测试连接」的**真实探测**（不碰任何存根）。
//
//  ══════════════════════════════════════════════════════════════════════════
//  为什么单独一个文件（而不是塞进 SettingsView）
//  ══════════════════════════════════════════════════════════════════════════
//  ① **类型检查超时**：ViewBuilder 里内联长字符串拼接 + 数值转换是本仓
//    已记录的编译期卡死来源（见 ContentView 的 static let 纪律）。
//    探测结果 → 文案的映射放在纯类型里，编译压力与 View 解耦。
//  ② **可测**：纯类型可单测，不必拉起整个 SwiftUI 视图树。
//
//  ── 🔴 铁律：`.noData` 与 `.unavailable` **必须是两套文案** ──────────────
//  · `.noData`     = **查过了，上游确实没给数据**（请求成功、HTTP 2xx、
//                    解码成功，只是 `days` 为空）→ 用户该等/换城市，
//                    **不该**去查网络或凭据。
//  · `.unavailable` = **取不到**（网络失败 / 超时 / 401 / 403 / 解码失败）
//                    → 用户该查网络或凭据。
//  把两者混成一句「失败」是本仓明令禁止的静默行为（见 `QWeatherCardModel`
//  文件头「`.noData` 与 `.unavailable` 必须分开」）。
//
//  ── 为什么探测走**真实链路**而不是「只校验格式」 ───────────────────────
//  格式合法 ≠ 能取到数据：Host 填错、凭据无该端点权限（403）、
//  凭据类型选错（JWT vs API KEY）**只有真发一次请求才会暴露**。
//  故这里构造**真** `QWeatherService` 并**真**发一次逐日请求。
//  ⚠️ 只探逐日端点：逐时是独立失败域（权限可能只覆盖其一），
//   但逐日足以回答「凭据能不能用」这个设置页要回答的问题。
//
//  本文件纪律：禁 try! / fatalError / as!；**不含任何真实凭据**。
//

import Foundation

/// 「测试连接」的结论（**穷举所有可能，不设兜底 case**）。
enum QWeatherProbeOutcome: Equatable {

    /// 字段没填齐（**根本没发请求**）—— 附缺失说明。
    case notConfigured(String)

    /// 字段格式非法（**根本没发请求**）—— 附第一条错误。
    case invalid(String)

    /// 🔴 请求成功且**取到数据**（附天数）。
    case success(dayCount: Int)

    /// 🔴 **查过了，上游没给数据**（HTTP 2xx + 解码成功，但 `days` 为空）。
    ///
    /// ⚠️ 这是**合法响应**，不是故障。绝不与 `.unavailable` 混文案。
    case noData

    /// 🔴 **取不到**（网络 / 超时 / 401 / 403 / 解码失败）—— 附真实原因。
    case unavailable(String)

    /// 是否已发出真实请求（用于 UI 决定要不要提示「未配置」而非「失败」）。
    var didRequest: Bool {
        switch self {
        case .notConfigured, .invalid:
            return false
        case .success, .noData, .unavailable:
            return true
        }
    }
}

// MARK: - 文案（单一真源）

extension QWeatherProbeOutcome {

    /// 结论 → 用户可读说明（**展示层只渲染，不判定**）。
    var summary: String {
        switch self {
        case .notConfigured(let detail):
            return "未发起请求：" + detail
        case .invalid(let detail):
            return "未发起请求：" + detail
        case .success(let dayCount):
            return "连接成功：取到 " + String(dayCount) + " 天逐日预报。"
        case .noData:
            // 🔴 刻意**不说**「失败」：请求确实成功了。
            return "连接成功，但上游未返回任何一天（响应合法、内容为空）。"
                + "这不是网络问题，也不是凭据问题—— 换个城市或稍后再试即可。"
        case .unavailable(let detail):
            return "取不到数据：" + detail
        }
    }

    /// 结论 → 展示色（`.success` 绿、`.noData` 橙、其余红/次级）。
    ///
    /// ⚠️ `.noData` 用**橙**而非红：它是「合法但无内容」，
    ///   与「取不到」在语义上不同档（配色也应随之不同）。
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - 探测器

/// 凭据探测器（**发真实请求**，无任何存根）。
enum QWeatherCredentialProbe {

    /// 探测用的逐日天数（**1 天**即可回答「能不能用」，省流量）。
    ///
    /// ⚠️ 必须在 `QWeatherEndpoint.daysRange`（1–10）内，
    ///   否则拼装收敛为 `badURL`，用户会看到与凭据无关的报错。
    static let probeDays = 1

    /// 执行探测。
    ///
    /// 🔴 **本方法整体标 `@MainActor`**（P-06b 纪律，2026-10-10）：
    ///   `SourceCredentialStore` 是 `@MainActor` 类型，故它的 `static func`
    ///   `validate` / `makeCredentials` **同样是 MainActor 隔离的**。
    ///   本类型是**普通 enum**（非隔离），若不在方法上标 `@MainActor`，
    ///   在里面调那两个方法就会挂 CI 编译
    ///   （`expression is 'async' but is not marked with 'await'` 一类）。
    ///   标了之后调用点（本页 `probeConnection()`，本身已在 `@MainActor`）无需 `await`。
    ///   ⚠️ 标 `@MainActor` **不会**把网络请求搬到主线程上执行 ——
    ///   `await service.fetchDaily(...)` 期间主actor 是可让出的。
    ///
    /// - Parameters:
    ///   - fields: 待探测的凭据字段（**页面上正在编辑的那份**，不要求已保存）。
    ///   - latitude: 探测坐标纬度（由调用方给定，本类型不建城市来源）。
    ///   - longitude: 探测坐标经度。
    /// - Returns: 结论（**任何路径都不静默成功**）。
    @MainActor
    static func probe(fields: SourceCredentialFields,
                      latitude: Double,
                      longitude: Double) async -> QWeatherProbeOutcome {
        // ① 先做本地校验：**不发无意义的请求**。
        let validation = SourceCredentialStore.validate(fields)
        guard validation.isValid else {
            return .invalid(validation.firstError ?? "凭据字段不合法。")
        }
        // ② 本地齐备性（校验只管格式，这里管「四项都在」）。
        guard let credentials = SourceCredentialStore.makeCredentials(from: fields) else {
            return .notConfigured("需要 API Host / 项目 ID / 凭据 ID / Ed25519 私钥四项。")
        }

        // ③ 真发一次请求。`now` 由 App 侧显式传（Core 禁 `Date()`，SC-11）。
        let service = QWeatherService(now: { Date() }, credentials: credentials)
        do {
            let forecast = try await service.fetchDaily(latitude: latitude,
                                                         longitude: longitude,
                                                         days: probeDays)
            // 🔴 「成功但空」与「成功且有数据」必须分开（见文件头铁律）。
            return forecast.isEffectivelyEmpty
                ? .noData
                : .success(dayCount: forecast.days.count)
        } catch {
            // 复用卡片模型既有的错误渲染（401/403 有专门人话说明）——
            // **单一真源**，不在这里另写一套措辞。
            return .unavailable(QWeatherCardModel.describe(error))
        }
    }
}

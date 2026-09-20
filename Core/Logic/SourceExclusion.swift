//
//  SourceExclusion.swift
//  Core / Logic  [App + Widget 共用]
//
//  摘除原因（ExclusionReason）：运行中自动判定的 EV-1 / EV-3 本轮落地，
//  其余 EV 原因先占位、不实现（理由 UI 文案已支持，阈值待后续）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 源级摘除原因（语义 = 「源级」，非「卡片级」，与 SourceState 区分）。
enum ExclusionReason: Equatable, Sendable {

    /// EV-1：必填字段连续缺失（consecutive = 连续次数）。
    case missingFields(consecutive: Int)
    /// EV-3：认证失败（401/403，本会话内摘除）。
    case auth
    /// EV-3：限流（429，冷却期内不请求，until = 冷却截止时刻）。
    case rateLimit(until: Date)

    // 以下为登记占位（本轮不实现，reason 枚举先占位，UI 文案已支持）。
    case timeoutRate       // EV-2
    case coverage          // EV-4
    case quotaExhausted    // EV-7
    case semanticsInvalid  // EV-6
    /// 用户手动停用（D-C5 / AC-C13）。
    case userDisabled

    /// 判据代号（用于诊断与测试断言）。
    var code: String {
        switch self {
        case .missingFields: return "EV-1"
        case .auth, .rateLimit: return "EV-3"
        case .timeoutRate: return "EV-2"
        case .coverage: return "EV-4"
        case .quotaExhausted: return "EV-7"
        case .semanticsInvalid: return "EV-6"
        case .userDisabled: return "手动"
        }
    }

    /// 设置页展示文案（单一真源）。
    var displayText: String {
        switch self {
        case .missingFields(let n):
            return "已摘除 · 原因 EV-1（连续 \(n) 次缺字段）"
        case .auth:
            return "已摘除 · 原因 EV-3（认证失败 401/403）"
        case .rateLimit:
            return "已摘除 · 原因 EV-3（限流 429 冷却中）"
        case .timeoutRate:
            return "已摘除 · 原因 EV-2（超时率过高）"
        case .coverage:
            return "已摘除 · 原因 EV-4（地域缺口）"
        case .quotaExhausted:
            return "已摘除 · 原因 EV-7（额度耗尽）"
        case .semanticsInvalid:
            return "已摘除 · 原因 EV-6（语义不成立）"
        case .userDisabled:
            return "已停用（手动）"
        }
    }
}

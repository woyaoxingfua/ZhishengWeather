//
//  FaultDomain.swift
//  Core / Logic  [App + Widget 共用]
//
//  故障域分类（本轮「可诊断性」修复的核心，**纯逻辑**、可纯单测）。
//
//  背景（docs/handover/review-2026-09-16-run37.md §3）：
//  五条独立数据链路（forecast / air / ensemble / minutely-15 / climate）
//  此前全部收敛为一句泛化文案，真机出事时只能靠截图问人。本文件把
//  「到底谁的问题」抽成纯枚举 + 纯映射链：
//
//      Error / LocationOutcome  ──classify──▶  FaultDomain  ──message──▶  中文短句
//
//  纪律：
//  - 纯逻辑：仅 import Foundation；无 IO、无时钟、无 UIKit、无内部 Date()；
//  - 文案**单一真源**：所有面向用户的错误句子都必须从 `message(for:)` 出，
//    视图 / VM 禁止再各自拼错误文案（否则又是一处同源盲区）；
//  - **解码失败必须携带 codingPath**（run37 事故的直接修复）：只打
//    `localizedDescription` 会把「哪个字段解不出来」这条唯一线索丢掉。
//

import Foundation

/// 故障域：错误按「问题出在哪一环」分类。
///
/// 与 `WeatherError` 的关系：`WeatherError` 是**取数层**的收敛错误类型（含传输细节），
/// `FaultDomain` 是**面向用户的分类**（去细节、可给处置建议）。两者分离的好处是
/// 文案与判定可以脱离网络层纯单测，也便于后续接错误上报。
enum FaultDomain: Equatable, Sendable {

    /// 网络不可达（无网络 / DNS 失败 / 连接被拒）。
    case networkUnreachable(String)
    /// 请求超时。
    case timeout(String)
    /// HTTP 4xx：多半是**我们的请求**有问题（坐标 / 参数）。
    case httpClient(Int)
    /// HTTP 5xx：**服务端**的问题。
    case httpServer(Int)
    /// 解码失败：响应结构与预期不符；`path` 为 `DecodingError.codingPath`
    /// 的点号串（可能为空），`debugDescription` 为上游给的调试描述。
    case decodeFailure(path: String, debugDescription: String)
    /// 请求的城市**无可用数据**（响应结构性为空）。
    case dataMissing(String)
    /// 定位权限被拒绝 / 受限。
    case locationDenied
    /// App Group 共享容器故障（读 / 写失败或容器不可用）。
    case appGroup(String)
    /// URL 拼装失败。
    case badURL
    /// 其它未归类错误。
    case unknown(String)
}

// MARK: - 分类（纯函数）

extension FaultDomain {

    /// 任意错误 → 故障域（纯函数，无副作用）。
    ///
    /// 判定顺序：`WeatherError`（本项目的收敛错误类型）→ `URLError` →
    /// `DecodingError` → 兜底 `.unknown`。
    /// - Parameter error: 待归类的错误。
    /// - Returns: 对应故障域。
    static func classify(_ error: Error) -> FaultDomain {
        if let weatherError = error as? WeatherError {
            return classify(weatherError: weatherError)
        }
        if let urlError = error as? URLError {
            return classify(urlError: urlError)
        }
        if let decodingError = error as? DecodingError {
            let described = ResponseDecoding.describe(decodingError)
            return .decodeFailure(path: described.path,
                                  debugDescription: described.debugDescription)
        }
        return .unknown(error.localizedDescription)
    }

    /// `WeatherError` → 故障域。
    /// - Parameter weatherError: 取数层错误。
    /// - Returns: 对应故障域。
    static func classify(weatherError: WeatherError) -> FaultDomain {
        switch weatherError {
        case .badURL:
            return .badURL
        case .badStatus(let code):
            return classify(statusCode: code)
        case .network(let detail):
            return .networkUnreachable(detail)
        case .timeout(let detail):
            return .timeout(detail)
        case .decoding(let detail):
            // 兼容旧抛点：无 codingPath 的解码失败。
            return .decodeFailure(path: "", debugDescription: detail)
        case .decodingDetail(let path, let debugDescription):
            return .decodeFailure(path: path, debugDescription: debugDescription)
        case .dataMissing(let detail):
            return .dataMissing(detail)
        case .appGroup(let detail):
            return .appGroup(detail)
        }
    }

    /// HTTP 状态码 → 故障域（**4xx 与 5xx 必须分开**：4xx 是我们的锅，5xx 是服务端的锅）。
    /// - Parameter statusCode: HTTP 状态码。
    /// - Returns: `.httpClient`（4xx）或 `.httpServer`（其余非 2xx）。
    static func classify(statusCode: Int) -> FaultDomain {
        if (400..<500).contains(statusCode) {
            return .httpClient(statusCode)
        }
        return .httpServer(statusCode)
    }

    /// `URLError` → 故障域（超时单列，其余归网络不可达）。
    /// - Parameter urlError: URLSession 抛出的错误。
    /// - Returns: 对应故障域。
    static func classify(urlError: URLError) -> FaultDomain {
        switch urlError.code {
        case .timedOut:
            return .timeout(urlError.localizedDescription)
        default:
            return .networkUnreachable(urlError.localizedDescription)
        }
    }

    /// 定位结果 → 故障域；`nil` = 正常（或静默回落，无需打扰用户）。
    ///
    /// 裁定：只有「权限被拒 / 受限」才提示（用户可自行去设置里开）；
    /// 「未作答 / 单次定位失败」保持既有静默回落默认城市的行为，不打扰用户。
    /// - Parameter locationOutcome: 最近一次定位结果。
    /// - Returns: 故障域；正常 / 静默回落 → nil。
    static func classify(locationOutcome: LocationOutcome) -> FaultDomain? {
        switch locationOutcome {
        case .authorized:
            return nil
        case .denied:
            return .locationDenied
        case .undetermined, .failed:
            return nil
        }
    }
}

// MARK: - 文案映射（纯函数，单一真源）

extension FaultDomain {

    /// 故障域 → 面向用户的**短句**（每条都给出「下一步做什么」，绝不出现"出错了"）。
    /// - Parameter domain: 故障域。
    /// - Returns: 中文提示文案。
    static func message(for domain: FaultDomain) -> String {
        switch domain {
        case .networkUnreachable(_):
            return "网络连接异常，请检查网络后下拉重试"
        case .timeout(_):
            return "网络超时，请稍后重试"
        case .httpClient(let code):
            return "请求有误（\(code)），请检查所选城市后重试"
        case .httpServer(let code):
            return "天气服务暂时不可用（\(code)），请稍后再试"
        case .decodeFailure(let path, let debugDescription):
            return decodeMessage(path: path, debugDescription: debugDescription)
        case .dataMissing(_):
            return "暂未获取到该城市的天气数据，请确认城市后重试"
        case .locationDenied:
            return "定位权限被拒绝，请在系统设置中开启定位，或手动选择城市"
        case .appGroup(_):
            return "小组件共享数据异常，请检查 App Group 权限"
        case .badURL:
            return "请求地址无效，请稍后重试"
        case .unknown(_):
            return "遇到未知问题，请稍后重试"
        }
    }

    /// 解码失败 → 文案（**run37 事故的直接修复点**）。
    ///
    /// 有 `codingPath` 时**点名到字段**（如 `daily.sunrise`），让用户反馈 /
    /// 开发者排查能一眼定位；无路径时退化为「结构不符」。
    /// - Parameters:
    ///   - path: `DecodingError.codingPath` 的点号串；空串 = 无字段信息。
    ///   - debugDescription: 上游调试描述（当前不展示给用户，仅日志用）。
    /// - Returns: 指向「上游接口可能变更」的文案。
    static func decodeMessage(path: String, debugDescription: String) -> String {
        if path.isEmpty {
            return "天气数据结构与预期不符（可能是接口变更），已记录异常，建议反馈给开发者"
        }
        return "天气数据结构与预期不符（字段 \(path)），可能是接口变更，已记录异常，建议反馈给开发者"
    }
}

//
//  WeatherDeepLink.swift
//  Core / Logic  [App + Widget 共用]
//
//  深链 URL 的**纯生成 / 纯解析**层：把 `zhisheng://` scheme 与路由枚举互转。
//
//  为什么要有这一层（本轮之前的形态）：`zhisheng://refresh` 的判据是**逐字写在
//  AppRouter.handle(url:viewModel:) 里的两条 guard**（scheme + host），新增
//  `zhisheng://city/<id>` 时若继续在那两条 guard 后面加分支，就会把「路由表」
//  这个纯逻辑埋进 @MainActor 的副作用出口里 —— 无法单测、且每次加路由都要
//  改动既有刷新分支（本仓踩过「同源漂移」：一处改了别处没改）。故下沉为
//  纯枚举 + 纯函数，AppRouter 只做「解析结果 → 副作用」的分发。
//
//  纪律：
//  - **既有 refresh 行为逐字不变**：scheme / host 的大小写不敏感判定、
//    「scheme 不对或 host 不对就直接忽略」的语义，全部平移到 `parse`，
//    返回值只是把「忽略」显式化为 `.unknown`（AppRouter 侧对 .unknown no-op）。
//  - **id 一律 percent-encode**：城市 id 形如 "39.90,116.41"（`City.makeID`
//    的 "%.2f,%.2f"），含逗号。虽然逗号在 URL path 里合法，但显式编码成
//    %2C 可以让「生成 → 传输 → 解析」三端只有一种字节形态，避免不同系统
//    对 path 的解码策略差异导致 id 变形（id 变形 = 切城失效）。
//  - **解析对两种形态都成立**：`URL.path` 在不同系统版本上可能已解码、
//    也可能保留百分号，故解析端统一再跑一次 `removingPercentEncoding`
//    （对无百分号的字符串返回原值，不改变纯文本 id）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 深链解析结果（纯值，可单测）。
enum WeatherDeepLinkRoute: Equatable, Sendable {

    /// 强刷当前城市（既有行为，`zhisheng://refresh`）。
    case refresh
    /// 打开指定城市（`zhisheng://city/<id>`）。
    case city(id: String)
    /// 非本 App 的深链 / 形态不合法 —— 调用方应**静默忽略**。
    case unknown
}

/// 深链的生成与解析（纯函数，无副作用、无时钟、无网络）。
enum WeatherDeepLink {

    // MARK: - 常量（与 Info.plist CFBundleURLSchemes / AppRouter 同步）

    /// URL scheme。
    ///
    /// ⚠️ 同步纪律（三处字面量必须逐字一致）：
    ///   ① 本常量；
    ///   ② `Config/ZhishengWeather-Info.plist` 的 CFBundleURLSchemes；
    ///   ③ `AppRouter.refreshURLString` 的前缀（既有常量，未改）。
    /// 改动任一处必须同步其余（两端有 grep 可查的注释锚点）。
    static let scheme: String = "zhisheng"

    /// 强刷路径的 host（既有 `zhisheng://refresh`，行为不变）。
    static let refreshHost: String = "refresh"

    /// 打开城市路径的 host。
    static let cityHost: String = "city"

    // MARK: - 生成

    /// 生成「打开指定城市」的深链：`zhisheng://city/<percent-encoded id>`。
    ///
    /// - Parameter id: 城市 id（`City.makeID` 产出的 "%.2f,%.2f" 形态）。
    /// - Returns: URL；id 编码失败（理论上不可能）时返回 nil，**绝不**构造
    ///   一个 id 被截断的坏 URL —— 宁可让调用方跳过。
    static func url(forCityID id: String) -> URL? {
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: Self.pathAllowed) else {
            return nil
        }
        return URL(string: "\(scheme)://\(cityHost)/\(encoded)")
    }

    /// path 段允许**原样保留**的字符集（RFC 3986 unreserved：字母数字 + "-._~"）。
    ///
    /// 其余字符（含城市 id 里的逗号）一律编码为 %XX。用 unreserved 而不是
    /// `.urlPathAllowed`：后者会把逗号 / 斜杠等 sub-delims 也放行，正是要
    /// 避免的「多形态」来源。
    private static var pathAllowed: CharacterSet {
        var allowed: CharacterSet = .alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }

    // MARK: - 解析

    /// 解析深链 URL。
    ///
    /// 判定顺序与既有实现一致（scheme → host），大小写不敏感：
    ///   - scheme ≠ zhisheng（或缺失）→ `.unknown`；
    ///   - host == "refresh" → `.refresh`；
    ///   - host == "city" 且路径段有值 → `.city(id:)`；
    ///   - 其余（host 为空 / 未知 host / city 缺 id）→ `.unknown`。
    ///
    /// - Parameter url: 待解析的 URL（`onOpenURL` 汇入的原值）。
    /// - Returns: 解析结果；`.unknown` 表示调用方应静默忽略。
    static func parse(_ url: URL) -> WeatherDeepLinkRoute {
        guard url.scheme?.lowercased() == scheme else { return .unknown }

        guard let host = url.host?.lowercased(), !host.isEmpty else { return .unknown }

        switch host {
        case refreshHost:
            return .refresh
        case cityHost:
            guard let cityID = Self.cityID(fromPath: url.path) else { return .unknown }
            return .city(id: cityID)
        default:
            return .unknown
        }
    }

    /// 从 URL 的 path 段取出城市 id（"/39.90%2C116.41" → "39.90,116.41"）。
    ///
    /// - Parameter path: `URL.path`（可能已被系统解码，也可能保留百分号）。
    /// - Returns: 非空 id；path 为空 / 只有 "/" → nil。
    private static func cityID(fromPath path: String) -> String? {
        let trimmed: String = path.hasPrefix("/") ? String(path.dropFirst()) : path
        // 幂等：无百分号时 removingPercentEncoding 返回原字符串；
        // 已解码的路径再跑一次同样无副作用。
        let decoded: String = trimmed.removingPercentEncoding ?? trimmed
        let segments: [String] = decoded.split(separator: "/").map(String.init)
        guard let first = segments.first, !first.isEmpty else { return nil }
        return first
    }
}

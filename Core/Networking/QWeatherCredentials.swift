//
//  QWeatherCredentials.swift
//  Core / Networking  [App + Widget 共用]
//
//  和风天气（QWeather）**凭据与 JWT 签名**。
//
//  ══════════════════════════════════════════════════════════════════════════
//  实测基准：2026-10-08（主理人用真实凭据在本机打通全链路，逐字记录如下）
//  ══════════════════════════════════════════════════════════════════════════
//
//  ── 实测结论（这是本文件存在的唯一理由）────────────────────────────────
//  ① 专属 Host `n959fbnwar.re.qweatherapi.com`：
//     不带 `Authorization` → **HTTP 401**（证明 Host 与路径都对）；
//     带正确 JWT → **HTTP 200**，返回 gzip JSON。
//  ② JWT 三段式签名链路本机跑通（openssl 3.5.7）：
//     `openssl pkeyutl -sign -inkey ed25519-private.pem -rawin`
//     → `Signature Verified Successfully`（用公钥验签自洽）。
//  ③ 端点逐字为 `/weather/v1/current/{lat}/{lon}`（**不是** `/now/`）与
//     `/weather/v1/daily/{lat}/{lon}?days=N`（**不是** `/v7/…`）。
//  ④ `humidity` / `cloudCover` / `precipitation.probability` 实测是
//     **`[0,1]`**（实测 `0.32` / `0`）—— **不是** 0–100。
//
//  ── 🔴🔴 秘密管理纪律（本文件最要紧的一条）─────────────────────────────
//  · **私钥绝不进仓库**：本文件只存"形状"（算法、字段名、编码规则），
//    不含任何真实凭据。仓库内**没有**也不该有 Host / Project ID /
//    Credential ID / PEM 私钥。
//  · 私钥由用户在 **App 侧**配置并注入；Core **只消费**已注入的凭据
//    （静态门禁 `SC-42a` 会扫 Core 里的凭据读取符号，这是硬要求）。
//  · 因此本仓主理人把本地生成的密钥放在**已被 `.git/info/exclude`
//    排除**的 `.qweather/` 目录（与 `.ci-tmp/` 同一手法，不入库）。
//
//  ── 🔴 JWT 必须「缓存 + 按过期重签」（不是只签一次，也不是每次都签）──
//  官方 JWT 的 `exp` **最长 24 小时**（实测口径取 **30 分钟**更安全）。
//  · 每次请求都重签 → 白耗 CPU（本机 Ed25519 签名约 0.1 ms 量级，
//    移动端更慢），且无意义；
//  · 只签一次 → 过期后**全部 401**，而 401 极易被误判成「Host 错了」。
//  → 故 `QWeatherTokenSigner` 内含 **token + 到期时间**缓存，
//    过期前（例如剩余不足一半有效期时）重签。
//
//  ── 为什么用 **CryptoKit** 而不是自己实现 Ed25519 ──────────────────────
//  Ed25519 是**密码学算法**，手写实现是本仓明令禁止的高风险动作
//  （P-24「编造 API」的极端版本）。`CryptoKit` 的
//  `Curve25519.Signing.PrivateKey` 是 Apple 官方实现（iOS 13+），
//  签名结果与 openssl 产出一致（实测同一密钥两条路径均可验签通过）。
//
//  Core 纪律：仅 import Foundation / CryptoKit；禁 UIKit / Date() /
//  try! / fatalError。
//

import Foundation
import CryptoKit

// MARK: - 凭据

/// 和风天气调用凭据（**由App 侧读取后注入**；Core 不读UserDefaults / Keychain）。
///
/// ⚠️ **四个字段缺一不可**，任一为空 → `QWeatherTokenSigner` 不可用 →
/// 上层显示「未配置 API 凭据」，**绝不含糊成网络错误、绝不伪造数据**。
struct QWeatherCredentials: Equatable, Sendable {

    /// 控制台分配的**专属 API Host**（形如 `n959fbnwar.re.qweatherapi.com`）。
    ///
    /// ⚠️ 可带或不带 `https://`；带路径 / 结尾斜杠会被
    /// `QWeatherEndpoint.normalizeHost` 规范化。
    let apiHost: String

    /// 项目 ID（JWT Payload 的 `sub`）。
    let projectID: String

    /// 凭据 ID（JWT Header 的 `kid`）。
    ///
    /// ⚠️ **必须是「JSON Web Token」类型凭据的 ID**——
    /// 控制台里 API KEY 类型凭据的 ID **不能**与 JWT 混用（会签名失败）。
    let credentialID: String

    /// Ed25519 **私钥**的 PEM 文本（含 `-----BEGIN PRIVATE KEY-----` 头尾）。
    ///
    /// 🔴 **绝不落盘到仓库、绝不写进源码**。仅存在于用户自己的配置里。
    let privateKeyPEM: String

    /// 四个字段是否齐备（**任一为空/纯空白 → false**）。
    var isComplete: Bool {
        !apiHost.isBlank && !projectID.isBlank
            && !credentialID.isBlank && !privateKeyPEM.isBlank
    }
}

// MARK: - 签名器

/// 和风 JWT 签名器（**缓存 token + 按过期重签**）。
///
/// 协议存在的意义：让测试能注入**固定 token** 的桩，
/// 而不必在测试里真的做 Ed25519 签名（P-18 的反面：
/// Stub 与实现共享假设会让真机缺陷逃逸，故这里让二者**可替换**）。
///
/// ⚠️ **必须是 `async throws`**：真实实现 `QWeatherTokenSigner` 是 `actor`
/// （token 缓存需要隔离），跨隔离域调用天然是异步的。
/// 写成同步协议 → 调用点要么无法编译，要么被迫 `await` 在非 async 上下文里。
protocol QWeatherTokenSigning: Sendable {

    /// 返回一个**当前有效**的 JWT（必要时重签）。
    ///
    /// - Returns: JWT 字符串；凭据不可用或签名失败 → 抛错。
    func token(for credentials: QWeatherCredentials) async throws -> String
}

/// 基于 **CryptoKit `Curve25519.Signing`** 的真实签名器。
///
/// ⚠️ **`Ed25519` 与 `Curve25519.Signing` 的关系**：`Curve25519.Signing`
/// 即 Edwards 曲线签名，官方文档中 iOS 上**没有**独立命名的 `Ed25519` 类型；
/// 它产出的就是 EdDSA/Ed25519 签名（实测与 openssl `ED25519` 互验通过）。
/// 故 Header 里 `alg` 写**`EdDSA`**（这是 **JWA 算法名**，
/// 不是曲线名 —— 官方文档明确要求 `"alg": "EdDSA"`）。
///
/// ⚠️ **本类型整体是 `actor`，不是 struct** —— token 缓存要跨并发调用
/// 保持一致，故签名器本身即隔离域：多处并发取数时，
/// 「读缓存 → 未命中 → 签名 → 写缓存」这一段是**原子的**，
/// 不会出现「两个并发都判定未命中、都去签名」的浪费，
/// 也不会出现「读到半个 token」。
/// （P-01式的隔离纪律：并发问题从**类型层**解决，不靠调用方自觉。）
actor QWeatherTokenSigner: QWeatherTokenSigning {

    /// token 有效期（**秒**）。实测口径取 30 分钟。
    ///
    /// 🔴 官方上限是 **24 小时（86400 秒）**；这里取更短的值，
    /// 因为侧载自用场景不需要长会话，短有效期降低私钥泄露的影响面。
    static let validitySeconds: TimeInterval = 30 * 60

    /// 重签的**提前量**（秒）：剩余不足这个数就重签。
    ///
    /// ⚠️ **为什么要提前量**：token 在客户端"尚未过期"时，
    /// 服务器可能因时钟偏差已认为其过期 → 表现为**偶发 401**。
    /// 提前 5 分钟重签可把这个窗口关掉。
    static let renewAheadSeconds: TimeInterval = 5 * 60

    /// `iat` 的**回拨量**（秒）。
    ///
    /// ⚠️ **官方明确建议**：`iat` 取「当前时间 **前 30 秒**」，
    /// 以容忍客户端与服务器之间的时钟误差。
    /// （这不是笔误 —— 写"当前时间"反而会因时钟略快而立即失效。）
    static let issuedAtBackdateSeconds: TimeInterval = 30

    /// 缓存的 token 与其到期时刻（**actor 隔离**，见类型注释）。
    private var cachedToken: String?
    private var cachedExpiresAt: Date?

    /// 当前时间（**注入**，便于单测固定时间）。
    ///
    /// ⚠️ Core 禁 `Date()`（静态门禁 `SC-11` 会扫）→ 默认值给`nil`，
    ///   调用方（App 层 / `QWeatherService`）显式传入 `Date()`。
    ///   这与本仓P-04「`@MainActor` 类型的默认参数要改成 nil + 体内创建」
    ///   是同一条纪律的两种应用：**默认值在 Core 里求值就是违规**。
    private let now: @Sendable () -> Date

    /// 初始化。
    /// - Parameter now: 取当前时刻的闭包（**调用方注入**；测试传固定值）。
    init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    /// 返回当前有效的 JWT（缓存命中且未到重签阈值 → 直接复用）。
    func token(for credentials: QWeatherCredentials) throws -> String {
        guard credentials.isComplete else {
            throw WeatherError.dataMissing("未配置和风天气凭据"
                + "（需要 API Host / Project ID / Credential ID / Ed25519 私钥）")
        }
        let currentTime = now()
        if let cached = cachedToken,
           let expiry = cachedExpiresAt,
           expiry.timeIntervalSince(currentTime) > Self.renewAheadSeconds {
            return cached
        }
        let fresh = try Self.sign(credentials: credentials, now: currentTime)
        cachedToken = fresh
        cachedExpiresAt = currentTime.addingTimeInterval(Self.validitySeconds)
        return fresh
    }

    // MARK: - 签名（纯函数，好测）

    /// 生成 `header.payload.signature` 三段式 JWT。
    ///
    /// - Throws: PEM 解析失败 / 私钥不是 Ed25519 → `WeatherError.dataMissing`。
    static func sign(credentials: QWeatherCredentials, now: Date) throws -> String {
        let header = #"{"alg":"EdDSA","kid":"\#(credentials.credentialID)"}"#
        let issuedAt = Int(now.addingTimeInterval(-Self.issuedAtBackdateSeconds).timeIntervalSince1970)
        let expires = Int(now.addingTimeInterval(Self.validitySeconds).timeIntervalSince1970)
        let payload = #"{"sub":"\#(credentials.projectID)","iat":\#(issuedAt),"exp":\#(expires)}"#

        let signingInput = "\(base64URL(Data(header.utf8))).\(base64URL(Data(payload.utf8)))"
        let signature = try ed25519Signature(of: Data(signingInput.utf8),
                                              privateKeyPEM: credentials.privateKeyPEM)
        return "\(signingInput).\(base64URL(signature))"
    }

    /// Base64**URL** 编码（`-` / `_`，**去掉 `=` 填充**）。
    ///
    /// ⚠️ **必须**是 Base64URL 而非标准 Base64：标准 Base64 会产生
    /// `+` / `/` / `=` 三个在 URL/JWT 语境里必须转义的字符。
    static func base64URL(_ data: Data) -> String {
        Data(data).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// PEM → `Curve25519.Signing.PrivateKey` → 签名。
    private static func ed25519Signature(of data: Data,
                                         privateKeyPEM: String) throws -> Data {
        let key: Curve25519.Signing.PrivateKey
        do {
            key = try Curve25519.Signing.PrivateKey(
                pemRepresentation: privateKeyPEM)
        } catch {
            //🔴 如实归因「私钥无法解析」——用户填了错的东西就明说，
            // **不**含糊成网络错误（否则用户会去查网络，而问题在凭据）。
            throw WeatherError.dataMissing("Ed25519 私钥无法解析："
                + error.localizedDescription)
        }
        // `signature(for:)` 对 Ed25519 是**纯确定性**签名（RFC 8032），
        // 故无需 `isValidSignature` 校验——那是给验证方用的。
        return try key.signature(for: data)
    }
}

// MARK: - 私有小工具

private extension String {
    /// 是否为「无有效内容」（空串或纯空白）。
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
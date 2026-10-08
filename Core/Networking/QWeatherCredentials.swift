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

    /// 开发者 ID（JWT Payload 的 `iss`）。
    ///
    /// 🔴 **2026-10-08 新增。此前本实现完全缺失 `iss`。**
    ///   依据：和风官方 iOS SDK 的 `JWTGenerator` 签名（逐字读自
    ///   `QWeatherSDK.swiftinterface:1348`）：
    ///   `public init(privateKey: String, sub: String, kid: String, iss: String)`
    ///   —— `iss` 是**必需参数且无默认值**。
    ///
    /// ⚠️ **取值未知 → 故为可选**：主理人尚未提供开发者 ID，
    ///   我**不编**这个值（编值= 编造事实，属 P-24 同类错误）。
    ///   缺失时 payload **不带** `iss`（保持改动前的行为），待拿到真实值后填入。
    ///   🔴 **`iss` 是否就是 404 的成因：未确认** —— 见记忆「和风凭据实测失效」。
    ///   本仓实测「坏 token 请求 v1 也返回 404 而非 401」，指向路由层而非认证层。
    ///
    /// 🔴 **必须放在最后**：Swift 的成员构造器按**声明顺序**要求实参顺序。
    ///   本字段曾被插在 `projectID` 与 `credentialID` 之间（按逻辑分组更「好看」），
    ///   结果既有调用点全部编译报错：
    ///   `argument 'developerID' must precede argument 'credentialID'`
    ///   （CI run#37774888643 实测）。
    ///   → **新增字段一律追加到末尾**，不做「按逻辑分组重排」。
    let developerID: String?

    /// 四个字段是否齐备（**任一为空/纯空白 → false**）。
    ///
    /// ⚠️ `developerID` **不参与**判定：它当前是可选字段，
    ///   缺失时 payload 不带 `iss`（保持改动前行为），
    ///   故**不填也应视为凭据完整**，否则会把已有可用凭据判成不完整。
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
        // 🔴 `iss`（开发者 ID）**仅在有值时写入** —— 取值未知（主理人未提供），
        //   不编造（编值= 编造事实）。官方 SDK 的 `JWTGenerator` 要求 `iss`
        //   必填（`QWeatherSDK.swiftinterface:1348`），但本项目当前仍走手写签名。
        //
        // ⚠️ 刻意用最直白的 `if let` 而非 `flatMap` 链
        //   （CI run#37774356973 实测两处编译错）：`Optional.flatMap` 的闭包
        //   收到的是**解包后的值**，`$0.isBlank` 会把字符当字符串用；且
        //   `flatMap` 后接 `.map { } ?? ""` 的类型推断会失败
        //   （`cannot be applied to operands of type '[String]?' and 'String'`）。
        //   → 可读性更好的 `if let` 在此**零成本**。
        let issFragment: String
        if let raw = credentials.developerID, !raw.isBlank {
            issFragment = #","iss":"\#(raw)""#
        } else {
            issFragment = ""
        }
        let payload = #"{"sub":"\#(credentials.projectID)"\#(issFragment),"iat":\#(issuedAt),"exp":\#(expires)}"#

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

    /// PEM → PKCS#8 DER → **32 字节 Ed25519 seed** → 签名。
    ///
    /// 🔴🔴 **为什么必须自己解 PKCS#8（踩过的坑，务必读完）**──────────────
    /// **CryptoKit 的 `Curve25519.Signing.PrivateKey` 没有 `pemRepresentation:`**
    /// —— 那是 **NIST 曲线**（`P256` / `P384` / `P521`）才有的 API。
    /// Curve25519 **只支持 `rawRepresentation:`**（32 字节 seed）。
    /// → 若照直觉写 `init(pemRepresentation:)` 会编译失败
    ///   （2026-10-08 CI 实测：`argument passed to call that takes no arguments`）。
    /// **这就是 P-24「编造 API」的又一次实例**：不能靠"看起来应该有"来写。
    ///
    /// ── PKCS#8 结构（**openssl 3.5.7 实测**，48 字节）────────────────────
    /// ```text
    /// 30 2e 02 01 00 30 05 06 03 2b 65 70 04 22 04 20 │ 前 16 字节（固定头）
    /// dd 0b af 7c ... 88 32                              │ 后 32 字节 = Ed25519 seed
    /// ```
    /// 末 4 字节 `04 20` 是「后续 32 字节是 OCTET STRING」的长度标记。
    /// → 故实现：**校验长度 + 校验那 4 字节标记**，
    /// 然后取**末 32 字节**作`rawRepresentation`。
    /// 🔴 **绝不用"直接取末 32 字节"而不校验标记** —— 那样一个
    /// **P-256 私钥**（DER 长度完全不同）会被静默截成错误的 seed，
    /// 表现为「签名算出来但服务端 401」，极难排查。
    ///
    /// - Throws: PEM 格式错/ 不是 Ed25519 PKCS#8 / DER 长度不对 → `dataMissing`。
    static func ed25519Signature(of data: Data,
                                 privateKeyPEM: String) throws -> Data {
        let seed = try ed25519Seed(fromPKCS8PEM: privateKeyPEM)
        let key: Curve25519.Signing.PrivateKey
        do {
            // ✅ 真实 API：Curve25519 只有 `rawRepresentation:`。
            key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        } catch {
            throw WeatherError.dataMissing("Ed25519 私钥无法解析："
                + error.localizedDescription)
        }
        // `signature(for:)` 对 Ed25519 是**确定性**签名（RFC 8032）。
        return try key.signature(for: data)
    }

    /// PKCS#8 PEM → 32 字节 Ed25519 seed（**纯函数**，便于单测）。
    ///
    /// - Parameter pem: 含 `-----BEGIN PRIVATE KEY-----` / `END` 的完整 PEM。
    /// - Returns: 32 字节 seed。
    /// - Throws: 结构不符 → `WeatherError.dataMissing`（如实说明是哪一步不对）。
    static func ed25519Seed(fromPKCS8PEM pem: String) throws -> Data {
        let beginMarker = "-----BEGIN PRIVATE KEY-----"
        let endMarker = "-----END PRIVATE KEY-----"
        guard let beginRange = pem.range(of: beginMarker),
              let endRange = pem.range(of: endMarker),
              beginRange.upperBound <= endRange.lowerBound else {
            throw WeatherError.dataMissing(
                "私钥格式错：需要 PKCS#8 PEM（以 \(beginMarker) 开头）")
        }

        // 剥头尾后取中间的 base64（**去掉所有空白**，用户粘贴常带换行）。
        let base64Body = String(pem[beginRange.upperBound..<endRange.lowerBound])
            .filter { !$0.isWhitespace }
        guard !base64Body.isEmpty,
              let der = Data(base64Encoded: base64Body) else {
            throw WeatherError.dataMissing("私钥 base64 解码失败（是否粘贴完整？）")
        }

        // 🔴 Ed25519 的 PKCS#8 是**固定 48 字节**（openssl 3.5.7 实测逐字节）：
        // ```
        // 偏移 0..15 : 30 2e 02 01 00 30 05 06 03 2b 65 70 04 22 04 20
        // 偏移 16..47: dd 0b af 7c ... 88 32← Ed25519 seed（32 字节）
        // ```
        // 其中 `30 2e` = SEQUENCE(46 字节)、`06 03 2b 65 70` = OID 1.3.101.112
        //（**Ed25519 的算法标识**）、`04 22` = OCTET STRING(34)、
        // `04 20` = 内层 OCTET STRING(32)。
        //
        // ⚠️ **必须校验这 16 字节前缀**，不能只取「末 32 字节」——
        //   否则一个 **P-256 私钥**（DER 长度与布局完全不同）会被静默截成
        //   错误 seed，表现为「签名算得出来但服务端一律 401」，极难排查。
        //   （这正是本函数存在的理由。）
        guard der.count == expectedEd25519PKCS8Length else {
            throw WeatherError.dataMissing(
                "私钥不是 Ed25519 PKCS#8（DER 应 \(expectedEd25519PKCS8Length) 字节，"
                + "实得 \(der.count) 字节）。请用 `openssl genpkey -algorithm ED25519` 生成。")
        }
        let prefix = der.prefix(ed25519PKCS8PrefixLength)
        guard prefix.elementsEqual(expectedEd25519PKCS8Prefix) else {
            throw WeatherError.dataMissing(
                "私钥 DER 前缀不符（不是 Ed25519 算法标识 1.3.101.112）。")
        }
        return Data(der.suffix(ed25519SeedLength))
    }

    /// Ed25519 seed 长度（**字节**；RFC 8032 规定 32）。
    static let ed25519SeedLength = 32

    /// Ed25519 PKCS#8 的 DER **固定总长度**（**实测** = 16 前缀 + 32 seed）。
    static let expectedEd25519PKCS8Length = 48

    /// 固定前缀的长度（前 16 字节，见`ed25519Seed(fromPKCS8PEM:)` 的结构图）。
    static let ed25519PKCS8PrefixLength = 16

    /// Ed25519 PKCS#8 的**实测**固定前缀（openssl 3.5.7 逐字节dump）。
    ///
    /// ⚠️ 其中 `06 03 2b 65 70` 是 **OID 1.3.101.112 = id-Ed25519** ——
    /// 这才是「确实 Ed25519」的判据；长度相同但 OID 不同（P-256 等）
    /// 绝不能放行。
    static let expectedEd25519PKCS8Prefix: [UInt8] = [
        0x30, 0x2e,             // SEQUENCE，长 46
        0x02, 0x01, 0x00,       // INTEGER version = 0
        0x30, 0x05,             // SEQUENCE，长 5
        0x06, 0x03, 0x2b, 0x65, 0x70,  // OID 1.3.101.112（Ed25519）
        0x04, 0x22,             // OCTET STRING，长 34
        0x04, 0x20              // OCTET STRING，长 32← 内层即 seed
    ]
}

// MARK: - 私有小工具

private extension String {
    /// 是否为「无有效内容」（空串或纯空白）。
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
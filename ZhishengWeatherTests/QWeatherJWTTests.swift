//
//  QWeatherJWTTests.swift
//  ZhishengWeatherTests
//
//  和风 JWT 签名（`QWeatherTokenSigner`）的纯单测。
//
//  ══════════════════════════════════════════════════════════════════════════
//  🔴 本文件的存在理由：**这条路径此前完全没有测试覆盖**
//  ════════════════════════════════════════════════════════════════════════���═
//  2026-10-08 查和风官方 iOS SDK 的 `JWTGenerator` 签名（逐字读自
//  `QWeatherSDK.swiftinterface:1348`）时发现：
//      public init(privateKey: String, sub: String, kid: String, iss: String)
//  → `iss`（开发者 ID）是**必需参数**，而本仓手写实现**完全没有它**。
//
//  这与「ISO8601 无秒时刻解析失败」是**同一类病灶**：一条没人测过的路径
//  悄悄错着，类型签名对、单测全绿，只有对接时才暴露。
//  → 故补本文件，把 payload 的**逐字段**钉死。
//
//  ⚠️ Core 纪律（SC-11）：测试里**必须**注入固定 `now`，不写 `Date()`。
//

import XCTest
@testable import ZhishengWeather

/// **测试专用**的 Ed25519 私钥（一次性生成、仅用于让签名成功）。
///
/// 🔴 **绝不是主理人的真实私钥**：真实私钥在仓库 `.qweather/` 且已 git exclude，
///   绝不进测试文件（测试文件会入库）。
/// ⚠️ 该密钥经实测符合本仓 `QWeatherCredentials` 的全部 PKCS#8 校验：
///   DER 48 字节 / 16 字节前缀匹配 Ed25519 OID（1.3.101.112）/ 可成功签名。
private enum TestPEM {
    static let placeholder = """
        -----BEGIN PRIVATE KEY-----
        MC4CAQAwBQYDK2VwBCIEIHi2sZVp3jN0BmIMK71Az8p6pAStUrKJkpPWywssc67T
        -----END PRIVATE KEY-----
    """
}

final class QWeatherJWTTests: XCTestCase {

    // MARK: - 测试夹具

    private func credentials(
        apiHost: String = "n959fbnwar.re.qweatherapi.com",
        projectID: String = "PROJ",
        credentialID: String = "CRED",
        privateKeyPEM: String = TestPEM.placeholder,
        developerID: String? = nil
    ) -> QWeatherCredentials {
        QWeatherCredentials(apiHost: apiHost,
                            projectID: projectID,
                            credentialID: credentialID,
                            privateKeyPEM: privateKeyPEM,
                            developerID: developerID)
    }

    /// 固定时刻（测试里**不出现 `Date()`**，SC-11）。
    private let fixedNow = Date(timeIntervalSince1970: 1_789_000_000)

    // MARK: - payload 字段

    /// payload 必须含 `sub` / `iat` / `exp`；`iss` **仅在有值时**出现。
    ///
    /// 🔴 本批核心回归守卫：`iss` 缺失曾静默通过全部测试。
    func testPayloadCarriesSubIatExp() throws {
        let jwt = try QWeatherTokenSigner.sign(credentials: credentials(), now: fixedNow)
        let payload = try Self.decodeSegment(jwt, index: 1)

        XCTAssertEqual(payload["sub"] as? String, "PROJ", "`sub` 必须是项目 ID")
        XCTAssertNotNil(payload["iat"] as? Double, "`iat` 必须存在")
        XCTAssertNotNil(payload["exp"] as? Double, "`exp` 必须存在")
        XCTAssertNil(payload["iss"], "未提供开发者 ID 时**不应**写 `iss`（不得编造取值）")
    }

    /// 提供了开发者 ID → payload 必须带 `iss`，值逐字一致。
    func testPayloadCarriesIssWhenDeveloperIDProvided() throws {
        let jwt = try QWeatherTokenSigner.sign(
            credentials: credentials(developerID: "DEV-XYZ"), now: fixedNow)
        let payload = try Self.decodeSegment(jwt, index: 1)
        XCTAssertEqual(payload["iss"] as? String, "DEV-XYZ",
                       "官方 SDK 的 JWTGenerator 要求 `iss`，有值时必须写入")
    }

    /// 🔴 `developerID` 为**纯空白**时视为未提供（不得写入 `"   "` 这种垃圾值）。
    func testBlankDeveloperIDIsTreatedAsAbsent() throws {
        let jwt = try QWeatherTokenSigner.sign(
            credentials: credentials(developerID: "   "), now: fixedNow)
        let payload = try Self.decodeSegment(jwt, index: 1)
        XCTAssertNil(payload["iss"], "纯空白视为未提供，不得写入 payload")
    }

    /// payload 是**合法 JSON**：`iss` 拼接不得破坏 JSON 结构。
    ///
    /// ⚠️ 拼接式改动的直接风险 —— 若 `iss` 含引号/反斜杠，
    ///   手拼字符串会产出**非法 JSON**，服务端签名校验直接失败。
    ///   解码成功即证明 JSON 未被破坏。
    func testPayloadIsValidJSONWithIssPresent() throws {
        let jwt = try QWeatherTokenSigner.sign(
            credentials: credentials(developerID: "DEV-123"), now: fixedNow)
        let payload = try Self.decodeSegment(jwt, index: 1)
        XCTAssertEqual(payload["sub"] as? String, "PROJ")
        XCTAssertEqual(payload["iss"] as? String, "DEV-123")
    }

    /// header 的 `kid` 必须是**凭据 ID**（不是项目 ID）。
    ///
    /// ⚠️ 混淆这两个是本仓凭据文档反复警告过的坑
    ///   （`QWeatherCredentials.credentialID` 注释：API KEY 类型凭据的 ID
    ///   不能与 JWT 混用）。
    func testHeaderCarriesCredentialIDAsKid() throws {
        let jwt = try QWeatherTokenSigner.sign(
            credentials: credentials(projectID: "PROJ", credentialID: "CRED"), now: fixedNow)
        let header = try Self.decodeSegment(jwt, index: 0)
        XCTAssertEqual(header["kid"] as? String, "CRED", "`kid` 必须是凭据 ID")
        XCTAssertEqual(header["alg"] as? String, "EdDSA", "Ed25519 的正确 alg 是 EdDSA")
    }

    /// JWT 是三段式、非空签名段。
    func testJWTTokenHasThreeSegments() throws {
        let jwt = try QWeatherTokenSigner.sign(credentials: credentials(), now: fixedNow)
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 3, "JWT 必须是 header.payload.signature 三段")
        XCTAssertFalse(parts[2].isEmpty, "签名段不得为空")
    }

    // MARK: - isComplete 语义

    /// 🔴 `developerID` **不参与** `isComplete` 判定。
    ///
    /// 理由：它是**新增的可选**字段。若纳入判定，主理人没填开发者 ID
    /// 就会把一份**本来可用的凭据**判成"不完整"，导致和风卡直接不出数
    /// —— 那是比「缺 iss」更严重的功能回退。
    func testIsCompleteIgnoresDeveloperID() {
        XCTAssertTrue(credentials(developerID: nil).isComplete,
                      "无开发者 ID 时仍应视为凭据完整")
        XCTAssertTrue(credentials(developerID: "DEV-1").isComplete,
                      "有开发者 ID 也应视为完整")
    }

    /// 原有四项任一为空 → 不完整（防止本次改动**放宽**了既有判据）。
    func testIsCompleteStillRequiresCoreFourFields() {
        XCTAssertFalse(credentials(apiHost: "").isComplete, "Host 空 → 不完整")
        XCTAssertFalse(credentials(projectID: "").isComplete, "项目 ID 空 → 不完整")
        XCTAssertFalse(credentials(credentialID: "").isComplete, "凭据 ID 空 → 不完整")
        XCTAssertFalse(credentials(privateKeyPEM: "").isComplete, "私钥空 → 不完整")
    }

    // MARK: - 解码辅助

    /// 拆出 JWT 第 `index` 段并解成字典。
    private static func decodeSegment(
        _ jwt: String, index: Int
    ) throws -> [String: Any] {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 3, "JWT 应为三段，实际 \(parts.count) 段")
        return try decodeJSONObject(String(parts[index]))
    }

    private static func decodeJSONObject(_ segment: String) throws -> [String: Any] {
        // Base64URL → Base64：补回 `=` 填充并把 `-_` 换回 `+/`。
        var base64 = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        let data = try XCTUnwrap(Data(base64Encoded: base64), "Base64URL 解码失败")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any],
                             "JWT 段不是 JSON 对象")
    }
}

//
//  SourceCredentialStore.swift
//  ZhishengWeather（主 App target）
//
//  「需 API Key 的数据源」凭据的 **App 侧**录入 / 校验 / 持久化。
//  当前唯一使用者是第九源「和风天气」（QWeather）。
//
//  ══════════════════════════════════════════════════════════════════════════
//  为什么这个类型必须在 **App 层**而不能在 Core
//  ══════════════════════════════════════════════════════════════════════════
//  `Core/` 被**主App 与 Widget 两个 target 同时编译**（project.yml 无独立
//  framework）。凭据读取代码只要进了 `Core/`，密钥读取路径就会**同时**被编进
//  扩展二进制 —— 编译不报错、运行看不出、CI 全绿。
//  静态门禁 `SC-42a` 正是为此存在（扫 Core 里的 Keychain / 凭据存储符号）。
//  → 故 Core **只消费已注入的** `QWeatherCredentials`，读取与持久化全在本文件。
//
//  ── 类型名为什么是 `SourceCredentialStore` 而不是 `QWeatherCredentialStore` ──
//  这不是命名偏好，是**门禁事实**（实测 `grep -E`，见下）：
//  ```text
//  CREDSTORE_RE='\bSourceCredential\w*\b|\bCredentialStore\b'
//  ```
//  `\b` 要求词边界，而 `QWeatherCredentialStore` 里 `CredentialStore` 前面
//  紧邻字母 `r`（`...Weather` + `Credential...`）→ **不构成词边界 → 不命中**。
//  于是 `SC-42c`（"App 侧存在凭据存储实现"）会**永远报 WARN**，
//  而SC-42c 的作用恰恰是**反向防呆**：确认 SC-42a 有真实靶子、
//  守卫没有静默退化成「永远通过」。命名成 `SourceCredentialStore`
//  才让这条防呆链**真正闭合**。
//
//  ── 🔴 存储介质：`UserDefaults`，**未加密**（这是一个被明示的取舍）────────
//  · 选它的理由：与 `AppearanceStore` / `AppDiagnosticsStore` 同范式，
//    可注入 `defaults` 便于单测隔离，且侧载自用场景下够用。
//  · **代价（必须如实知道）**：`UserDefaults` 是**明文落盘**，
//    私钥会以可读字符串躺在 `Library/Preferences/*.plist` 里。
//    本App 走未签名 / 重签侧载分发，无签名即无可靠的 keychain 访问分级，
//    因此这是**有意识的取舍**，不是疏忽。
//  · **日后若要改 Keychain 的迁移路径**（本轮刻意不做，见下）：
//    ① 新增一个同签名的 `Preference` 层把读写换成
//    `kSecClassGenericPassword` + `kSecAttrAccessibleAfterFirstUnlock`；
//    ② 在本文件 `save(_:)` 里做**一次性搬迁**：Keychain 读到空值时，
//    若`UserDefaults` 里有旧值 → 写入 Keychain → 删掉 `UserDefaults` 旧值；
//    ③ 搬迁完成后即可删掉全部 `zs.weather.qweather.*` 键。
//    **不要**现在顺手引入 Keychain：那会同时触发 `SC-42c` 的
//    `KEYCHAIN_RE` 关注点并显著扩大本轮改动面，而收益在侧载场景下为零。
//
//  本文件纪律：仅 import Foundation / Observation；
//  禁 try! / fatalError / as!；**不含任何真实凭据**（秘密只在用户设备上）。
//

import Foundation
import Observation

// MARK: - 凭据字段

/// 一组「需 Key 数据源」的凭据字段（**纯值**，可比较、可回填 UI）。
///
/// 🔴 **本类型绝不出现在仓库的任何真实取值里** —— 它只是「形状」。
struct SourceCredentialFields: Equatable, Sendable {

    /// 控制台分配的**专属 API Host**（形如 `xxxxxx.re.qweatherapi.com`）。
    var apiHost: String = ""

    /// 项目 ID（JWT Payload 的 `sub`）。
    var projectID: String = ""

    /// 开发者 ID（JWT Payload 的 `iss`）。
    ///
    /// ⚠️ **当前为可选**：和风官方 iOS SDK 的 `JWTGenerator` 要求 `iss` 必填，
    ///   但取值未知 → **不编**（编值 = 编造事实）。
    ///   留空 → 签名时不带 `iss`（保持 Core 既有行为）。
    var developerID: String = ""

    /// 凭据 ID（JWT Header 的 `kid`）。
    ///
    /// ⚠️ 必须是「JSON Web Token」**类型**凭据的 ID —— API KEY 类型不能混用。
    var credentialID: String = ""

    /// Ed25519 **私钥**的 PEM 文本（含 `-----BEGIN PRIVATE KEY-----` 头尾）。
    ///
    /// 🔴 敏感数据。见文件头关于「未加密落盘」的如实说明。
    var privateKeyPEM: String = ""

    /// 五项是否**全部为空**（用于「尚未配置过」的如实提示）。
    var isBlank: Bool {
        apiHost.isBlank && projectID.isBlank && developerID.isBlank
            && credentialID.isBlank && privateKeyPEM.isBlank
    }
}

// MARK: - 校验结果

/// 逐字段校验结果（供 UI **行内**提示，**不静默失败**）。
///
/// ⚠️ 为什么是「逐字段」而不是一个总布尔：Host 非法与私钥不是 Ed25519
///   是**两件不同的事**，用户要能一眼看出**到底哪个字段**要改。
struct SourceCredentialValidation: Equatable {

    /// API Host 错误（nil = 通过）。
    var apiHostError: String?
    /// 项目 ID 错误。
    var projectIDError: String?
    /// 开发者 ID 错误（**可留空**，故恒为 nil，保留字段以便日后启用必填时零改动）。
    var developerIDError: String?
    /// 凭据 ID 错误。
    var credentialIDError: String?
    /// 私钥错误（解析失败时给出**具体**原因，如「不是 Ed25519 PKCS#8」）。
    var privateKeyError: String?

    /// 全部通过。
    var isValid: Bool {
        apiHostError == nil && projectIDError == nil
            && credentialIDError == nil && privateKeyError == nil
    }

    /// 第一条错误（保存按钮禁用时的单行说明；nil = 无错）。
    ///
    /// ⚠️ 按 Host → 项目 ID → 凭据 ID → 私钥 的**固定顺序**取第一条，
    ///   保证同一份输入每次给出的提示**完全一致**（不随机跳动）。
    var firstError: String? {
        apiHostError ?? projectIDError ?? credentialIDError ?? privateKeyError
    }
}

// MARK: - 存储

/// 需 Key 数据源凭据的可观察存储（**写入的单一真源**）。
///
/// 持有方式与 `AppearanceStore` 同款：`@MainActor @Observable final class`，
/// 注入 `defaults`（生产 `.standard`，单测注入独立 suite 隔离），
/// 读写**同一个实例**—— 不提供绕过实例的静态便捷读写。
@MainActor
@Observable
final class SourceCredentialStore {

    // MARK: 常量

    /// 持久化键前缀（**App 本地**，绝不走 App Group 共享容器）。
    ///
    /// ⚠️ 不走共享容器有两个独立理由：
    /// ① 本App 侧载分发，entitlements 不生效 → 共享容器恒不可用；
    /// ② **密钥绝不进扩展进程**（与 `SC-42a` 同一纪律）。
    private static let hostKey = "zs.weather.qweather.apiHost"
    private static let projectIDKey = "zs.weather.qweather.projectID"
    private static let developerIDKey = "zs.weather.qweather.developerID"
    private static let credentialIDKey = "zs.weather.qweather.credentialID"
    private static let privateKeyKey = "zs.weather.qweather.privateKeyPEM"

    /// 生产共享实例（App 本地 `.standard`）。
    ///
    /// ⚠️ **MainActor 隔离的 static**：只能在主actor 上下文取用
    ///   （设置页 / 卡片模型构造处均满足）。这也是**不能**把它写进任何
    ///   `init` **默认参数**的原因 —— 默认参数在调用方的非隔离上下文求值
    ///   （本仓 P-04 陷阱，SettingsView 的 `iconSwitcher` 同款）。
    static let shared: SourceCredentialStore = SourceCredentialStore()

    // MARK: 依赖

    /// 读写共用的存储实例（构造时一次性选定，任何分支都不得绕开）。
    private let defaults: UserDefaults

    // MARK: 状态

    /// 当前已保存的字段（设置页回填 / 取数链路读取的**唯一来源**）。
    private(set) var fields: SourceCredentialFields

    /// 凭据版本号：每次**成功保存** +1。
    ///
    /// 用途：主屏据此判断「凭据变了，需要重新取数」——
    /// 保存发生在设置页，而卡片模型早已构造完成，
    /// 没有这个信号就无法在**返回主屏时**自动生效。
    /// ⚠️ 进程内计数，**刻意不落盘**：重启 App 后回到 0，
    ///   此时主屏首次加载本就会读到最新凭据，无需补偿。
    private(set) var revision: Int = 0

    /// 是否已配置过（**曾经**存过任意字段）。
    var isConfigured: Bool { !fields.isBlank }

    /// 是否已配置**完整**（四项必填齐备 → 可用于签名）。
    var hasCompleteCredentials: Bool { Self.makeCredentials(from: fields) != nil }

    // MARK: 初始化

    /// 从本地持久化恢复字段（缺失 → 空串，即「未配置」）。
    ///
    /// - Parameter defaults: 偏好存储（生产 `.standard`；单测注入独立 suite）。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.fields = SourceCredentialFields(
            apiHost: defaults.string(forKey: Self.hostKey) ?? "",
            projectID: defaults.string(forKey: Self.projectIDKey) ?? "",
            developerID: defaults.string(forKey: Self.developerIDKey) ?? "",
            credentialID: defaults.string(forKey: Self.credentialIDKey) ?? "",
            privateKeyPEM: defaults.string(forKey: Self.privateKeyKey) ?? ""
        )
    }

    // MARK: 写入

    /// 保存凭据并推进版本号。
    ///
    /// ⚠️ **调用方必须先自行 `validate`** —— 本方法不做校验，
    /// 以免「保存」与「校验」两套判据各自演化（那正是本仓吃过亏的地方）。
    /// 落盘的 Host 是**规范化后**的裸主机名（与校验用的是同一个函数），
    /// 保证「界面上看到的」=「校验过的」=「落盘的」=「取数时用的」。
    ///
    /// - Parameter newFields: 待保存字段。
    func save(_ newFields: SourceCredentialFields) {
        let normalizedHost = QWeatherEndpoint.normalizeHost(newFields.apiHost)
            ?? newFields.apiHost.trimmingCharacters(in: .whitespacesAndNewlines)
        var stored = newFields
        stored.apiHost = normalizedHost
        stored.projectID = newFields.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        stored.developerID = newFields.developerID.trimmingCharacters(in: .whitespacesAndNewlines)
        stored.credentialID = newFields.credentialID.trimmingCharacters(in: .whitespacesAndNewlines)
        // ⚠️ 私钥**不做 trim**：PEM 头尾之外的空行由 Core 的解析器自行忽略
        //（`ed25519Seed(fromPKCS8PEM:)` 内部会滤掉所有空白字符），
        // 而这里 trim 掉用户可能**故意**保留的换行只会让「所见即所存」失真。

        defaults.set(stored.apiHost, forKey: Self.hostKey)
        defaults.set(stored.projectID, forKey: Self.projectIDKey)
        defaults.set(stored.developerID, forKey: Self.developerIDKey)
        defaults.set(stored.credentialID, forKey: Self.credentialIDKey)
        defaults.set(stored.privateKeyPEM, forKey: Self.privateKeyKey)

        fields = stored
        revision += 1
    }

    /// 清空全部凭据（回到「未配置」如实空态）。
    func clear() {
        for key in [Self.hostKey, Self.projectIDKey, Self.developerIDKey,
                    Self.credentialIDKey, Self.privateKeyKey] {
            defaults.removeObject(forKey: key)
        }
        fields = SourceCredentialFields()
        revision += 1
    }

    // MARK: 读取

    /// 当前凭据的 Core 注入形态。
    ///
    /// - Returns: 四项齐备 → 可用凭据；任一缺失/ 空白 → `nil`
    ///   （上层据此显示「未配置 API 凭据」，**绝不含糊成网络错误**）。
    func credentials() -> QWeatherCredentials? {
        Self.makeCredentials(from: fields)
    }

    // MARK: - 纯函数（校验与构造，好测）

    /// 字段 → `QWeatherCredentials`（**规范化 Host + 必填齐备**才返回）。
    ///
    /// - Returns: 不可用 → `nil`。
    static func makeCredentials(from fields: SourceCredentialFields) -> QWeatherCredentials? {
        guard let host = QWeatherEndpoint.normalizeHost(fields.apiHost) else { return nil }
        let projectID = fields.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentialID = fields.credentialID.trimmingCharacters(in: .whitespacesAndNewlines)
        let privateKeyPEM = fields.privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectID.isBlank, !credentialID.isBlank, !privateKeyPEM.isBlank else {
            return nil
        }
        // ⚠️ `developerID` 留空 → nil → Core 签名时不带 `iss`
        //（取值未知不编造，见 `QWeatherCredentials.developerID`）。
        let developerID = fields.developerID.trimmingCharacters(in: .whitespacesAndNewlines)
        return QWeatherCredentials(
            apiHost: host,
            projectID: projectID,
            developerID: developerID.isBlank ? nil : developerID,
            credentialID: credentialID,
            privateKeyPEM: privateKeyPEM
        )
    }

    /// 逐字段校验（**如实**：Host 复用 Core 的 `normalizeHost`，
    /// 私钥复用 Core 的 `ed25519Seed(fromPKCS8PEM:)`）。
    ///
    /// ⚠️ **绝不自己重写一套** Host / 私钥判据：
    ///   Core 里那两处是实测得出的（`normalizeHost` 只接受 https 且拒绝带路径；
    ///   `ed25519Seed` 校验 PKCS#8 长度与 Ed25519 OID 前缀）。
    ///   这里若另写一份，两处会**各自演化**，用户就会遇到
    ///   「设置页说合法、真机却 401」这种最难排查的错位。
    ///
    /// - Parameter fields: 待校验字段。
    /// - Returns: 逐字段结果。
    static func validate(_ fields: SourceCredentialFields) -> SourceCredentialValidation {
        var result = SourceCredentialValidation()

        // ① Host
        if fields.apiHost.isBlank {
            result.apiHostError = Self.hostBlankMessage
        } else if QWeatherEndpoint.normalizeHost(fields.apiHost) == nil {
            result.apiHostError = Self.hostInvalidMessage
        }

        // ② 项目 ID
        if fields.projectID.isBlank {
            result.projectIDError = Self.projectIDBlankMessage
        }

        // ③ 凭据 ID
        if fields.credentialID.isBlank {
            result.credentialIDError = Self.credentialIDBlankMessage
        }

        // ④ 私钥（PEM → Ed25519 seed，**用 Core 的真实解析器**）
        if fields.privateKeyPEM.isBlank {
            result.privateKeyError = Self.privateKeyBlankMessage
        } else {
            do {
                // 丢弃返回值：这里只要「能不能解出 32 字节 seed」这个事实。
                _ = try QWeatherTokenSigner.ed25519Seed(fromPKCS8PEM: fields.privateKeyPEM)
            } catch {
                result.privateKeyError = Self.describe(error)
            }
        }

        return result
    }

    /// 错误 → 用户可读说明（**优先用 Core 给的具体原因**）。
    ///
    /// ⚠️ 刻意**不用** `QWeatherCardModel.describe` —— 它把
    ///   `.dataMissing` 归到「暂未获取到该城市的天气数据，请确认城市后重试」，
    ///   对「私钥格式错」完全是**驴唇不对马嘴**（还会误导用户去查城市）。
    ///   这里直接把 Core 解析器写的具体原因透出来。
    static func describe(_ error: Error) -> String {
        if let weatherError = error as? WeatherError,
           case .dataMissing(let detail) = weatherError {
            return detail
        }
        return error.localizedDescription
    }

    // MARK: - 文案（单一真源；`static let` 避免 ViewBuilder 内联拼接）

    static let hostBlankMessage = "请填写 API Host（和风控制台分配，形如 xxxxxx.re.qweatherapi.com）。"
    static let hostInvalidMessage = "API Host 非法：只接受 https 主机名，"
        + "不能带路径（如 /weather）、不能是 http。控制台里整段复制即可，本页会自动去掉 https://。"
    static let projectIDBlankMessage = "请填写项目 ID（控制台项目列表里的 Project ID）。"
    static let credentialIDBlankMessage = "请填写凭据 ID。"
        + "必须是「JSON Web Token」类型凭据的 ID —— API KEY 类型的 ID 不能用于 JWT 签名。"
    static let privateKeyBlankMessage = "请填写 Ed25519 私钥（PKCS#8 PEM 全文，含 BEGIN/END 头尾）。"
}

// MARK: - 私有小工具

private extension String {
    /// 是否为「无有效内容」（空串或纯空白）。
    ///
    /// ⚠️ Core 里那份是 `private extension`（见 `QWeatherCredentials.swift`），
    ///   **跨文件不可见**，故此处另写一份同名私有工具。
    ///   这是可接受的重复：它是两行实现，且私有、不可能漂移成「两套判据」。
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 取数接线

/// 按**当前已保存凭据**取数的 `QWeatherProviding` 实现（**App 层**）。
///
/// ── 为什么需要它（这是本文件存在的一半理由）────────────────────────────
/// `QWeatherService` 在**构造时**就把凭据固化了（`private let credentials`）。
/// 而主屏的 `QWeatherCardModel` 在 `ContentView` 初始化那一刻就构造完成，
/// 那时用户**还没进设置页**、凭据必然是空的。
/// → 若直接在构造时注入，`credentials` 会**永远是 nil**：
///   真机表现就是「填了凭据、和风卡还是取不到数据」。
///
/// ── 本类型怎么解决 ────────────────────────────────────────────────────
/// 在**每次取数前**读一次当前凭据：
/// · 变了 → 用新凭据重建服务（并丢弃旧服务的 JWT 缓存）；
/// · 没变 → **复用同一个服务实例**，保住 `QWeatherTokenSigner` 的
///   token 缓存（Core 明确要求「缓存 + 按过期重签」，每次重建等于
///   把那个优化作废）。
///
/// ⚠️ 声明为 `actor`：逐日与逐时是**两条并发链路**（`async let`），
///   「读凭据 → 比对 → 重建 / 复用」这一段必须在隔离域里**原子**完成，
///   否则两个并发都可能判定「需要重建」而各建一个服务。
/// 协议 `QWeatherProviding: Sendable`，actor 天然满足。
actor QWeatherCredentialProviding: QWeatherProviding {

    /// 凭据来源（**App 层**存储；`@MainActor` 隔离，读取需 `await`）。
    private let store: SourceCredentialStore

    /// 已缓存的服务实例与其对应凭据（**同生共死**，便于整体替换）。
    private var cachedService: (any QWeatherProviding)?
    private var cachedCredentials: QWeatherCredentials?

    /// 初始化。
    ///
    /// - Parameter store: 凭据存储（生产传 `SourceCredentialStore.shared`）。
    ///
    /// ⚠️ 本`init` **刻意非隔离**（actor 的 init 默认即非隔离），
    ///   且**不在**任何 `init` 默认参数里求值 `.shared`（P-04 陷阱）。
    init(store: SourceCredentialStore) {
        self.store = store
    }

    /// 取回逐日预报（按当前凭据解析服务）。
    func fetchDaily(latitude: Double,
                    longitude: Double,
                    days: Int) async throws -> QWeatherDailyForecast {
        let service = await resolveService()
        return try await service.fetchDaily(latitude: latitude,
                                            longitude: longitude,
                                            days: days)
    }

    /// 取回逐时预报（按当前凭据解析服务）。
    ///
    /// ⚠️ 与 `fetchDaily` **完全同构**，只有端点与参数不同 ——
    ///   刻意**不复用**任何"共用的请求辅助"：一旦把两条链路抽象到一起，
    ///   逐日与逐时的差异（路径段 `hourly` vs 响应顶层键 `hours`）
    ///   就会被藏进参数里，而那正是本仓最易静默出错之处。
    func fetchHourly(latitude: Double,
                     longitude: Double,
                     hours: Int) async throws -> QWeatherHourlyForecast {
        let service = await resolveService()
        return try await service.fetchHourly(latitude: latitude,
                                            longitude: longitude,
                                            hours: hours)
    }

    // MARK: - Private

    /// 当前应使用的服务：凭据未变则复用，变了则重建。
    ///
    /// 🔴 **未配置时也要返回服务**（传 `nil` 凭据），而不是抛错 ——
    ///   这样上层 `QWeatherService` 会抛它自己的
    ///   `WeatherError.dataMissing`，卡片显示**既有的**「未配置 API 凭据」空态。
    ///   若在这里自己抛，会绕开既有文案链路、造成两套「未配置」表述。
    private func resolveService() async -> any QWeatherProviding {
        let current = await store.credentials()
        if let service = cachedService, current == cachedCredentials {
            return service
        }
        // `now` 由 App 侧显式传（Core 禁 `Date()`，SC-11；本文件在 App 层，合规）。
        let service = QWeatherService(now: { Date() }, credentials: current)
        cachedService = service
        cachedCredentials = current
        return service
    }
}

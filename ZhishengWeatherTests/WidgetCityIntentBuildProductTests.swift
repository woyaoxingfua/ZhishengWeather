//
//  WidgetCityIntentBuildProductTests.swift
//  ZhishengWeatherTests
//
//  「配置用的AppIntent 有没有真的进**两个产物**」—— 根因级回归守卫。
//
//  ── 被守卫的缺陷（2026-09 真机实测，全绿而功能是死的）────────────────────
//  现象：小组件能添加到桌面，但**永远**显示 `--°` / 空态；主 App一切正常；
//  用户在编辑界面**能正常选择城市并保存**，仍然没有数据。
//
//  根因：`WidgetCityIntent.swift`（配置三件套 `WidgetCityEntity` /
//  `WidgetCityQuery` / `WidgetCitySelectionIntent`）当时位于
//  `ZhishengWeatherWidget/` 目录 —— **只编入 widget target，主 App target
//  完全没有这些类型定义**。
//
//  为什么这会致命：系统抽取 AppIntents 元数据（供主 App 进程反序列化用户
//  **已保存**的 per-instance 配置）时，要求该 Intent 类型在**主 App 二进制里
//  也有完整定义**。缺定义 →
//    元数据里类型不完整 → 无法反序列化已保存配置
//    → `configuration.city` 永远退回默认哨兵「跟随 App」
//    → `WidgetCityResolver.followAppOutcome(container:)`
//    → 侧载产物上 App Group 容器不可用 → `.needsConfiguration`
//    → `WeatherProvider.swift:101`「无城市就不取数」→ **零网络请求** → 空态。
//
//  与`WidgetLocationBuildProductTests` / `AppIconBuildProductTests` 同族：
//  纯映射单测**永远抓不到**这类缺陷 —— 它锁的是「解析逻辑写对了」，
//  锁不住「类型有没有编进产物」。构建成功、单测全过、真机打包正确，
//  唯独小组件无数据，且不报错、不告警。
//
//  ── 守卫锚点纪律 ────────────────────────────────────────────────────────
//  锚的是**性质**「主 App 产物与 appex 产物里都能找到配置 Intent 的类型名」，
//  不锚具体文件名、不锚元数据容器的目录名（见下方「证明力边界」）。
//
//  ── 定位不到产物必须 XCTFail ─────────────────────────────────────────────
//  静默 skip 会退化成「永远为真的假绿」，那正是本类缺陷的成因。
//
//  ──⚠️ 证明力边界（务必读，勿过度依赖本测试）─────────────────────────────
//  1. 本测试断言的是**类型名出现在产物里**（bundle 内全量字节扫描）。这证明
//     「类型确实编进了该产物」，也就是上面那条根因链的**必要条件**被守住了。
//  2. 它**不能**证明「系统成功反序列化了用户已保存的配置」。后者依赖设备上
//     AppIntents 元数据抽取器的行为、以及 App Group 容器在侧载产物上是否可用
//     —— 这两件事都**只能在真机验**（本仓唯一编译门禁是 CI，验不了真机）。
//  3. 它刻意**不**断言 AppIntents 元数据容器的目录名 / 文件名：那属于 Apple
//     私有实现，跨 Xcode 版本会变；锚死它会让本测试在 Xcode 升级后**假红**，
//     而假红会把真信号一起埋掉（与 SC-40 初版「锚在文件名上」的教训同类）。
//     故采取**超集判据**：只要产物里有该类型的名字即通过，无论它落在
//     可执行文件的反射段里还是元数据载荷里。
//

import Foundation
import XCTest

final class WidgetCityIntentBuildProductTests: XCTestCase {

    // MARK: - 常量（故意硬编码：守卫要独立于被测代码）

    /// 配置 Intent 的类型名。搬回 widget 目录前，主 App 产物里**搜不到**它。
    private static let intentTypeName = "WidgetCitySelectionIntent"

    /// 配置 Intent 的实体类型名（同理，用于确认 AppEntity 侧也编进了主 App）。
    private static let entityTypeName = "WidgetCityEntity"

    /// 主 App bundle id（与 project.yml 的 PRODUCT_BUNDLE_IDENTIFIER 逐字一致）。
    private static let appBundleID = "com.zhisheng.weather"

    /// 小组件扩展 bundle id（同上）。
    private static let widgetBundleID = "com.zhisheng.weather.widget"

    /// 单文件大小上限：超过就不读（防止把超大资源拖进内存）。
    private static let maxScannableFileBytes = 64 * 1024 * 1024

    // MARK: - 1. 主 App 产物里必须有配置 Intent 的类型名

    /// 主 App 产物里必须能搜到 `WidgetCitySelectionIntent` 与 `WidgetCityEntity`。
    ///
    /// 这就是那个「全绿却功能是死的」缺陷的哨兵：类型只在 widget 二进制里时，
    /// 系统抽出的AppIntents 元数据缺定义 → 用户已保存的配置无法反序列化 →
    /// 小组件永远空态，而 CI 全绿。
    func testHostAppProductContainsCityConfigurationIntentTypes() {
        guard let app = locatedAppBundle() else { return }

        for typeName in [Self.intentTypeName, Self.entityTypeName] {
            let hits = productFilesContaining(typeName, in: app)
            XCTAssertFalse(
                hits.isEmpty,
                """
                主 App 产物（\(Self.appBundleID)）里搜不到 AppIntents 类型 \(typeName)。
                后果：系统抽取的 AppIntents 元数据缺该类型定义 → 无法反序列化用户
                **已保存**的小组件配置 → `configuration.city` 永远退回「跟随 App」哨兵
                → 走followAppOutcome → 侧载产物上 App Group 不可用 → `.needsConfiguration`
                → 「无城市就不取数」→ **零网络请求** → 小组件永远空态。
                且这一切**不报错、不告警、CI 全绿**。
                最可能的原因：`Core/Logic/WidgetCityIntent.swift` 被搬回了
                `ZhishengWeatherWidget/`（那里只编入 widget target）。
                本文件必须与 `Core/Logic/WidgetRefreshIntent.swift` 同居 Core/Logic
                —— AppIntent 需同时编进主 App 与 Widget 两个 target。
                （已扫 \(hits) 个文件均未命中。）
                """
            )
        }
    }

    // MARK: - 2. appex 产物里也必须有（搬移前的原有状态，防「搬过头」）

    /// 小组件扩展产物里必须同样能搜到这两个类型名。
    ///
    /// 方向相反的回归：若把文件搬到某个**两target 都不含**的位置（或被误删、
    /// 误加 target 排除规则），widget 自己就拿不到配置项了。这条断言保证
    /// 「搬移后两侧都在」，而不是只顾主App。
    func testWidgetExtensionProductContainsCityConfigurationIntentTypes() {
        guard let appex = locatedWidgetExtensionBundle() else { return }

        for typeName in [Self.intentTypeName, Self.entityTypeName] {
            let hits = productFilesContaining(typeName, in: appex)
            XCTAssertFalse(
                hits.isEmpty,
                """
                小组件扩展产物（\(Self.widgetBundleID)）里搜不到 \(typeName)。
                后果：`AppIntentConfiguration` 拿不到配置类型 → 编辑界面选不了城市
                （或已保存的配置无法被系统回显）。
                请检查 `Core/Logic/WidgetCityIntent.swift` 是否仍在 `Core/` 下
                （project.yml 里两个 target 的 sources 都含 `- path: Core`）。
                （已扫 \(hits) 个文件均未命中。）
                """
            )
        }
    }

    // MARK: - 3. 源码侧位置纪律：文件必须在 Core/Logic，且两个 target 都挂 Core

    /// `WidgetCityIntent.swift` 必须住在 `Core/Logic/`，且 `ZhishengWeatherWidget/`
    /// 下**不得**再有同名文件。
    ///
    /// 为什么源码侧也要钉：产物扫描能抓住「类型没进产物」，但如果只看产物，
    /// 「文件被搬走 + 恰好另一处有同名类型」这类漂移会很难排查。这里把
    /// **物理位置**本身作为被守卫的性质 —— 它正是本次根因的直接成因。
    /// （写法参照同目录 `AppIconSourceSizeGuardTests` 的 `#filePath` 上溯定位。）
    func testCityConfigurationIntentSourceLivesInCoreLogic() {
        guard let root = locatedRepositoryRoot() else { return }

        let fm = FileManager.default
        let expected = root.appendingPathComponent("Core/Logic/WidgetCityIntent.swift")
        let stale = root.appendingPathComponent("ZhishengWeatherWidget/WidgetCityIntent.swift")

        XCTAssertTrue(
            fm.fileExists(atPath: expected.path),
            "配置 Intent 必须位于 Core/Logic/WidgetCityIntent.swift（由 project.yml 自动挂入"
                + "主 App 与 Widget 两个 target）；实际找不到 \(expected.path)。"
        )
        XCTAssertFalse(
            fm.fileExists(atPath: stale.path),
            """
            \(stale.path) 又出现了 —— AppIntent 只编入 widget target 会让系统抽出的
            AppIntents 元数据缺定义，用户已保存的配置无法反序列化，小组件永远空态
            （且不报错、CI 全绿）。请把它放回 Core/Logic/。
            """
        )

        // project.yml：两个 target 的 sources 都必须含 `- path: Core`。
        // 至少两处，缺一处就意味着有一个 target 拿不到 Core。
        let spec = root.appendingPathComponent("project.yml")
        XCTAssertTrue(
            fm.fileExists(atPath: spec.path),
            "定位不到 project.yml（\(spec.path)），无法断言 Core 的target 挂载关系。"
        )
        guard let text = try? String(contentsOf: spec, encoding: .utf8) else {
            XCTFail("读不到 project.yml 内容（\(spec.path)）。")
            return
        }
        let coreMountCount = text.components(separatedBy: "- path: Core").count - 1
        XCTAssertGreaterThanOrEqual(
            coreMountCount,
            2,
            """
            project.yml 里 `- path: Core` 只出现 \(coreMountCount) 次（应≥ 2：
            主 App 与 Widget 各一次）。少一次 = 有一个 target 拿不到 Core 里的类型。
            """
        )
    }

    // MARK: - 产物定位（多候选 + id 校验，定位不到一律 XCTFail）

    /// 定位**被测主 App** bundle；定位不到返回 nil（并在此处 XCTFail）。
    ///
    /// 依据 project.yml：测试 target 设了 `TEST_HOST` / `BUNDLE_LOADER` =
    /// `ZhishengWeather.app/...`（app-hosted 单测），故 `Bundle.main` 预期即主 App。
    /// 即便如此仍走「多候选 + bundle id 校验」，避免某代 Xcode 换注入方式后
    /// 读到测试 bundle 的 Info.plist —— 那会让断言变成永远为真的假绿。
    private func locatedAppBundle() -> Bundle? {
        var candidates: [Bundle] = [Bundle.main, Bundle(for: Self.self)]

        if let plugIns = Bundle.main.builtInPlugInsURL {
            candidates.append(contentsOf: bundles(in: plugIns))
        }

        for base in [Bundle.main, Bundle(for: Self.self)] {
            var url = base.bundleURL
            for _ in 0..<6 {
                url = url.deletingLastPathComponent()
                if let bundle = Bundle(url: url) {
                    candidates.append(bundle)
                }
                candidates.append(contentsOf: bundles(in: url.appendingPathComponent("PlugIns")))
            }
        }

        if let hit = candidates.first(where: { $0.bundleIdentifier == Self.appBundleID }) {
            return hit
        }
        if let hit = candidates.first(where: {
            $0.bundleURL.pathExtension == "app"
                && $0.object(forInfoDictionaryKey: "CFBundleExecutable") != nil
        }) {
            return hit
        }

        XCTFail("""
            定位不到被测主 App bundle（期望 CFBundleIdentifier = \(Self.appBundleID)）。
            已尝试：\(candidates.map { "\($0.bundleURL.lastPathComponent)(id=\($0.bundleIdentifier ?? "nil"))" })
            请检查 project.yml 里测试 target 的 TEST_HOST / BUNDLE_LOADER 是否仍指向
            ZhishengWeather.app。若宿主关系已变，本测试的定位策略需同步更新，
            但**不许**改成 skip。
            """)
        return nil
    }

    /// 定位**被测小组件扩展（appex）** bundle；定位不到返回 nil（并在此处 XCTFail）。
    ///
    /// 依据 project.yml：主 App 声明 `- target: ZhishengWeatherWidget, embed: true`
    /// → 扩展被嵌入 `ZhishengWeather.app/PlugIns/`。
    private func locatedWidgetExtensionBundle() -> Bundle? {
        var candidates: [Bundle] = []

        if let plugIns = Bundle.main.builtInPlugInsURL {
            candidates.append(contentsOf: bundles(in: plugIns))
        }

        var url = Bundle(for: Self.self).bundleURL
        for _ in 0..<6 {
            candidates.append(contentsOf: bundles(in: url))
            url = url.deletingLastPathComponent()
            candidates.append(contentsOf: bundles(in: url.appendingPathComponent("PlugIns")))
        }

        if let hit = candidates.first(where: { $0.bundleIdentifier == Self.widgetBundleID }) {
            return hit
        }
        if let hit = candidates.first(where: { $0.bundleURL.pathExtension == "appex" }) {
            return hit
        }

        XCTFail("""
            定位不到被测小组件扩展（期望 CFBundleIdentifier = \(Self.widgetBundleID)）。
            已尝试：\(candidates.map { "\($0.bundleURL.lastPathComponent)(id=\($0.bundleIdentifier ?? "nil"))" })
            请检查 project.yml 里主 App 是否仍 `embed: true` 地依赖 ZhishengWeatherWidget。
            """)
        return nil
    }

    /// 列出某目录下的 `*.appex` bundle（目录不存在 / 读不了 → 空数组）。
    private func bundles(in directory: URL) -> [Bundle] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [])) ?? []
        return contents
            .filter { $0.pathExtension == "appex" }
            .compactMap { Bundle(url: $0) }
    }

    // MARK: - 产物字节扫描

    /// 返回 bundle 内**含指定 ASCII 字符串**的文件（相对路径），用于断言与诊断。
    ///
    /// 为什么扫全量字节而不是解析某个元数据容器：Apple 的 AppIntents 元数据
    /// 载荷格式与目录名属私有实现，跨 Xcode 版本会变；类型名在**可执行文件的
    /// 反射段**里同样以明文出现，故全量扫描是**超集判据** —— 只要类型真被编进
    /// 该产物就必然命中，且不会因Apple 改了容器名而假红。
    private func productFilesContaining(_ needle: String, in bundle: Bundle) -> [String] {
        let root = bundle.bundleURL
        let fm = FileManager.default

        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else {
            XCTFail("枚举产物内容失败：\(root.path)")
            return []
        }

        var hits: [String] = []
        for url in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            if let size = values?.fileSize, size > Self.maxScannableFileBytes { continue }

            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            guard Self.containsASCII(needle, in: data) else { continue }

            let relative = url.path.hasPrefix(root.path)
                ? String(url.path.dropFirst(root.path.count))
                : url.lastPathComponent
            hits.append(relative)
        }
        return hits
    }

    /// 在 `Data` 里查找一段 ASCII 子串（避免 `String(data:)` 把二进制整体转字符串）。
    ///
    /// 实现说明：走 `withUnsafeBytes` 逐字节比对，**不复制**整个缓冲区 ——
    /// 可执行文件动辄几十 MB，拷贝既慢又占内存。先比对首字节再逐个确认，
    /// 绝大多数位置一次比较即被排除。
    private static func containsASCII(_ needle: String, in data: Data) -> Bool {
        let pattern = Array(needle.utf8)
        guard !pattern.isEmpty else { return false }

        var found = false
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let haystack = raw.bindMemory(to: UInt8.self).baseAddress,
                  haystack.count >= pattern.count else { return }
            let first = pattern[0]
            let limit = haystack.count - pattern.count
            var index = 0
            while index <= limit {
                if haystack[index] == first {
                    var offset = 1
                    while offset < pattern.count, haystack[index + offset] == pattern[offset] {
                        offset += 1
                    }
                    if offset == pattern.count {
                        found = true
                        return
                    }
                }
                index += 1
            }
        }
        return found
    }

    // MARK: - 源码树定位（`#filePath` 上溯，参照AppIconSourceSizeGuardTests）

    /// 定位仓库根（含 `project.yml` 的那一层）；定位不到返回 nil 并 XCTFail。
    ///
    /// `#filePath` 是**编译期**绝对路径（CI 上就是 checkout 里的真实路径），
    /// 逐级上溯即可。若 Xcode 传的是相对路径，则再以进程当前目录为基准重试。
    private func locatedRepositoryRoot() -> URL? {
        let raw = #filePath
        let fm = FileManager.default

        var bases: [URL] = [URL(fileURLWithPath: raw, isDirectory: false)]
        if !raw.hasPrefix("/") {
            bases.append(URL(fileURLWithPath: fm.currentDirectoryPath)
                .appendingPathComponent(raw))
        }

        for base in bases {
            var dir = base.deletingLastPathComponent()
            for _ in 0..<8 {
                let candidate = dir.appendingPathComponent("project.yml")
                if fm.fileExists(atPath: candidate.path) {
                    return dir
                }
                dir = dir.deletingLastPathComponent()
            }
        }

        XCTFail("""
            定位不到仓库根（含 project.yml 的那一层）。
            #filePath = \(raw)；进程当前目录 = \(fm.currentDirectoryPath)。
            本守卫绝不静默跳过 —— 若源码在测试运行环境中不可达，
            请修正本文件的定位策略，而不是把断言删掉。
            """)
        return nil
    }
}
//
//  AppIconBuildProductTests.swift
//  ZhishengWeatherTests
//
//  「备用图标到底有没有进**构建产物**」——对已编译产物的断言。
//
//  ── 为什么必须有这条测试 ────────────────────────────────────────────────
//  这个缺陷的可怕之处在于**全绿**：541 个测试全过、CI 12 步全 success、
//  构建日志零告警，而功能是死的。
//
//  实测缺陷链（CI run 35217270251 @ fe5ed5c，绿色构建，产出了真正的新 IPA）：
//    1. project.yml 把两个备用图标名写成逗号串 "AppIcon-Jade,AppIcon-Rain"，
//       Xcode 把整串当成**一个**名字传给 actool（构建日志实测命令行：
//       `--alternate-app-icon AppIcon-Jade,AppIcon-Rain`）；
//    2. 该名字在 Assets.xcassets 里不存在（catalog 里是两个 appiconset：
//       AppIcon-Jade、AppIcon-Rain），actool **静默跳过**——那次 actool 调用
//       带了 `--warnings --notices`，却一条告警都没有；
//    3. 产物 Info.plist 因此**没有** CFBundleAlternateIcons 这个键，
//       `UIApplication.shared.supportsAlternateIcons` 恒为 false，
//       App 内换图标**必然**失败（用户看到的"点不动"就是这个）；
//    4. 产物 Assets.car 里也搜不到 AppIcon-Jade / AppIcon-Rain 的字节。
//
//  纯映射单测（AppIconChoiceTests）**永远抓不到**这类缺陷——它锁的是
//  「档位 → 资源名」的映射写对了，锁不住「资源名有没有进产物」。
//  actool 既不报错也不告警，唯一能抓住它的判据就是**构建产物里的键**。
//  故本文件不加任何对 project.yml 文本的断言，只读被测 App 的 Info.plist。
//

import XCTest
@testable import ZhishengWeather

final class AppIconBuildProductTests: XCTestCase {

    // MARK: - 常量

    /// 主 App 的 bundle id（与 project.yml 的 PRODUCT_BUNDLE_IDENTIFIER 逐字一致）。
    private static let appBundleID = "com.zhisheng.weather"

    /// 构建产物里必须出现的两个备用图标名（与 IconChoice.alternateIconName 同源，
    /// 但这里**硬编码**：本测试要独立于被测代码，防止「映射与资源一起改错」时
    /// 断言跟着一起漂移）。
    private static let requiredAlternateIconNames: Set<String> = [
        "AppIcon-Jade",
        "AppIcon-Rain",
    ]

    // MARK: - 定位被测主 App bundle

    /// 定位**被测主 App** 的 bundle；定位不到返回 nil（并在此处 XCTFail）。
    ///
    /// 为什么 `Bundle.main` 应当是主 App（依据来自 project.yml，不是猜的）：
    /// 测试 target 同时设了
    ///   `TEST_HOST     = $(BUILT_PRODUCTS_DIR)/ZhishengWeather.app/.../ZhishengWeather`
    ///   `BUNDLE_LOADER = $(TEST_HOST)`
    /// （project.yml 第 130–131 行）——这是**宿主式（app-hosted）单测**：
    /// 测试 bundle 被注入主 App 进程，进程的可执行文件就是主 App 的，
    /// 因此 `Bundle.main` 指向 `ZhishengWeather.app`，而不是 .xctest bundle。
    /// 注意：project.yml 里**没有** `TEST_TARGET_NAME`，宿主关系完全靠
    /// TEST_HOST + BUNDLE_LOADER 表达。
    ///
    /// 即便如此，这里仍按「多候选 + bundle id 校验」取，而不是直接信
    /// `Bundle.main`：万一某代 Xcode 的注入方式变了，读到的会是测试 bundle
    /// 的 Info.plist，那条断言就成了**永远为真的假绿**——正是我们要消灭的东西。
    /// 候选顺序：
    ///   1. `Bundle.main`（预期命中）；
    ///   2. `Bundle(for: AppIconSwitcher.self)`（主 App target 的类，其镜像即
    ///      主 App 可执行文件）；
    ///   3. 从上述两个 bundle 的路径逐级上溯（测试 bundle 位于
    ///      `ZhishengWeather.app/PlugIns/` 时，上溯两级即命中主 App）。
    /// 命中判据：`bundleIdentifier` 等于主 App 的 id；再兜底一层
    /// 「`*.app` 目录且能读到 CFBundleExecutable」。
    private func locatedAppBundle() -> Bundle? {
        var candidates: [Bundle] = [Bundle.main, Bundle(for: AppIconSwitcher.self)]
        for base in [Bundle.main, Bundle(for: Self.self)] {
            var url = base.bundleURL
            for _ in 0..<6 {
                url = url.deletingLastPathComponent()
                if let bundle = Bundle(url: url) {
                    candidates.append(bundle)
                }
            }
        }

        if let hit = candidates.first(where: { $0.bundleIdentifier == Self.appBundleID }) {
            return hit
        }
        // 兜底：bundle id 读不到（变量未替换等）时按结构匹配。
        if let hit = candidates.first(where: {
            $0.bundleURL.pathExtension == "app"
                && $0.object(forInfoDictionaryKey: "CFBundleExecutable") != nil
        }) {
            return hit
        }

        // 定位不到 = 这条守卫根本无法成立，必须**显式红**而不是静默跳过：
        // 静默 skip 会退化成"永远为真的假绿"，那正是本缺陷的成因。
        XCTFail("""
            定位不到被测主 App bundle（期望 CFBundleIdentifier = \(Self.appBundleID)）。
            已尝试的候选：\(candidates.map { "\($0.bundleURL.lastPathComponent)(id=\($0.bundleIdentifier ?? "nil"))" })
            请检查 project.yml 里测试 target 的 TEST_HOST / BUNDLE_LOADER 是否仍指向
            ZhishengWeather.app；若宿主关系已变，本测试的定位策略需同步更新。
            """)
        return nil
    }

    /// 读取主 App 产物 Info.plist 里声明的备用图标名（取并集）。
    ///
    /// 同时看 `CFBundleIcons`（iPhone）与 `CFBundleIcons~ipad`（iPad）：
    /// 本 target 的 `TARGETED_DEVICE_FAMILY = "1,2"`，actool 按设备族分别注入，
    /// 只查一个键会在另一种设备上漏判（UI 上就是"iPhone 能换、iPad 换不了"）。
    private func declaredAlternateIconNames(in app: Bundle) -> Set<String> {
        var names: Set<String> = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = app.object(forInfoDictionaryKey: key) as? [String: Any],
                  let alternates = icons["CFBundleAlternateIcons"] as? [String: Any] else {
                continue
            }
            names.formUnion(alternates.keys)
        }
        return names
    }

    // MARK: - 1. 产物里声明了两个备用图标（缺陷的直接判据）

    /// 主 App 的 Info.plist 必须声明 `CFBundleAlternateIcons`，且**同时**含两个备用名。
    ///
    /// 这条就是那个"全绿却功能是死的"缺陷的哨兵：actool 对不存在的备用图标名
    /// **静默忽略、零告警**，所以只有断言构建产物才能抓住它。
    func testBuiltAppInfoPlistDeclaresBothAlternateIcons() {
        guard let app = locatedAppBundle() else { return }
        let declared = declaredAlternateIconNames(in: app)

        XCTAssertFalse(
            declared.isEmpty,
            """
            产物 Info.plist 里没有 CFBundleAlternateIcons —— 备用图标没进构建产物。
            此时 UIApplication.shared.supportsAlternateIcons 为 false，App 内换图标必然失败。
            最可能的原因：project.yml 的 ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES
            被写回了逗号串（逗号不是多值分隔符，整串会被当成一个不存在的图标名，被 actool 静默忽略）。
            """
        )
        for name in Self.requiredAlternateIconNames {
            XCTAssertTrue(
                declared.contains(name),
                "产物 Info.plist 的 CFBundleAlternateIcons 缺少 \(name)；实际声明的是 \(declared.sorted())"
            )
        }
    }

    // MARK: - 2. 交叉一致性：代码里的映射 ⇄ 产物里的声明

    /// 遍历 `IconChoice.allCases`，每个有备用名的档位都必须在产物里被声明。
    ///
    /// 防的是「改了资源名忘了改映射」（或反之）——那种情况下 UI 能点、代码能跑、
    /// 系统调用会返回 bundleDoesNotContainAlternateIcon，用户看到的是"点了没反应"。
    /// `phosphor` 的 `alternateIconName` 是 nil（代表默认图标，系统语义就是传 nil），
    /// 不参与本断言。
    func testEveryAlternateChoiceIsDeclaredInBuiltApp() {
        guard let app = locatedAppBundle() else { return }
        let declared = declaredAlternateIconNames(in: app)

        for choice in IconChoice.allCases {
            guard let name = choice.alternateIconName else { continue }
            XCTAssertTrue(
                declared.contains(name),
                "档位 \(choice.rawValue) 映射到备用图标名 \(name)，但产物 Info.plist 的 CFBundleAlternateIcons 里没有它；实际声明的是 \(declared.sorted())"
            )
        }
    }
}

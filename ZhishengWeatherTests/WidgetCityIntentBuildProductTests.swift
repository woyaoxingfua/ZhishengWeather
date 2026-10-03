//
//  WidgetCityIntentBuildProductTests.swift
//  ZhishengWeatherTests
//
//  ⚠️⚠️ **文件名与内容不符，先读这段**（2026-09 `e65bcb9` 删用例后遗留的债）：
//  本文件名叫 `...BuildProductTests`、标题曾写「根因级回归守卫」，但**现在
//  完全不做任何 build product 检查**——只含两个纯逻辑 / 纯文本用例：
//    ① `testCitySelectionIntentDefaultMatchesDefaultQuerySentinel`
//    ② `testCityConfigurationIntentSourceLivesInCoreLogic`
//  原先还有两个「产物字节扫描」用例（扫 bundle 找类型名），它们在 CI 上
//  **编译不过**（`locatedAppBundle()` / `bundles(in:)` 的类型推断塌成 `[Any]`，
//  加 `withUnsafeBytes` 指针代码），已在 `e65bcb9` 中**整体删除**。
//  → **产物级验证仍是已知缺口**，本文件**没有**覆盖它。若要恢复，需重写而非
//  复原（且请优先用「读 Info.plist / 用 grep 找符号」这类不需要 `bindMemory`
//  的写法）。文件名暂留以免搅动提交历史，**但请勿据名推断本文件查产物**。
//
//  ── 被守卫的缺陷（2026-09 真机实测，全绿而功能是死的）────────────────────
//  现象：小组件能添加到桌面，但**永远**显示 `--°` / 空态；主 App 一切正常；
//  用户在编辑界面**能正常选择城市并保存**，仍然没有数据。
//
//  ⚠️ **归因更正（重要，勿再沿用旧说法）**：曾把根因记作「配置 Intent 位于
//  `ZhishengWeatherWidget/`、只编入 widget target，主 App 缺定义」。
//  **该归因已被证伪**：
//  · `WidgetRefreshIntent` 需要进主 App target，理由是 `openAppWhenRun = true`
//  （系统在主 App 进程执行 perform()）；
//  · 而 `WidgetCitySelectionIntent` 是 `WidgetConfigurationIntent`，**没有**
//    `openAppWhenRun`，只在 **widget 进程**里被反序列化 —— 上面那条纪律
//    **不适用于**它，按同一条处理属过度泛化；
//  · 且该归因**解释不了**「用户能选、能保存」（若类型定义缺失，选择器本身就该坏）。
//
//  ✅ 当前最强候选根因（**用例①** 守着它的不变式）：`WidgetCitySelectionIntent`
//  **缺 initializer** → 系统读回 per-instance 配置时退回
//  `defaultQuery.defaultResult()` 哨兵 →「用户选了什么都被静默替换成默认值」
//  → 零网络请求 → 永久空态。
//  ⚠️ 仍**未在真机验证**（本仓唯一编译门禁是 CI，验不了真机）。
//
//  与 `WidgetLocationBuildProductTests` / `AppIconBuildProductTests` 同族：
//  纯映射单测**永远抓不到**「值读回来变了」这类缺陷 —— 它锁的是「解析逻辑
//  写对了」，锁不住「系统读回的值是不是用户选的那个」。构建成功、单测全过、
//  真机打包正确，唯独小组件无数据，且不报错、不告警。
//
//  ── 守卫锚点纪律 ────────────────────────────────────────────────────────
//  锚的是**性质**：「默认配置解析出来的必须是用户可见的那个哨兵」、
//  「哨兵 id 必须被判为 `.followApp`（分类点）」、「容器空时必须如实要配置」、
//  以及「配置 Intent 的源码位置仍在 `Core/Logic/`」。**不锚具体文件名**。
//
//  ── ⚠️ 证明力边界（务必读，勿过度依赖本测试）─────────────────────────────
//  1. 两个用例都是**纯逻辑 / 纯文本断言**：它们锁定「默认值与回退值同口径」
//     「哨兵分类正确」「容器空不注入默认城市」「源码位置未漂移」。
//  2. 它们**不能**证明真机上系统真的会用这个 `init` 去反序列化配置
//     —— 那取决于设备上的 AppIntents 运行时，**只能真机验**。
//  3. 本文件**不覆盖**产物级验证（见文首「已知缺口」）。
//

import Foundation
import XCTest
@testable import ZhishengWeather

final class WidgetCityIntentBuildProductTests: XCTestCase {

    // ⚠️ **已知缺口（本文件已移除产物字节扫描，见文件头「归因与缺口」段）**：
    // 曾尝试扫描主 App / appex 产物、断言两个 Intent 类型名编进了两侧 —— 那是唯一
    // 能直接验证「主 App bundle 也含该 Intent 元数据」的手段。该实现依赖
    // FileManager enumerator 的 resourceValues 与 withUnsafeBytes 指针 API，
    // 在本机无 Xcode 的条件下写就，CI 编译不通过
    // （`value of type 'Any' has no member 'resourceValues'` 等 6 处 error）。
    // 现改为只保留下面两条**纯逻辑 / 纯文本**断言，它们几乎不可能假红：
    //   1) `testCitySelectionIntentDefaultMatchesDefaultQuerySentinel` —— 缺 init 的静默回退防线
    //   2) `testCityConfigurationIntentSourceLivesInCoreLogic`      —— 防文件漂移 + 两侧挂载
    // 代价：**「主 App bundle 也含该 Intent 元数据」这条性质目前无自动守卫**，
    // 只能靠第 2 条的源码位置断言间接兜住。若将来有人在别处找到可复用的、
    // 已在 CI 上跑通的构建产物定位办法（参见同目录 `WidgetLocationBuildProductTests.swift`
    // 与 `AppIconBuildProductTests.swift`），应优先把字节扫描加回来。

    // MARK: - ① 配置 Intent 的默认值不变式（缺 init 的静默回退防线）

    /// `WidgetCitySelectionIntent()` 的默认 city 必须是 `followApp` 哨兵。
    ///
    /// ── 为什么这条最贴近「用户能选、能保存、却读回默认值」─────────────────
    /// 非可选 `@Parameter` 且无 `default:` 时，Apple 要求默认值由 intent 的
    /// **initializer** 提供。缺 init → 系统反序列化 per-instance 配置时退回
    /// `WidgetCityQuery.defaultResult()`（也就是 `followApp` 哨兵），
    /// **用户选了什么都被静默替换**。
    /// 链：`city.id == followAppID` → `mode(forEntityID:)` 判 `.followApp`
    /// → `followAppOutcome(container:)`（侧载容器 `selectedID` 恒 nil）
    /// → `.needsConfiguration` → `WidgetDataResolver`「无城市就不取数」
    /// → **零网络请求** → 小组件永远 `--°` / 「暂无数据」。
    /// 而选择器本身工作正常（用户**能**选**能**保存），这正是该缺陷的特征签名。
    ///
    /// 本条同时锁住三处默认值**同口径**（init / defaultQuery / backgroundStyle
    /// 的 `default:`），任一漂移都会让「配置界面显示的默认」与「实际回退值」不一致。
    func testCitySelectionIntentDefaultMatchesDefaultQuerySentinel() async {
        let intent = WidgetCitySelectionIntent()

        XCTAssertEqual(
            intent.city.id,
            WidgetCityEntity.followAppID,
            """
            `WidgetCitySelectionIntent()` 的默认 city 不是「跟随 App」哨兵。
            若默认值与 `WidgetCityQuery.defaultResult()` 不同口径，用户在配置界面
            看到的默认项会与系统实际回退的值不一致（易被当成"保存没生效"）。
            哨兵唯一真源是 `WidgetCityResolver.followAppID`，全仓禁写 "follow-app" 字面量。
            """
        )
        XCTAssertEqual(
            intent.backgroundStyle,
            .glass,
            "默认底色必须是「玻璃」（与 `@Parameter(default:)` 及 A1 前视觉一致）。"
        )

        // 哨兵必须真的解析成「跟随 App」，而不是被当成一个城市 id（`.fixed`）。
        // 这是本缺陷的**唯一分类点**：mode 判错 → 整条链走偏。
        XCTAssertEqual(
            WidgetCityResolver.mode(forEntityID: intent.city.id),
            .followApp,
            "默认 city 的 id 必须被 `WidgetCityResolver.mode(forEntityID:)` 判为 `.followApp`；"
                + "若被判成 `.fixed(cityID:)`，说明哨兵 id 漂移，回退链会走错分支。"
        )

        // 容器**空**（`cities: []` + `selectedID: nil`）时，默认配置必须**如实**要配置，
        // 而不是静默塞一个城市（或北京）—— 幽灵北京回归防线。
        // ⚠️ 别把「容器空」与「容器不可用」混为一谈（`containerAvailable` 正是这个维度）：
        //   · 本例传 `containerAvailable: true` = 容器**可用但里面啥也没有**
        //     （与 `WidgetCityResolverTests.testFollowAppWithEmptyContainerYields
        //     NoCityInsteadOfGhostBeijing` 同口径）；
        //   · 侧载渠道上的常态是 `containerAvailable: false`（App Group 不可用）。
        // 断言在**两种情况下都成立**，因为 `followAppOutcome` 只看 `selectedID`
        // 与 `cities`，**不看** `containerAvailable` —— 故这里取哪个值都能守住
        // 「不注入默认城市」这条性质。
        let outcome = await WidgetCityResolver.resolveOutcome(
            selection: WidgetCitySelection(id: intent.city.id,
                                           name: intent.city.name,
                                           subtitle: intent.city.subtitle),
            container: WidgetContainerSnapshot(cities: [], selectedID: nil,
                                               containerAvailable: true),
            builtIn: WidgetBuiltInCities.cities,
            location: { .notAuthorized })
        XCTAssertEqual(
            outcome,
            .needsConfiguration,
            """
            容器**空**（`cities: []` + `selectedID: nil`，无论 `containerAvailable`
            取值）+ 默认哨兵配置时，`resolveOutcome` 必须返回 `.needsConfiguration`
            （`city == nil`），让 UI 如实显示「未选择城市」。
            若这里解析出城市，等于凭空注入默认城市（幽灵北京）。
            outcome=\(outcome)
            """
        )
    }

    // MARK: - ② 源码侧位置纪律：文件必须在 Core/Logic，且两个 target 都挂 Core

    /// `WidgetCityIntent.swift` 必须住在 `Core/Logic/`，且 `ZhishengWeatherWidget/`
    /// 下**不得**再有同名文件。
    ///
    /// ⚠️ 位置纪律的**理由已修正**（见文件头）：本文件住Core 的**真正**理由是
    /// 「与 `WidgetRefreshIntent.swift` 同路径同惯例 + 两 target 共享 Core 的
    /// 组织方式」，**不是**「配置 Intent 必须进主 App target」（那条不成立）。
    /// 但**双向**断言仍要保留：搬走会让 widget 侧拿不到配置类型，搬回
    /// `ZhishengWeatherWidget/` 会让两侧编译输入不一致 —— 两者都是静默失败。
    /// （写法参照同目录 `AppIconSourceSizeGuardTests` 的 `#filePath` 上溯定位。）
    func testCityConfigurationIntentSourceLivesInCoreLogic() {
        guard let root = locatedRepositoryRoot() else { return }

        let fm = FileManager.default
        let expected = root.appendingPathComponent("Core/Logic/WidgetCityIntent.swift")
        let stale = root.appendingPathComponent("ZhishengWeatherWidget/WidgetCityIntent.swift")

        XCTAssertTrue(
            fm.fileExists(atPath: expected.path),
            "配置 Intent 必须位于 Core/Logic/WidgetCityIntent.swift（与 "
                + "WidgetRefreshIntent.swift 同路径同惯例，由 project.yml 挂入两个 target）；"
                + "实际找不到 \(expected.path)。"
        )
        XCTAssertFalse(
            fm.fileExists(atPath: stale.path),
            """
            \(stale.path) 又出现了。若配置 Intent 只编入 widget target，两个 target 的
            编译输入就不一致（widget 侧有、主 App 侧无）—— 这类漂移不报错、不告警、
            CI 全绿。请把它放回 Core/Logic/。
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
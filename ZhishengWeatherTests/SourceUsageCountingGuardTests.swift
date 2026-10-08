//
//  SourceUsageCountingGuardTests.swift
//  ZhishengWeatherTests
//
//  「设置 → 多源管理 → 今日用量」的机械守卫（2026-10-09）。
//
//  ── 这批测试防的是什么病 ────────────────────────────────────────────────
//  线上症状：**所有数据源的「今日用量」长期显示 0**。根因是两层叠加：
//    ① **计数侧**：`SourceHealthTracker.recordSuccess` 只在
//       `SourceAttributionCoordinator.refresh` 一处被调用，而该协调器只服务
//       3 个辅助源 → 其余 8 个源**永远没有自增路径**；
//    ② **显示侧**：`snapshot()` 把无记录兜底成 `?? 0`，于是「压根没接入」
//       与「接入了但今天真的一次没成功」显示成同一个 0，**互相冒充**。
//
//  ── 为什么这类缺陷必须钉成机械守卫 ─────────────────────────────────────
//  它的失效方式**全是静默的**：编译通过、运行时无异常、CI 全绿，
//  只有真机打开设置页才看得见，而且那一眼很容易被当成「今天网络不好」。
//  本仓反复出现的正是这类「哑火接线」（见 `SourceDescriptor` 文件头
//  关于 `openMeteoAirQuality` 静默丢失的记述），故必须机械拦住。
//
//  ── 守卫锚的是「性质」，不是符号名 ─────────────────────────────────────
//  · 「声明 `countsUsage == true` 的源，**必须**能在代码里找到它的计数调用点」
//    → 防「声明了却没接线」重新发生；
//  · 「计数只在**成功**路径自增，失败路径绝不加」
//    → 防数字虚高（那比显示 0 更有害：它会让用户以为网络在被消耗）；
//  · 「未接入的源**不得**出现在计数守卫的覆盖清单里却被静默跳过」
//    → 防守卫自身退化为恒真。
//
//  不联网、不读真实时钟（时刻全部注入）。
//

import XCTest
import Foundation
@testable import ZhishengWeather

final class SourceUsageCountingGuardTests: XCTestCase {

    // MARK: - 1. 声明了 countsUsage 就必须真的有调用点

    /// **本批的核心守卫**：`countsUsage == true` 的每个源，仓库里都必须存在
    /// 对它调用 `recordSuccess` 的真实代码路径。
    ///
    /// ⚠️ 为什么用**扫源码**而不是靠构造每个源去跑一遍：
    /// 真实取数要联网，而这些源的调用点分散在 4 个不同文件
    /// （`WeatherViewModel` / `FloodCardModel` / `TyphoonCardModel` /
    /// `QWeatherCardModel` / `EarthquakeCardModel`）。
    /// 扫源码锚的是「**存在一条自增路径**」这条性质 ——
    /// 将来有人把某个源的计数调用删了、或改了源 id 而忘了改描述符声明，
    /// 本测试立刻红。这正是原病灶的机械形态。
    ///
    /// 扫描范围限定在**主 App 层目录**（计数必须落在 App 层：
    /// Core 层不得读 UserDefaults，见本仓 SC-42a 纪律）。
    func testEverySourceDeclaredAsCountedHasAnIncrementationCallSite() throws {
        let appDir = Self.repositoryRoot() + "/ZhishengWeather"
        let files = try Self.swiftFiles(in: appDir)
        XCTAssertFalse(files.isEmpty, "未在 \(appDir) 找到任何 .swift 文件 —— 守卫退化为恒真")

        // 目录里没出现过的源码片段全文（用于跨行匹配调用点）。
        //
        // 🔴 `String(contentsOfFile:)` **会抛**，`map` 只在 `rethrows` 闭包里
        // 才替我们转发错误 —— 此处是**普通 map 闭包**（非 rethrows），
        // 故必须**逐元素显式 `try`**。
        // 漏掉时报 `call can throw but is not marked with 'try'`
        //（CI run#37770782331 实测，第 59行）。
        let corpus = try files.map { path in
            (path: path, text: try String(contentsOfFile: path, encoding: .utf8))
        }
        let joined = corpus.map(\.text).joined(separator: "\n")

        for descriptor in SourceDirectory.all where descriptor.countsUsage {
            // 两种合法接线形态：
            //  ① 直接点名：`recordSuccess(.openMeteoForecast, at: ...)`
            //  ② 间接接线：`SourceAttributionCoordinator.refresh` 遍历辅助源时
            //     调`health.recordSuccess(source.id, ...)`，其中
            //     `source.id` 是**运行期值**，源码里查不到字面量。
            //     对这类源，判据是「它出现在协调器服务的辅助源清单里」。
let directCallSite = "recordSuccess(."
                + Self.sourceIDCaseName(descriptor.id)
            let indirectAuxSource = Self.isServedByAttributionCoordinator(descriptor.id)

            if joined.contains(directCallSite) || indirectAuxSource {
                continue
            }

            XCTFail("""
                源 \(descriptor.id.rawValue) 在描述符里声明了 countsUsage = true，
                但仓库里既没有它的 `recordSuccess(.\(Self.sourceIDCaseName(descriptor.id)), ...)` \
                计数调用点，它也不在 SourceComposition 的辅助源清单里。
                ⇒ 它会在设置页显示「0 次」却永远不会被加一 —— \
                这正是「数据源调用次数全为 0」那类静默哑火。
                修法二选一：① 在真实取数成功处补上recordSuccess 调用；\
                ② 若该源确实不计数，把 countsUsage 改成 false（UI 会显示「未接入」）。
                """)
        }
    }

    /// 反面守卫：**不得**出现「宣称不计数、却有计数调用点」的源。
    ///
    /// 这是上一条的反向对称 —— 若某源 `countsUsage == false` 却仍被自增，
    /// 说明 UI 会一直显示「未接入」而数字在背后涨，是**另一种谎报**
    /// （用户以为没在用这个源）。
    func testNoSourceDeclaresNotCountedWhileHavingCallSites() throws {
        let appDir = Self.repositoryRoot() + "/ZhishengWeather"
        let files = try Self.swiftFiles(in: appDir)
        // ⚠️ 同上：闭包内 `String(contentsOfFile:)` 会抛，
        // 这里用 `try` 显式转发（外层方法已标 `throws`）。
        let joined = try files
            .map { try String(contentsOfFile: $0, encoding: .utf8) }
            .joined(separator: "\n")

        for descriptor in SourceDirectory.all where !descriptor.countsUsage {
            let callSite = "recordSuccess(." + Self.sourceIDCaseName(descriptor.id)
            XCTAssertFalse(joined.contains(callSite),
                           "源 \(descriptor.id.rawValue) 声明 countsUsage = false（UI 会显示"
                           + "「未接入」），却有计数调用点 \(callSite) —— 声明与实际不一致")
        }
    }

    // MARK: - 2. 计数语义：成功 +1 / 失败不变

    /// 成功路径 `recordSuccess` → 用量 +1，且 `lastSuccessAt` 被推进。
    ///
    /// 🔴 本方法签名原本是 `async`（**漏了 `throws`**）而函数体里用了 `try` →
    /// 编译器报「errors thrown from here are not handled」且**报错行指向函数体内**
    /// （第 126 行那几处），不是签名行 —— 排查时容易误以为是别的问题。
    /// （CI run#37770782331 实测）
    func testRecordSuccessIncrementsUsageByExactlyOne() async throws {
        let (tracker, cleanup) = try Self.makeTracker()
        defer { cleanup() }
        let now = Date()

        await tracker.recordSuccess(.usgsEarthquake, at: now)
        var rows = await tracker.snapshot(now: now)
        var row = try Self.row(for: .usgsEarthquake, in: rows)
        XCTAssertEqual(row.todayUsage, 1, "一次成功后用量应为 1")
        XCTAssertEqual(row.lastSuccessAt, now)

        await tracker.recordSuccess(.usgsEarthquake, at: now)
        rows = await tracker.snapshot(now: now)
        row = try Self.row(for: .usgsEarthquake, in: rows)
        XCTAssertEqual(row.todayUsage, 2, "两次成功后用量应为 2")
    }

    /// **失败绝不加**（EV-3 与 EV-1 都不得污染用量计数）。
    ///
    /// ⚠️ 这是「数字虚高」的反面守卫：若失败也自增，设置页的数字会随
    /// 网络恶化而**上涨**，用户会得到完全相反的结论。
    func testFailuresNeverIncrementUsage() async throws {
        let (tracker, cleanup) = try Self.makeTracker()
        defer { cleanup() }
        let now = Date()

        // 先成功一次，确认基线。
        await tracker.recordSuccess(.usgsEarthquake, at: now)
        let before = try Self.row(for: .usgsEarthquake,
                                  in: await tracker.snapshot(now: now))
        XCTAssertEqual(before.todayUsage, 1)

        // 各种失败：EV-3 状态码（401 / 429）、EV-1 缺字段。
        _ = await tracker.recordHTTPStatus(.usgsEarthquake, status: 401, at: now)
        _ = await tracker.recordHTTPStatus(.usgsEarthquake, status: 429, at: now)
        _ = await tracker.recordMissingFields(.usgsEarthquake, missing: [.temperature], at: now)

        let after = try Self.row(for: .usgsEarthquake,
                                 in: await tracker.snapshot(now: now))
        XCTAssertEqual(after.todayUsage, 1, "失败路径绝不能让用量上涨")
    }

    /// 从未被记录过的源 → `todayUsage == nil`（**不是 0**）。
    ///
    /// ⚠️ 这是显示侧修复的基石：UI 靠 `nil` 显示「未接入」，
    /// 若这里退化成 0，「未接入」就永远显示不出来。
    func testUnrecordedSourceYieldsNilNotZero() async throws {
        let (tracker, cleanup) = try Self.makeTracker()
        defer { cleanup() }
        let now = Date()

        let rows = await tracker.snapshot(now: now)
        let row = try Self.row(for: .usgsEarthquake, in: rows)
        XCTAssertNil(row.todayUsage,
                     "无任何记录时必须是 nil（= 未接入 / 无记录），"
                     + "退化成 0 会让 UI 把「未接入」显示成「0 次」")
    }

    // MARK: - 3. 文案与占比：两套说法 + 分母只含已接入源

    /// ⚠️ 本测试标了 `@MainActor`：`SettingsView` 整体是 `@MainActor`
    /// （P-06），故其 `static func usageText` **同样带 MainActor 隔离**
    /// （本仓 P-06b 教训：类型级 `@MainActor` 会传染到 static 成员）。
    /// 在非隔离的同步测试方法里直接调用它**编译不过**。
    /// 「0 次」与「N 次」两条分支的字面输出（**已接入**的那些源）。
    ///
    /// ⚠️ 「未接入」分支**不在这里测**：它由 `SourceDescriptor.countsUsage`
    /// 驱动，而当前目录里 11 个源**全部** `countsUsage == true`（都已接线）
    /// —— 目录中**不存在**能触发该分支的源。擅自把某个真实源改成 `false`
    /// 来造测试条件 = **为了让测试通过而谎报生产状态**，是本仓最忌讳的做法，
    /// 故不做。该分支由下面 `testUsageShareIsComputedForSourcesDeclaredAsCounted`
    /// 侧面锚住（见该测试注释）。
    @MainActor
    func testUsageTextRendersCountWhenSourceIsWired() {
        // ① 已接入 + 无记录 → 「0 次」（如实：确实一次都没成功过）。
        let wiredNoRecord = SourceStatusRow(id: .usgsEarthquake,
                                            displayName: "USGS 地震",
                                            state: .standby,
                                            lastSuccessAt: nil,
                                            todayUsage: nil)
        XCTAssertEqual(SettingsView.usageText(for: wiredNoRecord), "0 次",
                       "已接入但无记录 → 「0 次」（这是如实的，不是谎报）")

        // ② 已接入 + 有记录 → 「N 次」。
        let wiredWithRecord = SourceStatusRow(id: .usgsEarthquake,
                                              displayName: "USGS 地震",
                                              state: .standby,
                                              lastSuccessAt: Date(),
                                              todayUsage: 7)
        XCTAssertEqual(SettingsView.usageText(for: wiredWithRecord), "7 次",
                       "已接入且有记录 → 「N 次」")

        // 🔴 关键：`nil`（无记录）**不得**被渲染成「未接入」——
        // 那会把「接入了但今天一次没成功」误报成「压根没接线」，
        // 是与原 bug **方向相反**的另一种谎报。两套文案必须各归各的。
        XCTAssertNotEqual(SettingsView.usageText(for: wiredNoRecord), "未接入",
                          "nil（无记录）不等于未接入 —— 两者含义相反，绝不可混同")
    }

    /// 占比条**只对已接入计数的源**绘制（`usageShare` 返回 nil = 未接入）。
    ///
    /// ⚠️ 诚实说明本条的**当前局限**：目录里 11 个源全部 `countsUsage == true`，
    /// 所以「返回 nil」这一侧现在**恒真**（守不到任何东西）。记在这里是为了
    /// 不让后人误以为它在守着未接入的源。
    /// 等真出现 `countsUsage == false` 的源时，本条即变成真实守门。
    /// 这里能钉住的是**另一侧**：判据**没有**把所有源一律当成未接入
    ///（否则 UI 会一个占比条都不画，且这个错误是静默的）。
    func testUsageShareIsComputedForSourcesDeclaredAsCounted() {
        let row = SourceStatusRow(id: .usgsEarthquake,
                                  displayName: "USGS 地震",
                                  state: .standby,
                                  lastSuccessAt: nil,
                                  todayUsage: 3)
        XCTAssertNotNil(SourceHealthTracker.usageShare(for: row, total: 3),
                        "已声明 countsUsage 的源必须能算出占比 —— "
                        + "若这里为 nil，说明判据把所有源都当成未接入了")
    }

    /// 占比只由**已接入计数**的源构成；未接入的源返回 nil（UI 不画条）。
    func testUsageShareIsNilForSourcesWithoutRecordsAndZeroTotal() {
        let row = SourceStatusRow(id: .usgsEarthquake,
                                  displayName: "USGS 地震",
                                  state: .standby,
                                  lastSuccessAt: nil,
                                  todayUsage: 3)
        // 合计为 0 → 无占比（除零守卫）。
        XCTAssertNil(SourceHealthTracker.usageShare(for: row, total: 0))
        // 有合计 → 正常占比（3 / 6 = 0.5）。
        let share = SourceHealthTracker.usageShare(for: row, total: 6)
        XCTAssertNotNil(share, "有合计且已接入 → 必须能算出占比")
        XCTAssertEqual(share ?? 0, 0.5, accuracy: 0.0001)
        // 无记录 → 不画条。
        let noRecord = SourceStatusRow(id: .usgsEarthquake,
                                       displayName: "USGS 地震",
                                       state: .standby,
                                       lastSuccessAt: nil,
                                       todayUsage: nil)
        XCTAssertNil(SourceHealthTracker.usageShare(for: noRecord, total: 6))
    }

    /// 合计只累加**有记录**的源；全空 → 0。
    func testTotalCountedUsageSumsOnlyRecordedSources() {
        let rows = [
            SourceStatusRow(id: .openMeteoForecast, displayName: "A", state: .standby,
                            lastSuccessAt: nil, todayUsage: 4),
            SourceStatusRow(id: .usgsEarthquake, displayName: "B", state: .standby,
                            lastSuccessAt: nil, todayUsage: 6),
            SourceStatusRow(id: .qWeather, displayName: "C", state: .standby,
                            lastSuccessAt: nil, todayUsage: nil)
        ]
        XCTAssertEqual(SourceHealthTracker.totalCountedUsage(rows: rows), 10,
                       "合计 = 4 + 6（nil 记作 0 参与求和，但该源仍画不出条）")
        XCTAssertEqual(SourceHealthTracker.totalCountedUsage(rows: []), 0)
    }

    /// 每个源都必须出现在 `SourceCatalog`（设置页目录）里，且 id 不重复。
    ///
    /// ⚠️ 这条是「计数守卫」本身的**前提守卫**：若 `SourceDirectory.all` 与
    /// `SourceCatalog.all` 不同步，本文件里所有基于目录的断言都会**锚在
    /// 错误的集合上**（例如一个源有计数调用点却不在目录里 → UI 根本不显示它，
    /// 计数白做）。故先把「目录 ↔ 展示目录」的双射钉住。
    func testSourceDirectoryAndCatalogStayInSync() {
        let directoryIDs = SourceDirectory.all.map(\.id)
        XCTAssertFalse(directoryIDs.isEmpty, "源目录为空 —— 本文件所有守卫都会退化为恒真")
        XCTAssertEqual(Set(directoryIDs).count, directoryIDs.count,
                       "源目录里有重复 id —— 设置页会渲染出重复行")

        let catalogIDs = Set(SourceCatalog.all.map(\.id))
        for id in directoryIDs {
            XCTAssertTrue(catalogIDs.contains(id),
                          "源 \(id.rawValue) 在 SourceDirectory 里但不在 SourceCatalog 里"
                          + " —— 设置页不会显示它，它的计数也就无人可见")
        }
    }

    // MARK: - Helpers

    /// 造一个隔离 UserDefaults 的 tracker（不污染 `.standard`）。
    private static func makeTracker() throws -> (SourceHealthTracker, () -> Void) {
        let name = "zs.test.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        let tracker = SourceHealthTracker(ledger: SourceHealthLedger(defaults: d),
                                          preferences: SourcePreferences(defaults: d))
        return (tracker, { d.removePersistentDomain(forName: name) })
    }

    /// 从快照里取某源的行（缺失即 fail，附源清单便于定位）。
    private static func row(for id: SourceID, in rows: [SourceStatusRow]) throws -> SourceStatusRow {
        try XCTUnwrap(rows.first { $0.id == id },
                      "快照里没有源 \(id.rawValue) —— SourceCatalog 与 SourceID 不同步")
    }

    /// `SourceID` 的 Swift case 名（用于扫源码找字面量调用点）。
    ///
    /// ⚠️ `SourceID` 的 rawValue 是**连字符串**（`"usgs-earthquake"`），
    /// 而代码里写的是 **case 名**（`.usgsEarthquake`）—— 两者不同，故必须转换。
    private static func sourceIDCaseName(_ id: SourceID) -> String {
        // `String(describing:)` 对无关联值的 enum case 返回 case 名本身。
        String(describing: id)
    }

    /// 该源是否在 `SourceComposition` 的辅助源清单里（协调器服务对象）。
    private static func isServedByAttributionCoordinator(_ id: SourceID) -> Bool {
        SourceComposition.makeAuxiliarySources().contains { $0.id == id }
    }

    /// 递归列出目录下的 `.swift` 文件。
    private static func swiftFiles(in dir: String) throws -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else {
            XCTFail("无法枚举目录 \(dir)")
            return []
        }
        var result: [String] = []
        for case let rel as String in en where rel.hasSuffix(".swift") {
            result.append(dir + "/" + rel)
        }
        return result
    }

    /// 仓库根目录（`#filePath` 向上两级）。
    private static func repositoryRoot() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }
}
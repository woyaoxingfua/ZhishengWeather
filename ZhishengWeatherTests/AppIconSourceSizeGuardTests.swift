//
//  AppIconSourceSizeGuardTests.swift
//  ZhishengWeatherTests
//
//  「备用图标有没有把 iOS 真正要用的尺寸做出来」——对**源码资源**的断言。
//
//  ── 为什么必须有这条守卫 ────────────────────────────────────────────────
//  2026-09-17 真机缺陷：换图标不是"点不动"，而是 `supportsAlternateIcons`
//  **等于 true**（Info.plist 里 `CFBundleAlternateIcons` 声明确实在）、点下去却
//  回调报错失败。追到最后是资源层的问题：
//
//    · Assets.xcassets 里两个备用图标集 AppIcon-Jade / AppIcon-Rain 的
//      Contents.json **只有一条** 记录：`1024x1024 / universal`（App Store 槽位）；
//    · 构建产物里 Xcode 只给**主图标**补了散图（`AppIcon60x60@2x.png`、
//      `AppIcon76x76@2x~ipad.png`），`CFBundlePrimaryIcon.CFBundleIconFiles`
//      如实引用它们，所以 homemenu 上的主图标是正常的；
//    · 备用图标**没有任何散图**，只有 `CFBundleIconName` 指向资源目录，
//      而资源目录里缺少 iPhone 各档的实际 rendition → 系统取图失败 → 回调报错。
//
//  这条缺陷**全绿**：已有 `AppIconBuildProductTests` 只断言「Info.plist 里有没有
//  声明」，那条当时是绿的（声明确实在）；映射单测也是绿的（名字确实对得上）。
//  缺的是「尺寸有没有做出来」这一层，故本守卫锚在**资源描述本身**上。
//
//  ── 守卫锚点纪律 ────────────────────────────────────────────────────────
//  锚的是「每个备用图标集必须含下列 (idiom, size, scale) 记录，且引用文件存在」
//  这条**性质**，不锚具体文件名、也不锚记录总数（将来补/删尺寸都不该红，
//  但把 dx 尺寸退化回"只有一张 1024"必须红）。
//
//  ── 定位源码目录 ────────────────────────────────────────────────────────
//  `#filePath` 是**编译期**绝对路径（CI 上就是 checkout 里的真实路径），逐级上溯
//  找到含 `Assets.xcassets` 的目录即可。若 Xcode 传的是相对路径，则再退一步以
//  进程当前目录为基准重试。
//
//  定位不到必须 **XCTFail**，绝不静默 skip —— 静默 skip 会退化成"永远为真的假绿"，
//  那正是本类缺陷的成因（见同目录
//  `AppIconBuildProductTests` 文件头的实测缺陷链）。
//

import XCTest
import Foundation

final class AppIconSourceSizeGuardTests: XCTestCase {

    // MARK: - 常量（故意硬编码：本守卫要独立于被测代码）

    /// 必须被检查的备用图标集名（与 Core 的 `IconChoice.alternateIconName` 同源，
    /// 但此处硬编码，防止「映射与资源一起改错」时断言跟着漂移）。
    private static let alternateIconSetNames: [String] = ["AppIcon-Jade", "AppIcon-Rain"]

    /// iOS 真正会去取的 rendition 规格：(idiom, size, scale)。
    ///
    /// 取的是 Apple 官方 appiconset 尺寸矩阵里**不可缺省**的那部分：
    /// iPhone 的通知(20) / 设置(29) / Spotlight(40) / 主屏(60)，iPad 的主屏(76/83.5)。
    /// 只放 1024 universal（App Store 槽位）无法满足 runtime 取图。
    private static let requiredSpecs: [(idiom: String, size: String, scale: String)] = [
        ("iphone", "20x20", "2x"),
        ("iphone", "20x20", "3x"),
        ("iphone", "29x29", "2x"),
        ("iphone", "29x29", "3x"),
        ("iphone", "40x40", "2x"),
        ("iphone", "40x40", "3x"),
        ("iphone", "60x60", "2x"),
        ("iphone", "60x60", "3x"),
        ("ipad", "76x76", "1x"),
        ("ipad", "76x76", "2x"),
        ("ipad", "83.5x83.5", "2x"),
    ]

    // MARK: - 源码资源定位

    /// 定位仓库根（含 `Assets.xcassets` 的那一层）；定位不到返回 nil 并 XCTFail。
    ///
    /// - Returns: 根目录 URL。
    private func locatedRepositoryRoot() -> URL? {
        let raw = #filePath
        let fm = FileManager.default

        // 候选基准：① #filePath 本身（常见是绝对路径）；
        //           ② 相对路径时以进程当前目录拼接。
        var bases: [URL] = [URL(fileURLWithPath: raw, isDirectory: false)]
        if !raw.hasPrefix("/") {
            bases.append(URL(fileURLWithPath: fm.currentDirectoryPath)
                .appendingPathComponent(raw))
        }

        for base in bases {
            var dir = base.deletingLastPathComponent()
            for _ in 0..<8 {
                let candidate = dir.appendingPathComponent("Assets.xcassets")
                if fm.fileExists(atPath: candidate.path) {
                    return dir
                }
                dir = dir.deletingLastPathComponent()
            }
        }

        XCTFail("""
            定位不到仓库根（含 Assets.xcassets 的那一层）。
            #filePath = \(raw)；进程当前目录 = \(fm.currentDirectoryPath)。
            本守卫绝不静默跳过 —— 若源码在测试运行环境中不可达，
            请修正本文件的定位策略，而不是把断言删掉。
            """)
        return nil
    }

    /// 读取一个 appiconset 的 Contents.json 条目。
    /// - Parameter folder: appiconset 目录 URL。
    /// - Returns: 条目字典数组；读不到或不合法时返回 nil 并 XCTFail。
    private func loadIconSetEntries(at folder: URL) -> [[String: String]]? {
        let fm = FileManager.default
        let contentsURL = folder.appendingPathComponent("Contents.json")
        guard fm.fileExists(atPath: contentsURL.path) else {
            XCTFail("找不到 \(contentsURL.path)：该 appiconset 没有 Contents.json")
            return nil
        }
        do {
            let data = try Data(contentsOf: contentsURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let images = object["images"] as? [[String: Any]] else {
                XCTFail("\(contentsURL.path) 结构不合法：顶层应当有 images 数组")
                return nil
            }
            return images.map { entry in
                var flat: [String: String] = [:]
                for key in ["idiom", "size", "scale", "filename"] {
                    if let value = entry[key] as? String { flat[key] = value }
                }
                return flat
            }
        } catch {
            XCTFail("读取 \(contentsURL.path) 失败：\(error)")
            return nil
        }
    }

    // MARK: - 1. 每个备用图标集必须含 iOS 取图所需的尺寸

    /// 备用图标集的 Contents.json 必须含 iPhone / iPad 各档实际尺寸。
    ///
    /// 红的唯一理由应当只有一种：图标集**退化回只有 1024 universal 一条记录**。
    /// 那种状态下 `supportsAlternateIcons` 仍为 true、映射仍正确、产物仍含声明，
    /// 但 `setAlternateIconName` 会回调报错 —— 除本守卫外没有任何一处能抓住它。
    func testAlternateIconSetsDeclareRequiredSizes() {
        guard let root = locatedRepositoryRoot() else { return }

        for setName in Self.alternateIconSetNames {
            let folder = root
                .appendingPathComponent("Assets.xcassets")
                .appendingPathComponent("\(setName).appiconset")
            guard let entries = loadIconSetEntries(at: folder) else { continue }

            let present: Set<String> = Set(entries.map { entry in
                "\(entry["idiom"] ?? "")|\(entry["size"] ?? "")|\(entry["scale"] ?? "")"
            })
            let missing = Self.requiredSpecs.filter { !present.contains("\($0.idiom)|\($0.size)|\($0.scale)") }

            XCTAssertTrue(
                missing.isEmpty,
                """
                备用图标集 \(setName) 缺少 iOS 取图所需的 rendition 记录：
                \(missing.map { "  - \($0.idiom) \($0.size) @\($0.scale)" }.joined(separator: "\n"))
                现有记录：\(present.sorted())
                只有 1024x1024/universal（App Store 槽位）会导致
                UIApplication.supportsAlternateIcons == true 但 setAlternateIconName 回调报错失败。
                """)

            // 引用了但磁盘上没有 = 另一类静默失败（actool 会跳过、不一定报错）。
            for entry in entries where entry["filename"] != nil {
                let fileURL = folder.appendingPathComponent(entry["filename"] ?? "")
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: fileURL.path),
                    "\(setName) 的 Contents.json 引用了 \(entry["filename"] ?? ""),但磁盘上没有这个文件")
            }
        }
    }

    // MARK: - 2. 至少有两条以上记录（兜底住"整体退化成单尺寸"）

    /// 图标集不得退化成「只有一条记录」。
    ///
    /// 与上一条互补：上一条锚的是**具体规格**，这一条锚的是**性质的下限** ——
    /// 将来 Apple 改尺寸矩阵时上一条可能失焦，但只要退化成单尺寸，这条仍然红。
    func testAlternateIconSetsAreNotSingleEntry() {
        guard let root = locatedRepositoryRoot() else { return }

        for setName in Self.alternateIconSetNames {
            let folder = root
                .appendingPathComponent("Assets.xcassets")
                .appendingPathComponent("\(setName).appiconset")
            guard let entries = loadIconSetEntries(at: folder) else { continue }

            XCTAssertGreaterThan(
                entries.count, 1,
                "备用图标集 \(setName) 只有 \(entries.count) 条记录 —— 单尺寸图标集会让 App 内换图标回调报错")
        }
    }
}

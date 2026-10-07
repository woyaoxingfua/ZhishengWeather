//
//  SatelliteFrameValidator.swift
//  Core / Networking  [App + Widget 共用]
//
//  卫星云图**帧有效性**判定（纯逻辑，零 IO、零 `Date()`）。
//
//  ═══════════════════════════════════════════════════════════════════════
// 实测基准：2026-10-07（当次 curl 落盘 + Pillow 逐像素统计）
// ═══════════════════════════════════════════════════════════════════════
//
// ── 为什么需要它：纯黑占位图「状态码与字节数都骗人」─────────────────
// 设计稿给的 GIBS 负样本（本 worker 未复测，仅作对照说明为什么要有本文件）：
//   6 个**完全不同**的位置，夜间全部 `200` / `size=1665`（字节数一模一样），
//   但像素统计 `唯一样本=1`、`Rstd=0.00` → **纯黑**。
// → 只看 HTTP 码 + 字节数会 **100% 误判可用**。这与本项目历史上
//   「用字节数判雷达覆盖」零判别力是同一条教训。
//
// ── 🔴 nmc 源实测：帧**从不全黑**（含北京时间凌晨）────────────────────
//逐帧实测（像素统计，R 通道，抽行每 4 行取 1 行 → 样本 116 100 px，
// 与旧文件头声称的 116 100 **逐字吻合**）。
//   ⚠️ 下表是**本轮 2026-10-07 当次实测**（2026-10-07 各时次，15 帧全部 200）：
//   stamp                字节数     尺寸        uniq    Rstd   Rmean  pure_black
//   20261007000000000    142 144   860x540    29 868  67.00  99.14   2
//   20261007003000000    147 277   860x540    32 360  66.65  99.52   0
//   20261007020000000    156 999   860x540    37 144  66.20  99.00   0
//   20261007023000000    160 013   860x540    35 748  65.26  101.70  1
//   20261007040000000    155 589   860x540    31 710  65.71  108.16  0
//   20261007043000000    155 378   860x540    31 645  67.08  115.65  0
//   20261007060000000    160 772   860x540    30 704  66.45  108.59  0
//   20261007063000000    163 118   860x540    30 621  66.89  108.41  1
//   20261007080000000    163 863   860x540    32 499  66.56  111.11  0
//   20261007083000000    158 248   860x540    32 225  67.71  111.23  1
//   20261007100000000    150 899   860x540    30 120  72.80  107.48  17
//   20261007103000000    145 840   860x540    27 351  73.31  106.81  12
//   20261007120000000    132 647   860x540    20 433  73.75  94.60   15
//   20261007123000000    131 050   860x540    18 182  70.92  85.34   14
//   20261007140000000    126 137   860x540    13 344  69.13  76.47   10
//   （另测 2026-10-06 23:00 → 136 270 B / uniq 26 184 / Rstd 63.61）
// 关键观察（**全部为本轮实测**）：
//  · `uniq` 区间 **13 344 … 37 144**，**从未接近 1**；
//  · `Rstd` 区间 **63.61 … 73.75**，**从未接近 0**；
//  · `pure_black` 计数最多 **17 px / 116 100 抽样 = 0.015%**（夜间帧的
//    「黑」是**夜面陆地的低照度**，不是占位图）；
//  · 尺寸恒为 **860×540**；字节数区间 **126 137 … 163 863**。
// → 故阈值可以取得很宽裕：`uniq < 64` 或 `Rstd < 8` 判纯黑。
//
// ⚠️ **与旧文件头的差异（保留更正痕迹，不静默改）**：
// 旧表写`uniq` 最小 24 972、`Rstd` 最小 64.97、字节数 122 603…163 863。
// 本轮实测 `uniq` 最小值**低至 13 344**（比旧值低约一半）。
// → **阈值不变**（64 与 13 344 仍差 208 倍，依旧安全），
//   但「实测最小值」这个**论证依据**必须换成上表的真实数字。
//   保留一个偏高的下限，会让人误以为「实测下限」很接近阈值 —— 那是运气，
//   不是余量。
//
// ── ⚠️ 阈值仍必须有：不是为nmc常态帧，而是为「防御性兜底」────────────
// 三种会真的拿到坏帧的路径：
//  ① 404 的响应体是**openresty HTML 错误页**——
//     若只看「有数据」就会把 HTML 当图显示；
//  ② 将来上游若改行为返回占位图（GIBS 那种）；
//  ③ 传输截断 → JPEG 解码失败。
// 三者统一收敛到 `.invalid` → UI 显示「云图加载失败」，**绝不上黑屏**。
//
// ═══════════════════════════════════════════════════════════════════════
// 🔴 本轮（2026-10-07复核）**逐条重测了文件里的「实测」数字**，结论：
//
// ✅ **「404 响应体 552 B」是对的，予以保留。**
//    当次实测 4 次全部 **552 B**（`high` / `large` / 越界日期 / 经代理），
//    逐字以 `<html><head><title>404 Not Found</title>…` 开头、含
//    `<center>openresty</center>`。同批用 Pillow 读该文件 →
//    `cannot identify image file`（**它根本不是图片**，这才是关键）。
//    ⚠️ 复核过程中曾出现「150 B」的说法，**当次复测无法复现**（4/4 均为 552），
//    故按「以可复现的实测为准」保留 552 B。
//
// ❌ **阈值区间的旧数字被本轮实测推翻，已在下方逐条更新**（见各常量文档）。
//    旧文件头的帧样本表写`uniq` 区间 24 972…52 690、`Rstd` 64.97…72.86；
//    本轮 15 帧实测 `uniq` 区间为 **13 344…37 144**（下限比旧值低一半），
//    `Rstd` 区间 **65.26…73.75**。
//    → **纯黑判据的阈值本身仍然安全**（见 `pureBlackUniqueSampleLimit`：
//    13 344 与64 仍差 208 倍），但「实测最小值」这类**依据数字必须以本轮为准**，
//    否则下一个改阈值的人会拿一个偏高的下限去论证「绝不会误杀」——
//    那是**用不实的依据证明正确的结论**，同样有害。
// ═══════════════════════════════════════════════════════════════════════
//
// Core 纪律：仅 import Foundation；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 帧的像素统计（**由上层解码后注入**，本文件不做解码，故可单测）。
struct SatelliteFrameStatistics: Equatable {

    /// 画面宽度（px）。
    let width: Int

    /// 画面高度（px）。
    let height: Int

    /// 唯一样本数（**去重后的不同像素值个数**，0–256²）。
    let uniqueSampleCount: Int

    /// 亮度标准差（0–255 尺度）。
    let intensityStandardDeviation: Double

    /// 纯黑像素数（r=g=b=0）。
    let pureBlackPixelCount: Int

    /// 总像素数。
    var totalPixelCount: Int { max(0, width) * max(0, height) }
}

/// 帧有效性判定结果。
///
/// ⚠️ **刻意不用 enum 带raw type**（本仓陷阱：enum 不能同时用 raw type
/// 与关联值 case）—— 这里无 raw type需求，故用纯 enum + 关联值。
enum SatelliteFrameVerdict: Equatable {

    /// 有效帧。
    case valid

    /// 纯黑占位图（**实测 nmc 未触发**，兜底路径）。
    case pureBlackFrame

    /// 画面过小（不是一张真图）。
    case implausiblySmall

    /// 字节数不像图片（**实测为 404 的 openresty HTML 错误页，552 B**）。
    case notAnImagePayload

    /// 解码失败（含传输截断）。
    case decodeFailed

    /// 用户可读文案（**如实区分**，绝不共用一句「加载失败」了事）。
    ///
    /// ⚠️ `pureBlackFrame` 与其它四态**必须给不同文案**：
    /// 前者是「这一帧没有有效影像」（可能是夜间/无日照），
    /// 后者是「取不到」。混用就是把「没有数据」说成「坏了」。
    var message: String {
        switch self {
        case .valid:
            return "云图有效"
        case .pureBlackFrame:
            // 夜间可能出现，故文案指向「时次」而非「故障」。
            return "该时次云图为空白（夜间或无日照时段）"
        case .implausiblySmall:
            return "云图画面尺寸异常"
        case .notAnImagePayload:
            return "云图服务返回的不是图片"
        case .decodeFailed:
            return "云图解码失败"
        }
    }

    /// 是否可展示。
    var isDisplayable: Bool { self == .valid }
}

/// 帧有效性判定（纯函数，可单测）。
enum SatelliteFrameValidator {

    // MARK: - 实测阈值

    /// 纯黑判定的「唯一样本数」上限。
    ///
    /// 本轮实测真帧 `uniq` 最小值 = **13 344**（`20261007140000000`）。
    /// 取 64 与之相差 **≈208 倍** → 绝不会误杀真帧。
    ///
    /// ⚠️ 旧文档写「最小 24 972（相差 390 倍）」，本轮实测下**该依据不成立**
    /// （真实下限更低）。阈值本身不变，仅更正论证依据 —— 见文件头。
    static let pureBlackUniqueSampleLimit = 64

    /// 纯黑判定的「亮度标准差」上限。
    ///
    /// 本轮实测真帧 `Rstd` 最小值 = **63.61**（2026-10-06 23:00 UTC）。
    /// 取 8 与之相差 **≈8 倍**，且远高于「真全黑」的 0.00。
    static let pureBlackStandardDeviationLimit: Double = 8.0

    /// 画面最小边长（px）。
    ///
    /// 本轮实测真帧恒为 **860 × 540**。取 64 作为「明显不是一张图」的下界。
    static let minimumEdgePixels = 64

    /// 字节数下限（B）。
    ///
    /// 本轮实测真帧字节数区间 **126 137 … 163 863 B**（15 帧样本）。
    /// 取 8 192 远低于该区间，目的是拦住 404 的 **552 B** openresty HTML
    /// 错误页（本轮 4 次实测恒为 552 B，逐字含 `<center>openresty</center>`）。
    static let minimumByteCount = 8_192

    /// 字节数上限（B）。
    ///
    /// 本轮实测最大 163 863 B。取 8 MiB 作为「不是图片而是别的东西」的上界。
    static let maximumByteCount = 8 * 1_024 * 1_024

    // MARK: - 判定

    /// 只判**字节层面**（不需要解码即可拦掉 HTML 错误页 / 空响应）。
    ///
    /// - Parameter byteCount: 响应字节数。
    /// - Returns: 通过 → `nil`；不通过 → 具体原因。
    static func validateByteCount(_ byteCount: Int) -> SatelliteFrameVerdict? {
        if byteCount < minimumByteCount { return .notAnImagePayload }
        if byteCount > maximumByteCount { return .notAnImagePayload }
        return nil
    }

    /// 只判**像素统计**（解码后调用）。
    ///
    /// - Parameter statistics: 像素统计。
    /// - Returns: 通过 → `nil`；不通过 → 具体原因。
    static func validateStatistics(_ statistics: SatelliteFrameStatistics) -> SatelliteFrameVerdict? {
        if statistics.width < minimumEdgePixels || statistics.height < minimumEdgePixels {
            return .implausiblySmall
        }
        if statistics.totalPixelCount == 0 { return .implausiblySmall }
        // 纯黑：唯一样本极少 **或** 亮度几乎无起伏（任一命中即判黑）。
        //
        // ⚠️ 用「或」是刻意的：GIBS 负样本两者同时成立，
        //   而不同来源的占位图可能只满足其一（如全灰图 uniq=1 但 Rstd=0）。
        if statistics.uniqueSampleCount <= pureBlackUniqueSampleLimit
            || statistics.intensityStandardDeviation <= pureBlackStandardDeviationLimit {
            return .pureBlackFrame
        }
        return nil
    }

    /// 合成判定：字节 + 像素（**像素统计可为 nil**，此时只判字节）。
    ///
    /// - Parameters:
    ///   - byteCount: 响应字节数。
    ///   - statistics: 像素统计；解码未做或失败时传 nil。
    /// - Returns: 通过 → `nil`；不通过 → **第一个**失败原因。
    static func validate(byteCount: Int,
                         statistics: SatelliteFrameStatistics?) -> SatelliteFrameVerdict? {
        if let bad = validateByteCount(byteCount) { return bad }
        guard let statistics else { return nil }
        return validateStatistics(statistics)
    }
}

// MARK: - 像素统计注入点

/// 「字节 → 像素统计」的**注入点**（Core 只声明契约，平台层提供实现）。
///
/// ── 为什么 Core 不自己解码 ─────────────────────────────────────────────
/// `Core/` 被**主App 与 Widget 两个 target 同时编译**（见 `project.yml`），
/// 且 Core 内**禁 `import UIKit`**（静态门禁 SC-08）→ Core 不能解码。
/// 而「纯黑占位图」这个头号坑**只能靠像素统计判**：纯黑判据（`uniq` / `Rstd`）
/// 对字节数**零判别力**——状态码 200、字节数与真实图完全一样。
/// → 故Core 只声明「谁能给我统计」，由 App 侧（唯一持有 UIKit 的 target）
///   在解码后把统计结果注入回来。
///
/// ── 实现方（本仓）──────────────────────────────────────────────────────
/// `ZhishengWeather/SatelliteCardModel.swift` 的
/// `nonisolated static func statistics(of: Data) -> SatelliteFrameStatistics?`
/// —— 抽行扫描（每 4 行取 1 行）；单测用替身注入。
///
/// ⚠️ **返回 nil 是合法且必须被如实处理的结果**，含义是
/// 「这一帧没能算出像素统计」（未注入实现/ 解码失败）。
/// 调用方**绝不能**把 nil 当成「已通过纯黑检测」——
/// 那正是本文件头记录的「只看字节数 100% 误判可用」的同一个错误。
typealias SatelliteStatisticsProvider = (Data) -> SatelliteFrameStatistics?

/// 一帧的**像素层判定实际发生了什么**（用于如实上报，绝不美化）。
///
/// ⚠️ 存在的理由：只说「拿到了一帧」并**不说明像素层到底跑没跑**。
/// 若不把这件事显式带出来，上层只能默认「拿到帧= 纯黑检测也过了」——
/// 而统计为 nil 时纯黑检测**根本没运行**。
/// 那就是「把『没判』说成『判过了』」，与本项目栽过的坑同一类。
enum SatellitePixelValidation: Equatable {

    /// 像素统计已算出且**通过**纯黑判定（两层都真跑了）。
    case passed

    /// **像素层未能判定**（未注入实现，或解码失败 → 统计为 nil）。
    ///
    /// ⚠️ 此状态下**确实会漏掉纯黑帧**：纯黑判定根本没运行。
    /// 故必须与 `.passed` 严格区分，禁止在文案 / 逻辑上混为一谈。
    case unavailable

    /// 用户可读说明（**如实区分「没判」与「判过」**）。
    var message: String {
        switch self {
        case .passed:
            return "云图像素已校验"
        case .unavailable:
            // ⚠️ 绝不说「云图有效」—— 那会谎称纯黑检测已通过。
            return "云图像素未校验（仅按数据量判定）"
        }
    }
}

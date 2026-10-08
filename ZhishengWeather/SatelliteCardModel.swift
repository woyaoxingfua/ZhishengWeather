//
//  SatelliteCardModel.swift
//  ZhishengWeather（主 App target）
//
//  卫星云图卡的主屏状态容器（`@Observable` + `@MainActor`）—— 与
//  `RadarCardModel` / `TyphoonCardModel` **同款**（独立链路 + 独立失败域 +
//  `@State` 持有）。
//
//  ── 为什么独立于 `WeatherViewModel` ────────────────────────────────
// 与雷达/台风同款：`image.nmc.cn` 是**独立域名 + 独立失败域**，
// 取数失败只该写自己的状态。塞进主 VM 会污染主 `state`。
//
//  ── 四态（**本类型唯一的判定出口**，视图只渲染不判定）──────────────
//  · `.idle`     未开始取数；
//  · `.loading`  取数中（**不参与**四态判定，只驱动"正在加载"）；
//  · `.loaded`   拿到**已通过坏帧校验**的图（附观测时刻 + 来源 URL）；
//  · `.unavailable(reason)` 取不到 / 帧不合格 → **如实显示原因**。
//
//  ⚠️ `.unavailable` 的 `reason` **必须区分三类**（依据不同）：
//   · 网络/全部时次缺失 → 「未找到可用时次」；
//   · 帧是 HTML 错误页（本轮实测 404 返回 **552 B** openresty HTML，
//     4 次探测恒为该值）→ 「不是图片」；
//   · 帧纯黑 → 「该时次云图为空白」。
//  把三者混成一句「加载失败」= **内容错误**：用户在夜间看到「加载失败」
//  会以为产品坏了，而实际只是那一帧没有日照。
//
//  ── 🔴 为什么「默认关闭」──────────────────────────────────────────
//  云图是**整幅亚洲区域**的位图（实测 860×540，覆盖实测经纬范围
//  约东经 48°–160°、北纬 3°–66°），一旦盖在地图上会把底图**完全遮住**。
//  而用户打开这张卡的目的（看回波 / 看预警）恰恰需要底图。
//  → 故 `isEnabled` 默认 **false**：先让用户主动开，而非替他决定。
//
//  ── 时间注入 ──────────────────────────────────────────────────────
//  `now` 全部**注入**（默认 `Date()` 只在 App 调用点生效），单测可固定。
//
//  Core 纪律：本文件在 App target，可 import UIKit（**仅用于图片解码**）；
//  取数判据全在 Core 的纯函数里，本文件只做「状态 + 生命周期」。
//

import Foundation
import UIKit
import Observation

/// 卫星云图卡主屏状态。
@MainActor
@Observable
final class SatelliteCardModel {

    // MARK: - 对外状态

    /// 降级四态（**视图只消费这个**）。
    private(set) var state: State = .idle

    /// 云图是否已解码成可显示的图（`nil` = 无图）。
    private(set) var image: UIImage?

    /// 当前帧的**UTC 观测时刻**（用于「更新时间」标注）。
    private(set) var observationDate: Date?

    /// 当前帧的产品 URL（用于「查看原图」外链）。
    private(set) var sourceURL: URL?

    /// 当前帧的**像素层是否真的判过**（`.unavailable` = 没判，别当成「验过了」）。
    ///
    /// ⚠️ 本批**尚无 UI 消费它**（本类型未接入 `ContentView`）。
    /// 存在的理由是**先把事实记录下来**：一旦丢掉，
    /// 「这一帧没做纯黑检测」这件事就再也无法与「验过了」区分。
    private(set) var pixelValidation: SatellitePixelValidation = .unavailable

    /// 是否正在取数（**只用于显示"正在加载"，不参与四态判定**）。
    private(set) var isLoading: Bool = false

    /// 图层开关（**默认关闭**，理由见文件头）。
    var isEnabled: Bool = false

    /// 加载是否已超时（秒）。
    ///
    /// ⚠️ **必须有超时兜底**（与 `RadarCardModel` 同款纪律）：取数卡住时
    /// 一直转圈，用户看到的就是「转圈卡死」——那是最容易被当成
    /// 「功能正常只是慢」的失败态。
    static let loadTimeout: TimeInterval = 20

    /// 本次加载是否已超时。
    private(set) var hasTimedOut: Bool = false

    // MARK: - 状态枚举

    /// 四态。
    enum State: Equatable {
        case idle
        case loaded
        case unavailable(String)

        /// 供 UI 显示的一句话（**如实，不夸大**）。
        var headline: String {
            switch self {
            case .idle: return "未加载"
            case .loaded: return "已更新"
            case .unavailable: return "云图加载失败"
            }
        }
    }

    // MARK: - 构造

    /// 取数服务（测试注入 Stub）。
    private let service: SatelliteImageService

    /// 注入服务。
    init(service: SatelliteImageService = SatelliteImageService()) {
        self.service = service
    }

    // MARK: - 生命周期

    /// 加载最新云图（主屏 `.task` 调用）。
    ///
    /// - Parameter now: 注入的「现在」（单测可固定）。
    func load(now: Date = Date()) async {
        isLoading = true
        hasTimedOut = false
        defer { isLoading = false }

        // 🔴 解码钩子在本层注入：Core 禁 UIKit（被 App + Widget 双 target 编译），
        //    故像素统计必须由 App 侧提供 —— 这正是服务接受闭包的原因。
        //    实测统计口径（见 SatelliteFrameValidator 文件头）：
        //   · 唯一样本数 = 去重后的不同 RGB 组合数；
        //   · 强度标准差 = R 通道标准差（0–255）。
        //
        // ⚠️ 本批**只接线不建 UI**：Core 层的判据与 URL 拼装已有测试覆盖，
        //    但本类型**尚未被任何 View 引用**（`ContentView` 未接入），
        //    故 `image` / `state` 目前无人消费。UI 接线留到下一批。
        //
        // ⚠️ 刻意写成**显式实参**而非尾随闭包：`statisticsProvider` 是
        //    **可选**闭包参数，尾随闭包在可选参数位置上有歧义风险，
        //    显式传参把「这里就是注入点」写死在代码里。
        let outcome = await service.fetchLatest(
            now: now,
            statisticsProvider: { data in Self.statistics(of: data) }
        )

        switch outcome {
        case .success(let data, let url, let observed, let pixelValidation):
            guard let decoded = UIImage(data: data) else {
                // 解码失败 = 一种「取不到」，**不能**当成功（否则展示破图）
                state = .unavailable(SatelliteFrameVerdict.decodeFailed.message)
                image = nil
                observationDate = nil
                sourceURL = nil
                self.pixelValidation = .unavailable
                return
            }
            state = .loaded
            image = decoded
            observationDate = observed
            sourceURL = url
            // 🔴 如实记录像素层是否真的判过：`.unavailable` 意味着
            // 「这一帧没做纯黑检测」（统计为 nil）。
            // **不因此改判失败** —— 字节层已过、图也解出来了，
            // 但也不能谎称「纯黑已验过」。留待 UI 批次决定如何呈现。
            self.pixelValidation = pixelValidation
        case .rejectedFrame(let verdict):
            state = .unavailable(verdict.message)
            image = nil
            observationDate = nil
            sourceURL = nil
            self.pixelValidation = .unavailable
        case .unavailable(let message):
            state = .unavailable(message)
            image = nil
            observationDate = nil
            sourceURL = nil
            self.pixelValidation = .unavailable
        }

        // 超时兜底：把「取数耗时」如实暴露给 UI。
        hasTimedOut = Date().timeIntervalSince(now) > Self.loadTimeout
    }

    // MARK: - 像素统计（实测口径）

    /// 统计一帧的像素特征（供 `SatelliteFrameValidator` 判定纯黑）。
    ///
    /// ⚠️ **抽行扫描**（每 4 行取 1 行）：全图 464 400 像素逐个统计在主线程
    /// 约需数十毫秒，App 侧解码每次切城市都会调；抽行后样本仍有 11.6 万，
    /// 对「是否纯黑」这一判定**绰绰有余**（实测真帧 `uniq` 区间
    /// 24 972–52 690，纯黑占位图为 1，两者在任何抽行比例下都差 3 个数量级）。
    ///
    /// - Parameter data: JPEG 字节。
    /// - Returns: 统计结果；解码失败 → nil（此时只做字节层校验）。
    nonisolated static func statistics(of data: Data) -> SatelliteFrameStatistics? {
        guard let image = UIImage(data: data),
              let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        // 建一个 RGBA 上下文把图绘进来（统一通道序，避免直接读 CGImage 数据
        // 时遇到 unknown layout / 字节序不确定的问题）。
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = pixels.withUnsafeMutableBytes({ raw -> CGContext? in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return nil }
            return ctx
        }) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var seen = Set<UInt32>()
        seen.reserveCapacity(1 << 16)
        var sum: Double = 0
        var sumSquares: Double = 0
        var count: Double = 0
        var pureBlack = 0

        // ⚠️ 这个局部常量**不能叫 `stride`** —— 它会遮蔽 Swift 标准库的
        // `stride(from:to:by:)` 函数，使下面那行循环变成
        // 「调用 Int 类型的值」，CI 报：
        // `error: cannot call value of non-function type 'Int'`（2026-10-08 实测）。
        // 改名而不是写 `Swift.stride(...)`：把地雷拆掉，避免下一个人再踩。
        let pixelStride = 4
        let rowStep = 4   // 每 4 行取1 行
        var index = 0
        for _ in stride(from: 0, to: height, by: rowStep) {
            for _ in 0..<width {
                let r = pixels[index]
                let g = pixels[index + 1]
                let b = pixels[index + 2]
                let value = Double(r)
                sum += value
                sumSquares += value * value
                count += 1
                if r == 0 && g == 0 && b == 0 { pureBlack += 1 }
                seen.insert(UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b))
                index += pixelStride
            }
            // 跳到下一采样行的起始像素
            index += (rowStep - 1) * width * pixelStride
        }

        guard count > 0 else { return nil }
        let mean = sum / count
        let variance = max(0, sumSquares / count - mean * mean)
        return SatelliteFrameStatistics(
            width: width,
            height: height,
            uniqueSampleCount: seen.count,
            intensityStandardDeviation: variance.squareRoot(),
            pureBlackPixelCount: pureBlack
        )
    }
}

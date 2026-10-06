//
//  RadarPNGDecoder.swift
//  ZhishengWeather（主 App target）
//
//  PNG → RGBA 字节解码（**只服务于覆盖瓦片判读**，不是通用图片工具）。
//
//  为什么单独一个文件：PNG 解码要 CoreGraphics，而 `Core/` 被主 App 与
//  Widget 两个 target 同时编译、且静态守卫 SC-12 的 Core import 白名单
// **不含 CoreGraphics/UIKit**。故解码留在 App 侧，通过闭包注入给
// `RadarCoverageService`（见该文件 `coverage(latitude:longitude:host:decoder:)`）。
//
//  用途单一：把覆盖瓦片数成「不透明黑色像素占比」，交给 Core 的纯函数
// `RadarCoverageTileReader` 判读。**不做缩放、不做颜色转换、不缓存**。
//

import Foundation
// CoreGraphics 在 iOS 上随 Foundation 可用；显式引入以免依赖隐式 re-export。
import CoreGraphics
import ImageIO

/// 覆盖瓦片解码器。
enum RadarPNGDecoder {

    /// PNG 字节 → 连续 RGBA 字节。
    ///
    /// - Parameter data: PNG 数据。
    /// - Returns: 长度 = 像素数 × 4 的 RGBA 字节；解码失败 → nil
    ///   （**nil 由调用方收敛为 `.unknown`**，绝不误判为"无覆盖"）。
    ///
    /// ⚠️ 固定以 **RGBA 8-bit** 输出，保证 `RadarCoverageTileReader` 的
    /// 「每像素 4 字节、通道序 r,g,b,a」假设成立（若返回 BGRA，
    /// 黑白判读虽不受影响，但 alpha 位置会错 → 覆盖率算错）。
    static func decodeRGBA(_ data: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        // 每像素 4 字节 × 行数；bitmapInfo 用 premultipliedLast（= RGBA）。
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let byteCount = bytesPerRow * height
        var buffer = [UInt8](repeating: 0, count: byteCount)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // 覆盖瓦片可能带 alpha（官方语义：有覆盖=透明）。故保留 alpha 通道，
        // 绝不 premultiply 到不透明 —— 否则"全透明=有覆盖"会被算成黑色。
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrderDefault.rawValue

        let created: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard created else { return nil }
        return buffer
    }
}

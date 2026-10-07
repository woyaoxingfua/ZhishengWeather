//
//  RadarPixelShiftTests.swift
//  ZhishengWeatherTests
//
//  R2（像素级平移）的**机制与量级**单测。
//
//  ── 本文件验证什么 / 不验证什么（务必读完）──────────────────────────
//  ✅ 能证明：
//    ① MapKit 侧平移机制的存在性判断被钉住（官方无平移API，但 draw 钩子可平移）；
//    ② 平移量换算链正确（米 → mapPoint → 点），且与解析式交叉一致；
//    ③ **平移量在 z4–z7 全区间都 < 1 设备像素**（**仅 @1x 成立**）——
//       即"平了也看不见"这个结论是可执行的，不是口头断言；
//       🔴 **@2x 起不再成立**（z7 北京 1.184 px、广州 1.104 px 已可见）。
//    ④ 惰性证明 `correctionIsInertAcrossRadarZooms` **仍然为真**
//       （像素级平移**不改变瓦片请求**，故三档 URL 仍相同 —— 这正是
//        平移与"切档"两条路的关键区别）。
//  ❌ **不能证明**：纠偏**方向**对不对、MapKit 是否已自动纠偏。
//     那是 MapKit 运行时行为，只能真机验证（R1未收敛）。
//
//  ⚠️ 期望值来源：全部由 Python 独立复刻同一套公式跑出（实测 2026-10-07），
//  不依赖 Swift 实现自身的结果，避免"用被测代码算期望值"的循环论证。
//
//  纪律：无 `XCTFail("待实现")`、无 `#if false` 占位。
//

import XCTest
// `atan` / `sinh` / `asinh` / `tan` 来自 Darwin 数学库，经 Foundation 转出。
import Foundation
// `ShiftedTileOverlayRenderer` 是 App target 的 MapKit 类，故本测试需 import MapKit
// 才能调它的静态 `shiftVector`（`CLLocationCoordinate2D` 也来自 MapKit 的连带导出）。
import MapKit
// ⚠️ `UIScreen` 属于 **UIKit**，不由 MapKit / Foundation 保证 re-export
// （同款判断见 `SettingsView.pixelShiftReading` 与 `RadarMapCard` 的 import 注释）
// → 必须显式引入，否则 `UIScreen.main.scale` 报 "cannot find 'UIScreen' in scope"。
import UIKit
@testable import ZhishengWeather

// MARK: - 一、MapKit 侧平移能力的查证结论（钉住「查到了什么」）

/// 把「MapKit 有没有平移 API」变成可执行断言。
///
/// ⚠️ 为什么要钉：很容易凭印象写「MapKit 不支持平移」或「肯定能平移」。
/// 两条都不对 —— 官方**没有**平移属性，但 `draw` 钩子**能**平移。
final class MapKitTranslationCapabilityTests: XCTestCase {

    /// `MKTileOverlayRenderer` 官方页**不提供**任何平移 / 变换属性。
    ///
    /// - 依据（实测查证 2026-10-07，WebFetch 官方页全文）：Topics 只有
    ///   `init(tileOverlay:)` 与 `reloadData()`。
    func testTileRendererExposesNoTranslationAPI() {
        XCTAssertFalse(CoordinateTransform.Evidence.tileRendererExposesTranslationAPI,
                       "MKTileOverlayRenderer 官方页无平移 API；"
                       + "若此断言失败，必须在注释里附官方原文链接后再改")
    }

    /// 但 `draw(_:zoomScale:in:)` 钩子**可用**于平移（机制层可行）。
    ///
    /// - 依据：`MKOverlayRenderer` 官方页明写
    ///   "Subclasses need to override the `draw(_:zoomScale:in:)` method to draw
    ///   the contents of the overlay."，且该方法收 `CGContext`。
    func testDrawHookIsAvailableForTranslation() {
        XCTAssertTrue(CoordinateTransform.Evidence.translationViaDrawHookAvailable,
                      "draw(_:zoomScale:in:) 是文档化的子类钩子，可用于平移绘制内容")
    }

    /// 平移能力查证用的链接与引文非空（防止证据被清空成"查无此事"）。
    func testTranslationEvidenceIsPopulated() {
        XCTAssertTrue(CoordinateTransform.Evidence.tileRendererDocURL
            .hasPrefix("https://developer.apple.com/documentation/mapkit/"))
        XCTAssertTrue(CoordinateTransform.Evidence.overlayRendererDocURL
            .hasPrefix("https://developer.apple.com/documentation/mapkit/"))
        XCTAssertTrue(CoordinateTransform.Evidence.overlayRendererSubclassHookQuote
            .contains("draw(_:zoomScale:in:)"),
                      "引文应含 draw(_:zoomScale:in:) 子类钩子原文")
    }

    /// 🔴 **能力 ≠ 效果已达成**：机制可行，但平移量在 **@1x** 不足 1 px（见下节）。
    ///
    /// ⚠️ 不可无条件转述为「平移量恒不足 1 px」—— **@2x 起就不成立**
    /// （z7 北京 1.184 px、广州 1.104 px 已可见）。
    ///
    /// 这条测试防止后来者只看到"机制可行"就宣称"纠偏已实现"。
    ///
    /// ⚠️ **2026-10-07（本轮，第三次修正）：断言的**档位**从 @2x 改为 @1x。**
    /// 前两轮修的是 `csf` 被平方（已修）；本轮发现的是**更深一层的物理错误**：
    /// `metersPerMapPoint` 把 `cos` **方向搞反了**（`÷ cos` ⇒ `× cos`），
    /// 导致高纬平移量被系统性低估 `1/cos²` 倍。改正后 z7 参考点最大值：
    /// @1x **0.592 px** / @2x **1.184 px** / @3x **1.776 px**（均为 Python 独立复算）
    /// ⇒ **"全区间 < 1 px"只对 @1x 成立**。这是**实现错了、断言跟着改**，
    /// 不是放宽标准去迁就代码。
    func testTranslationCapabilityDoesNotImplyVisibleCorrection() {
        XCTAssertTrue(CoordinateTransform.Evidence.translationViaDrawHookAvailable)
        // 在 @1x 上，全中国境内参考点仍**没有一个**达到 1 设备像素。
        // ⚠️ 不可读成「任何倍率下都看不见」—— @2x/@3x 都不成立（见上）。
        //
        // ⚠️ 这里**逐参考点断言 @1x**，而不是调`pixelShiftIsBelowOnePixelEverywhere`：
        // 后者把 `csf <= 1.0` 展开成 `[1.0, 2.0]`（`CoordinateTransform.swift:658`），
        // 修 cos 后它连@2x 一起测、对 csf=1 也返回 false ⇒ 不能用它表达"@1x 全不可见"。
        let worstAt1x = CoordinateTransform.probeReferencePoints
            .map { point in
                CoordinateTransform.pixelShiftProbe(
                    longitude: point.longitude, latitude: point.latitude,
                    zoom: 7, tileEdge: 256, contentScaleFactor: 1)
            }
            .map { $0.magnitudeDevicePixels }
            .max() ?? 0
        XCTAssertLessThan(worstAt1x, 1.0,
                          "@1x 下平移量应全区间 < 1 设备像素 —— 机制可行 ≠ 用户看得见"
                          + "（实测最大 \(worstAt1x) px =北京@z7）")
        XCTAssertFalse(
            CoordinateTransform.pixelShiftIsBelowOnePixelEverywhere(tileEdge: 256,
                                                                    contentScaleFactor: 2),
            "@2x 不应再声称全不可见（北京 z7 1.184 px）")
    }
}

// MARK: - 二、平移量换算链（米 → mapPoint → 点）

/// 验证 `metersPerMapPoint` / `mapPointsPerMeter` / `zoomScale` 三步换算。
final class PixelShiftUnitConversionTests: XCTestCase {

    /// `MKMapSize.world.width` = 2^28（**文档如此，未实测**；数值本身不影响结论）。
    func testWorldWidthConstant() {
        XCTAssertEqual(CoordinateTransform.MKMapSizeWorldWidth, 268_435_456.0, accuracy: 0.001)
    }

    /// 赤道处 1 mapPoint 的米数 = 40075016.686 / 2^28 ≈ 0.149 291 m。
    ///
    /// 期望值由 Python 独立算出：`40075016.686 / 268435456 = 0.14929107087105511`。
    ///
    /// 🔴 **2026-10-07：原先的期望值 0.14930864 是错的**（差 1.757e-5 > 容差 1e-5）。
    /// 它反推出的世界宽度是 268 403 869.2（真值 2^28 = 268 435 456）、
    /// 反推出的赤道周长是 40 079 732.9 m（真值 2πR = 40 075 016.686）——
    /// **两个都不是任何标准常量**，说明它是手算笔误而非另一套约定。
    /// ⇒ 期望值改为精确值并把容差收紧到 1e-9（实现就是 `C / 2^28`，无需宽容）。
    func testMetersPerMapPointAtEquator() {
        XCTAssertEqual(CoordinateTransform.metersPerMapPoint(atLatitude: 0),
                       0.14929107087105511, accuracy: 0.000000001)
    }

    /// 高纬度的 1 mapPoint 覆盖**更少**米（cos(lat) 收缩）—— 方向别搞反。
    ///
    /// 🔴 **2026-10-07：这条断言一直是「对」的，被改的是实现。**
    /// Web Mercator 地面分辨率 = `cos(lat)·2πR / (tileEdge·2^z)` ⇒ **高纬 1 投影单位
    /// 覆盖的地面更少**。独立复算（Python，不 import 被测实现）：
    /// z7/tileEdge=256 下 1222.9925 × cos(40°) = **936.8666 m/px**，
    /// 比值 `0.766044443` 恰为 `cos 40° = 0.766044443`。
    /// 另用 Mercator 有限差分交叉验证（北京 39.909°）：
    /// 赤道/高纬的「每投影单位地面米数」之比 = 1.30368 = 1/cos(39.9095)。两个方法同向。
    ///
    ///⚠️ **旧实现（`÷ cos`）为什么长期没被发现**：唯一的交叉验证
    /// `testZoomScaleChainReproducesAnalyticMetersPerPoint` 只在**赤道**跑，
    /// 而 cos(0)=1 ⇒ `× cos` 与 `÷ cos` 在赤道取值**完全相同**，
    /// 那条「换算链自洽」的证明对 cos 的方向**毫无鉴别力**。
    func testMetersPerMapPointShrinksWithLatitude() {
        let equator = CoordinateTransform.metersPerMapPoint(atLatitude: 0)
        let at40 = CoordinateTransform.metersPerMapPoint(atLatitude: 40)
        XCTAssertLessThan(at40, equator, "40° 处 1 mapPoint 应覆盖更少米")
        XCTAssertEqual(at40 / equator, cos(40 * .pi / 180), accuracy: 0.0001)
    }

    /// 倒数关系自洽。
    func testMapPointsPerMeterIsReciprocal() {
        for lat in [0.0, 23.129, 39.909, 45.803] {
            let perPoint = CoordinateTransform.metersPerMapPoint(atLatitude: lat)
            let perMeter = CoordinateTransform.mapPointsPerMeter(atLatitude: lat)
            XCTAssertEqual(perPoint * perMeter, 1.0, accuracy: 0.000001)
        }
    }

    /// 🔴 **交叉验证**：zoomScale 与 metersPerMapPoint 组合后，
    /// 反推出的「1 屏幕点 = 多少米」必须与既有解析式 `tileEdgeMeters/256` 吻合。
    ///
    /// 这是整条换算链的**自洽性证明** —— 若MapKit 单位假设错了，这里会炸。
    /// 实测（Python）：z4 9783.9 vs 解析 9783.940；z7 1223.0 vs 1222.992。
    func testZoomScaleChainReproducesAnalyticMetersPerPoint() {
        let expected: [Int: Double] = [
            4: 9_783.940,
            5: 4_891.970,
            6: 2_445.985,
            7: 1_222.992
        ]
        for (zoom, analytic) in expected {
            let scale = CoordinateTransform.zoomScale(atZoom: zoom, tileEdge: 256)
            let metersPerPoint = 1.0 / (CoordinateTransform.mapPointsPerMeter(atLatitude: 0) * scale)
            XCTAssertEqual(metersPerPoint, analytic, accuracy: 0.5,
                           "z\(zoom) 换算链与解析式不吻合（赤道处）")
        }
    }

    /// `zoomScale` 随 zoom 线性翻倍。
    ///
    /// ⚠️ **它不随 `contentScaleFactor` 变**（2026-10-07 修正的实现 bug）。
    /// 缩放因子由 `PixelShiftProbe.magnitudeDevicePixels` **恰好施加一次**；
    /// 若`zoomScale` 里也乘一遍，`csf` 会被平方（@2x 读数虚高一倍）。
    /// `testMagnitudePointsAreIndependentOfContentScale` 是这条的端到端 counterpart。
    func testZoomScaleScalesLinearlyWithZoomOnly() {
        let z7 = CoordinateTransform.zoomScale(atZoom: 7, tileEdge: 256)
        let z4 = CoordinateTransform.zoomScale(atZoom: 4, tileEdge: 256)
        XCTAssertEqual(z7 / z4, 8.0, accuracy: 0.0001)
    }

    /// 🔴 **回归护栏**：`csf` 只能被施加**一次**（这是 2026-10-07 修掉的真实 bug）。
    ///
    /// 曾经的 `zoomScale` 把 `contentScaleFactor` 乘了进去，而
    /// `magnitudeDevicePixels` 又乘一次⇒ @2x 读数是正确值的 2 倍
    /// （北京 @2x 1.393 px，而正确值应是其一半）。本测试从**两个方向**钉住"恰好一次"：
    ///① 点量不随 csf 变（缩放因子不该进 `zoomScale`）；
    /// ② 设备像素量 = 点量 × csf，且严格线性。
    func testMagnitudePointsAreIndependentOfContentScale() {
        let at1x = CoordinateTransform.pixelShiftProbe(longitude: 116.3970, latitude: 39.9090,
                                                       zoom: 7, tileEdge: 256,
                                                       contentScaleFactor: 1)
        let at2x = CoordinateTransform.pixelShiftProbe(longitude: 116.3970, latitude: 39.9090,
                                                       zoom: 7, tileEdge: 256,
                                                       contentScaleFactor: 2)
        let at3x = CoordinateTransform.pixelShiftProbe(longitude: 116.3970, latitude: 39.9090,
                                                       zoom: 7, tileEdge: 256,
                                                       contentScaleFactor: 3)
        //① 点量与 csf 无关 —— `zoomScale` 的单位是点/mapPoint，不含设备像素比。
        XCTAssertEqual(at2x.magnitudePoints, at1x.magnitudePoints, accuracy: 0.000001,
                       "🔴 点量不得随 contentScaleFactor 变（csf 被平方的征兆）")
        XCTAssertEqual(at3x.magnitudePoints, at1x.magnitudePoints, accuracy: 0.000001)
        // ② 设备像素量 = 点量 × csf，严格线性一次。
        XCTAssertEqual(at2x.magnitudeDevicePixels, at1x.magnitudeDevicePixels * 2,
                       accuracy: 0.000001,
                       "🔴 设备像素量应恰好是点量的 2 倍（@2x），不得是 4 倍")
        XCTAssertEqual(at3x.magnitudeDevicePixels, at1x.magnitudeDevicePixels * 3,
                       accuracy: 0.000001,
                       "🔴 设备像素量应恰好是点量的 3 倍（@3x），不得是 9 倍")
    }

    /// 非法输入 → 0（不崩、不 NaN）。
    func testInvalidInputsReturnZero() {
        XCTAssertEqual(CoordinateTransform.zoomScale(atZoom: -1, tileEdge: 256), 0)
        XCTAssertEqual(CoordinateTransform.zoomScale(atZoom: 7, tileEdge: 0), 0)
        XCTAssertEqual(CoordinateTransform.metersPerMapPoint(atLatitude: 91), 0)
        XCTAssertEqual(CoordinateTransform.metersPerMapPoint(atLatitude: 90), 0,
                       "极点处cos=0，米/点趋无穷 → 必须夹成 0 防除零")
    }
}

// MARK: - 三、🔴 核心量级：平移量不足 1 设备像素

/// **本轮最重要的量级结论**：像素级平移在雷达可用区间**看不见**。
final class PixelShiftMagnitudeTests: XCTestCase {

    /// z7 @1x：北京平移 0.592 设备像素（Python 独立复算 2026-10-07）。
    ///
    /// ⚠️ **2026-10-07：0.348 → 0.592。** 旧值按`metersPerMapPoint = E / cos` 算出，
    /// 而那个 cos 方向是反的（见 `testMetersPerMapPointShrinksWithLatitude`）。
    /// 改正后高纬平移量放大`1/cos²(39.909°) = 1.700` 倍：0.348 × 1.700 = 0.592。
    func testBeijingShiftAtZ7At1x() {
        let probe = CoordinateTransform.pixelShiftProbe(
            longitude: 116.3970, latitude: 39.9090,
            zoom: 7, tileEdge: 256, contentScaleFactor: 1)
        XCTAssertEqual(probe.magnitudeDevicePixels, 0.592, accuracy: 0.005,
                       "北京 z7@1x 平移量（Python 独立复算 0.5919 px）")
        XCTAssertFalse(probe.isVisuallyDetectable)
    }

    /// 🔴 z7 @2x：北京 **1.184 px** —— **已越过 1 px，可见**。
    ///
    /// ⚠️ **2026-10-07：这条断言的结论翻转了（0.697 → 1.184）。**
    /// 旧实现按`metersPerMapPoint = E / cos`（cos 方向反了，见
    /// `testMetersPerMapPointShrinksWithLatitude`）给出 0.697 px 并断言"仍 < 1"；
    /// 改正后`0.5919 pt × 2 = 1.184 px` ⇒ **@2x 下北京肉眼可辨**。
    /// 这不是"实现变差"，而是**高纬被系统性低估**了 `1/cos²(39.909°) = 1.700` 倍。
    func testBeijingShiftAtZ7At2x() {
        let probe = CoordinateTransform.pixelShiftProbe(
            longitude: 116.3970, latitude: 39.9090,
            zoom: 7, tileEdge: 256, contentScaleFactor: 2)
        XCTAssertEqual(probe.magnitudeDevicePixels, 1.184, accuracy: 0.005,
                       "北京 z7@2x = 0.5919 pt × 2 = 1.184 px（Python 独立复算）")
        XCTAssertTrue(probe.isVisuallyDetectable,
                      "🔴 z7@2x 北京 1.184 px 已越过 1 px —— 旧实现误报为不可见")
    }

    /// 🔴 z7 @2x：**北京 1.184 px 是参考点里的最大偏移，已越过 1 px。**
    ///
    /// ⚠️ **2026-10-07：本断言从"仍不足 1 px"翻转为"已可见"。**
    /// 旧期望 0.933 px（当时认为是广州最大）建立在错误的 cos 方向上；
    /// 改正后**北京 1.184 px 越过阈值成为最大者**（高纬 `1/cos²` 放大更狠：
    /// 北京 1.700× vs 广州 1.182×）。
    /// ⚠️ 方法名里的 `StillUnderOnePixel` 已按事实改为 `IsNowVisible` ——
    /// 名字里留着 "StillUnderOnePixel" 本身就是一句假话。
    func testLargestReferenceShiftAtZ7At2xIsNowVisible() {
        let beijing = CoordinateTransform.pixelShiftProbe(
            longitude: 116.3970, latitude: 39.9090,
            zoom: 7, tileEdge: 256, contentScaleFactor: 2)
        XCTAssertEqual(beijing.magnitudeDevicePixels, 1.184, accuracy: 0.005)
        XCTAssertTrue(beijing.isVisuallyDetectable,
                      "北京 z7@2x 1.184 px 应已可辨（旧实现误报 0.697 px 不可见）")
        // @1x 那一半没有被翻转 —— 可辨性是分档的，这是分档的另一半。
        // ⚠️逐参考点断言，不经`pixelShiftIsBelowOnePixelEverywhere`（它把 csf<=1
        // 展开成 [1.0, 2.0]，会连@2x 一起测而恒为 false，掩盖 @1x 的真实结论）。
        let at1x = CoordinateTransform.pixelShiftProbe(
            longitude: 116.3970, latitude: 39.9090,
            zoom: 7, tileEdge: 256, contentScaleFactor: 1)
        XCTAssertEqual(at1x.magnitudeDevicePixels, 0.592, accuracy: 0.005,
                       "北京 z7@1x = 0.592 px（仍属不可辨那一档）")
        XCTAssertFalse(at1x.isVisuallyDetectable,
                       "🔴 @1x 北京 0.592 px 应仍不可辨 —— 这是分档的另一半")
    }

    /// 🔴 **@1x 全区间、全参考点都 < 1 px；@2x 起不再成立。**
    ///
    /// ⚠️ **2026-10-07：@2x 那一半翻转了（True → False）。**
    /// 旧实现（cos 方向反了）把高纬平移量低估 `1/cos²` 倍，
    /// 于是 @2x 下最大只有 0.933 px < 1。改正后北京 1.184 px、广州 1.104 px
    /// 均越过 1 px ⇒ 不再能声称"全不可见"。
    /// 这是**实现修正**带来的真实结论变化，不是放宽断言。
    ///
    /// ⚠️⚠️ **不能用 `pixelShiftIsBelowOnePixelEverywhere(csf: 1)` 来表达
    /// 「@1x 全不可见」**：该函数把 `csf <= 1.0` **展开成 [1.0, 2.0]**
    /// （`CoordinateTransform.swift:658`，本意是"按常见档位保守估计"），
    /// 故它连@2x 一起测 ⇒ 修cos 后它对 csf=1/2/3 **一律返回 `false`**。
    /// 「@1x 全不可见」这条性质必须**逐参考点直接断言**（见下），
    /// 否则会被那个展开逻辑掩盖成false。
    func testNoReferencePointReachesOnePixelAcrossRadarZooms() {
        //① @1x：逐参考点、逐层断言 < 1 设备像素（不经上面那个会展开的函数）。
        for zoom in RadarTileZoomRange.minimum...RadarTileZoomRange.maximum {
            for point in CoordinateTransform.probeReferencePoints {
                let probe = CoordinateTransform.pixelShiftProbe(
                    longitude: point.longitude, latitude: point.latitude,
                    zoom: zoom, tileEdge: 256, contentScaleFactor: 1)
                XCTAssertLessThan(probe.magnitudeDevicePixels, 1.0,
                                  "@1x z\(zoom) \(point.name)应不足 1 设备像素，"
                                  + "实际 \(probe.magnitudeDevicePixels)")
                XCTAssertFalse(probe.isVisuallyDetectable)
            }
        }
        // ② 三个档位下该函数都返回 false（因其覆盖 @2x 及以上）。
        for csf in [1.0, 2.0, 3.0] {
            XCTAssertFalse(
                CoordinateTransform.pixelShiftIsBelowOnePixelEverywhere(tileEdge: 256,
                                                                        contentScaleFactor: csf),
                "@\(Int(csf))x 不应再声称全不可见（北京 z7 已越过 1 px）")
        }
    }

    /// 🔴 反向边界：**@3x + z7** 时部分参考点**确实越过** 1 px。
    ///
    /// ⚠️ 诚实记录：不是"任何设备上都看不见"。@3x 屏上 z7 广州 **1.656 px**。
    /// ⚠️ **2026-10-07：1.400 → 1.656**（cos 方向修正后高纬放大了
    /// `1/cos²(23.129°) = 1.182` 倍：0.467 × 1.182 × 3 = 1.656）。
    /// 这条断言的方向（`> 1.0`）始终正确，只是量值随实现修正上修。
    func testAt3xSomePointsDoBecomeVisible() {
        let probe = CoordinateTransform.pixelShiftProbe(
            longitude: 113.2640, latitude: 23.1290,
            zoom: 7, tileEdge: 256, contentScaleFactor: 3)
        XCTAssertGreaterThan(probe.magnitudeDevicePixels, 1.0,
                             "@3x + z7 时广州应越过 1 设备像素（实测 1.656 px）")
        XCTAssertTrue(probe.isVisuallyDetectable)
        XCTAssertFalse(
            CoordinateTransform.pixelShiftIsBelowOnePixelEverywhere(tileEdge: 256,
                                                                    contentScaleFactor: 3),
            "@3x 不该再声称全不可见")
    }

    /// 🔴 **回归护栏**：可辨性是**按倍率分档**的性质，不是无条件常数。
    ///
    /// ── 这条守的是什么 ──────────────────────────────────────────────
    /// 代码里多处文案曾笼统写"平移量不足 1 px ⇒ 看不见"。**这句话只在
    /// @1x 成立**：@2x 起（z7 北京 1.184 px）就已可辨。一旦有人把@2x 也算进来、
    /// 或把 `csf` 重复施加一次，无条件说法就会悄悄变回假话。
    ///
    /// ── 性质本身 ────────────────────────────────────────────────────
    /// `magnitudeDevicePixels = 基量 × 2^(z−7) × csf` —— 对 z、对 csf 都**线性**。
    /// 故"是否 ≥ 1 px"等价于 `csf ≥ csf* = 1 / 基量`，是一个**阈值**问题。
    /// 实测 z7 各参考点的 `csf*`（Python 独立复算，2026-10-07 cos 修正后）：
    /// 北京 **1.69** / 广州 **1.81** / 上海 **2.19** / 成都 **2.91** / 乌鲁木齐 **3.32**
    /// ⇒ **@1x 全在阈值下方；@2x 越过北京、广州两个；@3x 再越过上海、成都。**
    ///
    /// ⚠️ **2026-10-07：`csf*` 全体下修（旧值 2.87/2.14/2.99/3.92/6.37 是
    /// 按错误的 cos 方向算的）**，所以分档边界从"@2x 全不可见"移到了"@1x 全不可见"。
    ///
    /// 期望值来源：Python 独立复刻同一套公式（不 import 被测实现）。
    func testDetectabilityIsTieredByScaleNotAConstant() {
        // ① 严格线性：对每个参考点，@3x 读数应恰好是 @1x 的 3 倍。
        for point in CoordinateTransform.probeReferencePoints {
            let at1x = CoordinateTransform.pixelShiftProbe(
                longitude: point.longitude, latitude: point.latitude,
                zoom: 7, tileEdge: 256, contentScaleFactor: 1)
            let at2x = CoordinateTransform.pixelShiftProbe(
                longitude: point.longitude, latitude: point.latitude,
                zoom: 7, tileEdge: 256, contentScaleFactor: 2)
            let at3x = CoordinateTransform.pixelShiftProbe(
                longitude: point.longitude, latitude: point.latitude,
                zoom: 7, tileEdge: 256, contentScaleFactor: 3)
            XCTAssertEqual(at2x.magnitudeDevicePixels,
                           at1x.magnitudeDevicePixels * 2, accuracy: 0.000001,
                           "\(point.name)：@2x 应恰好是 @1x 的 2倍")
            XCTAssertEqual(at3x.magnitudeDevicePixels,
                           at1x.magnitudeDevicePixels * 3, accuracy: 0.000001,
                           "\(point.name)：@3x 应恰好是 @1x 的 3 倍")
            // ② 阈值单调：一旦某倍率可辨，更高倍率必可辨（csf* 存在且唯一）。
            if at2x.isVisuallyDetectable {
                XCTAssertTrue(at3x.isVisuallyDetectable,
                              "\(point.name)：@2x 已可辨则 @3x 必可辨（单调性）")
            }
        }
        // ③ 分档结论钉死：**@1x 全不可见；@2x/@3x 都不成立。**
        // ⚠️ @1x 用**逐参考点**判定：该helper 把 csf<=1 展开成 [1.0,2.0]，
        // 修 cos 后对 csf=1 也会返回 false（因为 @2x 已越过 1 px）。
        for point in CoordinateTransform.probeReferencePoints {
            let at1x = CoordinateTransform.pixelShiftProbe(
                longitude: point.longitude, latitude: point.latitude,
                zoom: 7, tileEdge: 256, contentScaleFactor: 1)
            XCTAssertFalse(at1x.isVisuallyDetectable,
                           "@1x \(point.name)（\(at1x.magnitudeDevicePixels) px）应不可辨")
        }
        XCTAssertFalse(CoordinateTransform.pixelShiftIsBelowOnePixelEverywhere(
            tileEdge: 256, contentScaleFactor: 2),
            "🔴 @2x 不应再声称全不可辨（北京 1.184 px）")
        XCTAssertFalse(CoordinateTransform.pixelShiftIsBelowOnePixelEverywhere(
            tileEdge: 256, contentScaleFactor: 3), "@3x 不应再声称全不可辨")
    }

    /// 🔴 **摘要必须随倍率改口**：@2x 就不能还写"肉眼不可辨"。
    ///
    /// 依据：`UIScreen.main.scale` 在真机上是 2 或 3，此时 z7 广州
    /// 分别是 **1.104 px / 1.656 px**，**确实可见**。若摘要无条件写"肉眼不可辨"，
    /// 就是对用户说假话。
    ///
    /// ⚠️ **2026-10-07：@2x 这一半翻转了**（广州 0.933 → 1.104 px）。
    /// 旧实现低估高纬`1/cos²` 倍，才让 @2x 看起来仍不可辨。
    /// 用**上海**（@2x 0.915 px，仍不可辨）与**广州**（@2x 1.104 px，可见）
    /// 做对照，确保摘要真按倍率/量值改口，而不是无条件写死任一措辞。
    func testSummaryStatesDetectabilityPerScale() {
        let guangzhou2x = CoordinateTransform.pixelShiftProbe(
            longitude: 113.2640, latitude: 23.1290,
            zoom: 7, tileEdge: 256, contentScaleFactor: 2)
        let shanghai2x = CoordinateTransform.pixelShiftProbe(
            longitude: 121.4900, latitude: 31.2400,
            zoom: 7, tileEdge: 256, contentScaleFactor: 2)
        let guangzhou3x = CoordinateTransform.pixelShiftProbe(
            longitude: 113.2640, latitude: 23.1290,
            zoom: 7, tileEdge: 256, contentScaleFactor: 3)
        // 🔴 @2x 广州 1.104 px 已可辨 —— 不得声称肉眼不可辨。
        XCTAssertTrue(guangzhou2x.summary.contains("可见"),
                      "@2x 广州（1.104 px）必须标可见，实际：\(guangzhou2x.summary)")
        XCTAssertFalse(guangzhou2x.summary.contains("肉眼不可辨"),
                       "@2x 广州不得声称肉眼不可辨 —— 那是假话，实际：\(guangzhou2x.summary)")
        // 同为 @2x，上海 0.915 px 确实仍不可辨 —— 证明措辞是按量值分档的。
        XCTAssertTrue(shanghai2x.summary.contains("肉眼不可辨"),
                      "@2x 上海（0.915 px）应标肉眼不可辨，实际：\(shanghai2x.summary)")
        XCTAssertTrue(guangzhou3x.summary.contains("可见"),
                      "@3x 广州（1.656 px）必须标可见，"
                      + "不得写『肉眼不可辨』，实际：\(guangzhou3x.summary)")
        XCTAssertFalse(guangzhou3x.summary.contains("肉眼不可辨"),
                       "@3x 广州不得声称肉眼不可辨 —— 那是假话，实际：\(guangzhou3x.summary)")
        // 读数本身也必须随倍率变化（否则等于没施加缩放因子）。
        XCTAssertNotEqual(guangzhou2x.summary, guangzhou3x.summary)
    }

    /// 平移量随 zoom 线性翻倍（z4 → z7 共 8倍）。
    func testShiftScalesWithZoom() {
        let atZ4 = CoordinateTransform.pixelShiftProbe(
            longitude: 116.3970, latitude: 39.9090,
            zoom: 4, tileEdge: 256, contentScaleFactor: 1)
        let atZ7 = CoordinateTransform.pixelShiftProbe(
            longitude: 116.3970, latitude: 39.9090,
            zoom: 7, tileEdge: 256, contentScaleFactor: 1)
        XCTAssertEqual(atZ7.magnitudePoints / atZ4.magnitudePoints, 8.0, accuracy: 0.001)
    }

    /// 探针的偏移米数必须与既有 `OffsetProbe` **一致**（同一份 GCJ 计算）。
    func testPixelShiftProbeAgreesWithOffsetProbe() {
        let shift = CoordinateTransform.pixelShiftProbe(
            longitude: 116.3970, latitude: 39.9090,
            zoom: 7, tileEdge: 256, contentScaleFactor: 1)
        let offset = CoordinateTransform.offsetProbe(longitude: 116.3970, latitude: 39.9090)
        XCTAssertEqual(shift.distanceMeters, offset.distanceMeters, accuracy: 0.0001,
                       "两个探针的偏移米数必须同源")
        XCTAssertEqual(shift.eastMeters, offset.eastMeters, accuracy: 0.0001)
        XCTAssertEqual(shift.northMeters, offset.northMeters, accuracy: 0.0001)
    }

    /// 摘要必须**自带**与量值相符的可辨性标注（不得无条件写死措辞）。
    ///
    /// 🔴 **2026-10-07：这条测试的取样点/@2x 组合已不再适用。**
    /// 旧版取北京 @2x 并要求"不足 1 px，肉眼不可辨"；cos 方向修正后
    /// 北京 @2x 是 **1.184 px（可见）**，故改用 @1x（0.592 px，不可辨）
    /// 与 @2x（可见）成对断言，确保措辞随量值切换。
    func testSummaryStatesDetectabilityHonestLy() {
        let at1x = CoordinateTransform.pixelShiftProbe(
            longitude: 116.3970, latitude: 39.9090,
            zoom: 7, tileEdge: 256, contentScaleFactor: 1)
        XCTAssertTrue(at1x.summary.contains("不足 1 px"),
                      "@1x 摘要应说明不足 1 px，实际：\(at1x.summary)")
        XCTAssertTrue(at1x.summary.contains("肉眼不可辨"),
                      "@1x 摘要应明说肉眼不可辨，实际：\(at1x.summary)")
        // 不得在 @1x 上谎称可见。
        XCTAssertFalse(at1x.summary.contains(" · 可见"),
                       "@1x 北京 0.592 px 不得声称可见，实际：\(at1x.summary)")
    }
}

// MARK: - 四、平移档位（RadarPixelShiftMode）

/// 档位语义：默认关闭、方向符号明确、非法值回落安全档。
final class RadarPixelShiftModeTests: XCTestCase {

    /// 🔴 **默认必须是不平移** —— 方向未验证时默认开平移是制造假信号。
    func testDefaultIsOff() {
        XCTAssertFalse(RadarPixelShiftMode.from(rawValue: nil).appliesShift)
        XCTAssertFalse(RadarPixelShiftMode.from(rawValue: "不存在的档位").appliesShift,
                       "非法值必须回落到 .off（安全档），而非某个平移档")
        XCTAssertEqual(RadarPixelShiftMode.from(rawValue: nil), .off)
    }

    /// 三档齐备，且只有 `.off` 不平移。
    func testExactlyThreeCasesAndOnlyOffIsNoShift() {
        XCTAssertEqual(RadarPixelShiftMode.allCases.count, 3)
        XCTAssertFalse(RadarPixelShiftMode.off.appliesShift)
        XCTAssertTrue(RadarPixelShiftMode.shiftAlongCorrection.appliesShift)
        XCTAssertTrue(RadarPixelShiftMode.shiftOppositeCorrection.appliesShift)
    }

    /// 两个平移档的符号**互为相反数**（供真机 A/B）。
    func testShiftDirectionsAreOpposite() {
        XCTAssertEqual(RadarPixelShiftMode.shiftAlongCorrection.directionSign, 1.0, accuracy: 0.0001)
        XCTAssertEqual(RadarPixelShiftMode.shiftOppositeCorrection.directionSign, -1.0, accuracy: 0.0001)
        XCTAssertEqual(RadarPixelShiftMode.off.directionSign, 0.0, accuracy: 0.0001)
    }

    /// 沿纠偏方向的档位，文案**必须**带「方向未验证」字样。
    func testShiftModeNamesStateDirectionIsUnverified() {
        XCTAssertTrue(RadarPixelShiftMode.shiftAlongCorrection.displayName.contains("方向未验证"),
                      "文案必须如实说明方向未验证，实际："
                      + RadarPixelShiftMode.shiftAlongCorrection.displayName)
    }

    /// 🔴 **任何档位的文案都不许出现"已纠偏"** —— 那会误导用户。
    func testNoModeNameClaimsCorrectionIsApplied() {
        for mode in RadarPixelShiftMode.allCases {
            XCTAssertFalse(mode.displayName.contains("已纠偏"),
                           "档位文案不得声称已纠偏，实际：\(mode.displayName)")
            XCTAssertFalse(mode.displayName.contains("已对齐"),
                           "档位文案不得声称已对齐，实际：\(mode.displayName)")
        }
    }

    /// 解析与持久化往返。
    func testRawValueRoundTrip() {
        for mode in RadarPixelShiftMode.allCases {
            XCTAssertEqual(RadarPixelShiftMode.from(rawValue: mode.rawValue), mode)
        }
    }
}

/// 验证平移量能落进诊断记录（真机验收的读数出口）。
final class PixelShiftDiagnosticsTests: XCTestCase {

    /// 落盘文案必须含平移量、档位、以及「方向未验证」这句免责。
    func testRecordPixelShiftWritesHonestMessage() {
        let suite = "zs.tests.pixelshift.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppDiagnosticsStore(defaults: defaults)
        AppDiagnosticsStore.recordRadarPixelShift(mode: .shiftAlongCorrection,
                                                  longitude: 116.3970,
                                                  latitude: 39.9090,
                                                  contentScaleFactor: 2,
                                                  store: store)
        let entry = store.latest(for: .radarOffsetProbe)
        XCTAssertNotNil(entry, "应落一条radarOffsetProbe 记录")
        let message = entry?.message ?? ""
        XCTAssertTrue(message.contains("平移"), "应写明平移档位，实际：\(message)")
        XCTAssertTrue(message.contains("方向未验证"),
                      "🔴 必须写明纠偏方向未验证（R1），实际：\(message)")
        XCTAssertTrue(message.contains("设备像素"),
                      "应写明单位是设备像素，实际：\(message)")
        XCTAssertFalse(message.contains("已纠偏"),
                       "🔴 诊断文案不得声称已纠偏，实际：\(message)")
    }

    /// `.off` 档也要落盘（真机需要确认「确实没开」）。
    func testRecordPixelShiftWorksWhenOff() {
        let suite = "zs.tests.pixelshift.off.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppDiagnosticsStore(defaults: defaults)
        AppDiagnosticsStore.recordRadarPixelShift(mode: .off,
                                                  longitude: 139.6917,
                                                  latitude: 35.6895,
                                                  contentScaleFactor: 2,
                                                  store: store)
        let message = store.latest(for: .radarOffsetProbe)?.message ?? ""
        XCTAssertFalse(message.isEmpty, "关闭档也应落盘（真机需确认「确实没开」）")
        XCTAssertTrue(message.contains("不平移"), "应写明是不平移档，实际：\(message)")
    }

    /// 摘要列表覆盖全部参考点（诊断不能少行）。
    ///
    /// 🔴 **2026-10-07：原先断言写死`"px@z7"`，与实现的实际格式不符 ⇒ 改测试。**
    /// 实现 `PixelShiftProbe.summary`（`CoordinateTransform.swift:465-471`）产出的是
    /// `北京天安门 平移 0.70 px@7/2.0x（555 m） · 不足 1 px，肉眼不可辨`
    /// —— 形如 `px@<zoom>/<csf>x`，**没有 `z` 前缀**，且**额外带了缩放因子**。
    /// 实现是对的：那个 `z7` 期望值来自**另一个函数**
    /// `probeSummaries`（`CoordinateTransform.swift:829`，产出 `≈ <px> px@z7`）——
    /// 两条不同的摘要链，格式本就不同，断言张冠李戴了。
    /// 而且带上 `csf` 是**必须**的：可辨性按倍率分档（见
    /// `testDetectabilityIsTieredByScaleNotAConstant`），只写 `px@z7`
    /// 会让读数看不出是@1x/@2x/@3x 哪一档 —— 那才是有害的模糊。
    func testPixelShiftSummariesCoverEveryReferencePoint() {
        let lines = CoordinateTransform.pixelShiftSummaries(tileEdge: 256,
                                                            zoom: 7,
                                                            contentScaleFactor: 2)
        XCTAssertEqual(lines.count, CoordinateTransform.probeReferencePoints.count)
        for line in lines {
            // 实现的格式是 `px@7/2.0x`：层级 + 缩放因子，二者都要在。
            XCTAssertTrue(line.contains("px@7/2.0x"),
                          "每行应含层级与缩放因子（格式 px@z/scale），实际：\(line)")
            // 🔴 可见性判定**按倍率分档**，@2x 下不再全是"肉眼不可辨"：
            // 修正 cos 方向后北京 1.18 px、广州 1.10 px 已越过 1 px（见下）。
            // 故此处只能要求"每行都如实标注可辨性"，不能钉死具体措辞。
            XCTAssertTrue(line.contains("可见") || line.contains("肉眼不可辨"),
                          "每行都应如实标注可辨性，实际：\(line)")
            // 不得出现"不足 1 px"却同时越过 1 px这类自相矛盾的表述。
            if line.contains("不足 1 px") {
                XCTAssertFalse(line.contains(" · 可见"),
                              "标『不足 1 px』的行不得又声称可见，实际：\(line)")
            }
        }
        //分档事实本身要钉住：@2x 下北京/广州可见、其余不可见（Python 独立复算）。
        XCTAssertTrue(lines[0].contains("可见"), "北京@2x 1.18 px 应标可见，实际：\(lines[0])")
        XCTAssertTrue(lines[1].contains("肉眼不可辨"),
                      "上海 @2x 0.92 px 应标肉眼不可辨，实际：\(lines[1])")
        XCTAssertTrue(lines[2].contains("可见"), "广州 @2x 1.10 px 应标可见，实际：\(lines[2])")
    }

    /// 定点格式辅助函数不得产出"-0.00" 这类看起来像 bug 的读数。
    ///
    /// ⚠️ **2026-10-07：`decimal2(1.4)` 曾返回 "1.39"（CI 报 1.39 ≠ 1.40）。
    /// 错的是实现** —— 它对已经四舍五入过的定点数再做一次**截断**
    /// （`Int((scaled - whole) * 100)`）：1.4 - 1.0 在二进制下是
    /// 0.3999999999999999 → ×100 = 39.99999999999999 → 截断成 **39**。
    /// ⇒ 期望值 "1.40" 是对的（1.4 就该显示 1.40），修实现。
    func testDecimalHelpersAvoidNegativeZero() {
        XCTAssertEqual(CoordinateTransform.decimal2(0.0), "0.00")
        XCTAssertEqual(CoordinateTransform.decimal2(0.004), "0.00")
        XCTAssertEqual(CoordinateTransform.decimal2(-0.004), "0.00")
        XCTAssertEqual(CoordinateTransform.decimal2(0.931), "0.93")
        XCTAssertEqual(CoordinateTransform.decimal2(1.4), "1.40")
        XCTAssertEqual(CoordinateTransform.decimal2(-1.4), "-1.40")
        XCTAssertEqual(CoordinateTransform.decimal1(2.0), "2.0")
        XCTAssertEqual(CoordinateTransform.decimal1(3.0), "3.0")
    }

    /// 🔴 **回归护栏**：`decimal2` / `decimal1` 的小数位必须**四舍五入**，不能截断。
    ///
    /// 截断会在"定点数的二进制表示略小于十进制直觉值"时集体下偏一格：
    /// `1.4 - 1.0 == 0.3999999999999999` → ×100 = 39.999... → `Int(...)` = 39
    /// → "1.39"。这在诊断面板上表现为**读数与真值差 0.01**，会被误当成"测量抖动"。
    ///
    /// 本测试把这批"看起来该进位"的边界值逐个钉住（Python 复刻同一套公式核对过）。
    func testDecimalHelpersRoundRatherThanTruncate() {
        // 二进制下略小于直觉值的经典样本 —— 截断实现全都会少1 格。
        XCTAssertEqual(CoordinateTransform.decimal2(1.4), "1.40", "1.4 必须显示 1.40")
        XCTAssertEqual(CoordinateTransform.decimal2(-1.4), "-1.40", "负值同样受影响")
        XCTAssertEqual(CoordinateTransform.decimal2(1.1), "1.10")
        XCTAssertEqual(CoordinateTransform.decimal2(2.9), "2.90")
        XCTAssertEqual(CoordinateTransform.decimal2(1.393), "1.39", "修复前的实际读数")
        XCTAssertEqual(CoordinateTransform.decimal2(0.7), "0.70")
        // 三位输入按两位定点四舍五入，而非截断。
        XCTAssertEqual(CoordinateTransform.decimal2(0.567), "0.57")
        XCTAssertEqual(CoordinateTransform.decimal2(0.564), "0.56")
        // 已在两位边界上的值不得被"进位"成 3 位（如 1.999 → 2.00，不是 2.100）。
        XCTAssertEqual(CoordinateTransform.decimal2(1.999), "2.00")
        XCTAssertEqual(CoordinateTransform.decimal2(9.999), "10.00")
        XCTAssertEqual(CoordinateTransform.decimal2(-9.999), "-10.00")
        // decimal1 同病：`1.4` 曾会显示成 "1.3"。
        XCTAssertEqual(CoordinateTransform.decimal1(1.4), "1.4")
        XCTAssertEqual(CoordinateTransform.decimal1(2.9), "2.9")
        XCTAssertEqual(CoordinateTransform.decimal1(-1.4), "-1.4", "负号位也要保留")
        XCTAssertEqual(CoordinateTransform.decimal1(0.25), "0.3", "0.25 → 四舍五入到 0.3")
        XCTAssertEqual(CoordinateTransform.decimal1(1.0), "1.0")
    }
}

// MARK: - 六、MapKit 侧渲染器（`ShiftedTileOverlayRenderer`）

/// 验证绘制期平移的接线：**`.off` 必须与原生渲染逐像素一致**。
///
/// ⚠️ 这些用例**只验纯函数 `shiftVector`**，不真跑 MapKit 渲染
/// （那需要真机/ 模拟器）。可执行的部分是「档位→ 向量」的映射与钳制。
///
/// ⚠️ **整体标 `@MainActor`**：`testShiftVectorMatchesCoreProbeMagnitude` 要读
/// `UIScreen.main.scale`（`shiftVector` 内部也读同一个量，两边必须同源），
/// 而 `UIScreen.main` 是 **`@MainActor` 隔离**的 —— 非隔离的同步用例读它会报
/// "call to main actor-isolated property 'main' in a synchronous nonisolated
/// context"（本仓 P-04 / P-06 铁律的同类形态）。
@MainActor
final class ShiftedTileOverlayRendererTests: XCTestCase {

    /// `.off` → 零向量（⇒ renderer 走原生路径，**不改任何渲染行为**）。
    func testOffModeProducesZeroShift() {
        let center = CLLocationCoordinate2D(latitude: 39.9090, longitude: 116.3970)
        let shift = ShiftedTileOverlayRenderer.shiftVector(for: center, mode: .off)
        XCTAssertEqual(shift.dx, 0, "关闭档必须零平移")
        XCTAssertEqual(shift.dy, 0, "关闭档必须零平移")
    }

    /// 两个平移档的向量**互为相反数**（A/B 对照成立）。
    func testShiftModesAreExactOpposites() {
        let center = CLLocationCoordinate2D(latitude: 39.9090, longitude: 116.3970)
        let along = ShiftedTileOverlayRenderer.shiftVector(for: center,
                                                           mode: .shiftAlongCorrection)
        let opposite = ShiftedTileOverlayRenderer.shiftVector(for: center,
                                                              mode: .shiftOppositeCorrection)
        XCTAssertEqual(along.dx, -opposite.dx, accuracy: 0.000001)
        XCTAssertEqual(along.dy, -opposite.dy, accuracy: 0.000001)
        XCTAssertNotEqual(along.dx, 0, "北京偏移非零，平移量应非零")
    }

    /// 境外城市（如东京）偏移为 0 → 平移向量必须是 0（不多余地挪境外回波）。
    func testOverseasCityGetsNoShift() {
        let tokyo = CLLocationCoordinate2D(latitude: 35.6895, longitude: 139.6917)
        for mode in [RadarPixelShiftMode.shiftAlongCorrection,
                     .shiftOppositeCorrection] {
            let shift = ShiftedTileOverlayRenderer.shiftVector(for: tokyo, mode: mode)
            XCTAssertEqual(shift.dx, 0, accuracy: 0.000001,
                           "境外（框外）纠偏偏移为 0，不该平移")
            XCTAssertEqual(shift.dy, 0, accuracy: 0.000001)
        }
    }

    /// 平移向量模长应与Core 探针一致（同一条换算链的两次实现必须吻合）。
    func testShiftVectorMatchesCoreProbeMagnitude() {
        let center = CLLocationCoordinate2D(latitude: 39.9090, longitude: 116.3970)
        let shift = ShiftedTileOverlayRenderer.shiftVector(
            for: center, mode: .shiftAlongCorrection)
        let probe = CoordinateTransform.pixelShiftProbe(
            longitude: center.longitude, latitude: center.latitude,
            zoom: RadarTileZoomRange.maximum,
            tileEdge: CGFloat(RadarTileURLBuilder.tileEdge),
            contentScaleFactor: Double(UIScreen.main.scale))
        let magnitude = (shift.dx * shift.dx + shift.dy * shift.dy).squareRoot()
        XCTAssertEqual(magnitude, probe.magnitudePoints, accuracy: 0.0001,
                       "平移向量模长应等于 Core 探针算出的点量")
    }

    /// 🔴 平移量级护栏：z7 下平移**不足 1 屏幕点**（北京，任意档位）。
    ///
    /// 这条是「不要误以为平移开了就有效果」的护栏 —— 若将来RainViewer
    /// 支持更高 zoom，该断言可能翻false，届时必须同步更新注释说明。
    ///
    /// ⚠️ 注：这里比的是**点**（不是设备像素），故与倍率无关。
    /// 北京 z7 = **0.592 pt**（旧实现 0.348 pt，cos 修正后 ×1.700）。
    /// ⚠️ **@2x/@3x 下换算成设备像素会越过 1 px**（1.184/ 1.776），
    /// 但那属于"设备像素"层面的可见性，见`testDetectabilityIsTieredByScaleNotAConstant`。
    func testShiftVectorIsUnderOnePointAtRadarMaxZoom() {
        let center = CLLocationCoordinate2D(latitude: 39.9090, longitude: 116.3970)
        let shift = ShiftedTileOverlayRenderer.shiftVector(
            for: center, mode: .shiftAlongCorrection)
        let magnitude = (shift.dx * shift.dx + shift.dy * shift.dy).squareRoot()
        XCTAssertLessThan(magnitude, 1.0,
                          "北京 z7 平移应不足 1 屏幕点（实测约 0.59pt@z7）")
    }
}

// MARK: - 五、平移机制不改瓦片请求 ⇒ 惰性证明仍然为真

/// **本轮的关键衔接**：像素级平移是**绘制期**行为，
/// 它**不改变** `correctedTileCoordinates` 的输出 ⇒ 昨天的惰性证明继续成立。
final class PixelShiftPreservesInertnessTests: XCTestCase {

    /// 🔴 惰性证明**继续为真**（z4–z7 纠偏仍不改瓦片索引）。
    ///
    /// ⚠️ **为什么平移没有让它失效**：平移发生在 `draw`（渲染），
    /// 而惰性说的是**请求**（`url(forTilePath:)`）—— 两者是不同层。
    /// ⇒ 平移量再大，瓦片 URL 也不变；「切档看对齐」**依然无效**。
    /// 若将来有人把平移塞进请求层，这条测试就是护栏。
    func testCorrectionRemainsInertAfterPixelShiftWasAdded() {
        XCTAssertTrue(
            CoordinateTransform.correctionIsInertAcrossRadarZooms(maximumOffsetMeters: 663.0),
            "像素级平移不改变瓦片请求 ⇒ 纠偏在 z4–z7 仍是恒等变换")
    }

    /// 惰性直接断言：三态在z4–z7 产生**完全相同**的瓦片索引（复刻覆盖层算法）。
    ///
    /// 这条是"切档验收方法无效"的**直接**依据：同一瓦片路径下，
    /// `.autoAssumeNotApplied`（纠偏）与 `.disabled`（不纠偏）算出的 x/y **逐个相等**。
    /// 本测试在 Core 层复刻 `RadarTileOverlay.correctedTileCoordinates` 的算法，
    /// 不 import MapKit —— 它验的是**纯几何**，与渲染无关。
    func testAllModesStillProduceIdenticalTileIndicesAcrossRadarZooms() {
        for zoom in RadarTileZoomRange.minimum...RadarTileZoomRange.maximum {
            let uncorrected = indices(x: 105, y: 48, z: zoom, applying: .disabled)
            let corrected = indices(x: 105, y: 48, z: zoom, applying: .autoAssumeNotApplied)
            XCTAssertEqual(corrected.x, uncorrected.x,
                           "z\(zoom)：纠偏不应改变 x（惰性）")
            XCTAssertEqual(corrected.y, uncorrected.y,
                           "z\(zoom)：纠偏不应改变 y（惰性）")
        }
    }

    /// 按给定模式复算瓦片索引（**复刻 `RadarTileOverlay.correctedTileCoordinates`**）。
    ///
    /// - Parameters:
    ///   - x: 瓦片 x。
    ///   - y: 瓦片 y。
    ///   - z: 瓦片层级。
    ///   - mode: 纠偏模式。
    /// - Returns: 实际会请求的 (x, y)。
    private func indices(x: Int, y: Int, z: Int,
                         applying mode: CoordinateTransformMode) -> (x: Int, y: Int) {
        let clamped = RadarTileZoomRange.clamp(z)
        let span = Double(1 << clamped)
        let lon = (Double(x) + 0.5) / span * 360.0 - 180.0
        let lat = atan(sinh(.pi * (1 - 2 * (Double(y) + 0.5) / span))) * 180.0 / .pi
        let g = CoordinateTransform.applyMode(mode, longitude: lon, latitude: lat)
        let newX = Int(floor((g.longitude + 180.0) / 360.0 * span))
        let newY = Int(floor((1.0 - asinh(tan(g.latitude * .pi / 180.0)) / .pi) / 2.0 * span))
        return (x: min(max(newX, 0), Int(span) - 1),
                y: min(max(newY, 0), Int(span) - 1))
    }

    /// 🆕 **平移与索引是两条独立的路**（本轮架构决策的护栏）。
    ///
    /// 平移量 < 1 px（绘制期），而改索引需要 > 半格（156 km @z7）。
    /// 二者量级差 **2 个数量级以上** ⇒ 不存在"平移量够大到能改索引"的情形。
    ///
    /// 🔴 **2026-10-07：这条断言的「本意」是对的，错的是它自己的单位算术。**
    /// 原写法 `magnitudeDevicePixels * metersPerPixel(atZoom:tileEdge:)` 有**两处**缺陷：
    ///① **csf 被施加了两次** —— `magnitudeDevicePixels` 已含 `csf`（设备像素），
    ///   而 `metersPerPixel` 返回的是**米/点**；两者相乘单位不匹配（px·m/pt ≠ m）。
    ///   广州 @csf=3 因此读成 1712 m，真值应按**点**算：0.552 pt × 1124.692 m/pt = 620.7 m。
    ///② 用了**赤道处**的米/点去乘一个**广州（23.129°N）**的点 ——
    ///   真实米/点 = 1222.992 × cos(23.129°) = **1124.692**。
    /// 两处缺陷叠加 ⇒ 1712 / 1565 = 1.094，看着"只差 9.4%"，其实是**算错了**，
    /// 而非"量级关系不成立"。改正后 620.70 m 比半格小 **252 倍**（2.40 个数量级），
    /// 远小于 `margin/100 = 1565.43` ⇒ **原阈值无需改动**。
    ///
    /// 独立复算（Python）：`magnitudePoints × mPerPoint(cos lat)` 必须**恒等于**
    /// `distanceMeters` —— 因为整条链就是把米数换算成点再换算回米。
    /// 实测 0.551888 pt × 1124.69174 m/pt = 620.703591 m = `distanceMeters`（误差 0）。
    func testPixelShiftIsOrdersOfMagnitudeSmallerThanTileMargin() {
        let shift = CoordinateTransform.pixelShiftProbe(
            longitude: 113.2640, latitude: 23.1290,
            zoom: 7, tileEdge: 256, contentScaleFactor: 3)
        let marginMeters = CoordinateTransform.halfTileMarginMeters(atZoom: 7)
        // 🔴 用**点**（不是设备像素）配**该纬度**的米/点，单位才闭合。
        //metersPerPixel 返回赤道处的米/点，需乘 cos(lat) 才是本纬度的真值。
        let metersPerPointHere = CoordinateTransform.metersPerPixel(atZoom: 7, tileEdge: 256)
            * cos(23.129 * .pi / 180.0)
        let shiftMeters = shift.magnitudePoints * metersPerPointHere
        // 换算链必须自洽：点 → 米 换回来应当就是原始偏移米数。
        XCTAssertEqual(shiftMeters, shift.distanceMeters, accuracy: 0.000001,
                       "换算链不自洽：点×米/点 应恒等于 distanceMeters")
        XCTAssertLessThan(shiftMeters, marginMeters / 100,
                          "平移量应比半格小两个数量级以上（实测 620.7 m vs 156543 m，252 倍）")
        XCTAssertTrue(CoordinateTransform.correctionIsInertAcrossRadarZooms(
            maximumOffsetMeters: 663.0),
            "索引路径依旧惰性")
    }
}

// MARK: - 五、🔴 设置页接线：写入 → store 读回（本轮新增）

/// **本轮要修的正是那个真阻塞**：`RadarPixelShiftStore.set` 全仓零调用点，
/// 设置页没有平移 Picker ⇒ 真机上档位恒为 `.off`，d715851 的平移机制是死代码。
///
///⚠️ 下面两条测试分别锁「**能写进store**」与「**UI 里真有调用点**」——
/// 后者防的正是本项目栽过的那次「组件交付了但没接进渲染路径」。
final class PixelShiftSettingsWiringTests: XCTestCase {

    /// 🔴 设置页写入 → `RadarPixelShiftStore.current()` 读回（**往返**）。
    ///
    /// ⚠️ `RadarPixelShiftStore` 写的是 `UserDefaults.standard`（**不接受注入 suite**，
    /// 与 `UnitPreference` / `AppearanceStore` 不同）⇒ 本测试必须**快照-复原**，
    /// 否则会污染单测宿主的真实偏好。复原放在 `defer`，失败也照样执行。
    func testStoreWriteThenReadBackRoundTrips() {
        let savedValue = UserDefaults.standard.string(forKey: RadarPixelShiftStore.key)
        defer {
            if let savedValue {
                UserDefaults.standard.set(savedValue, forKey: RadarPixelShiftStore.key)
            } else {
                UserDefaults.standard.removeObject(forKey: RadarPixelShiftStore.key)
            }
        }

        for mode in RadarPixelShiftMode.allCases {
            RadarPixelShiftStore.set(mode)
            XCTAssertEqual(RadarPixelShiftStore.current(), mode,
                           "设置页选「\(mode.displayName)」后应能读回同一档位")
            XCTAssertEqual(UserDefaults.standard.string(forKey: RadarPixelShiftStore.key),
                           mode.rawValue,
                           "落盘值应逐字等于 rawValue（偏好键 \(RadarPixelShiftStore.key)）")
        }
    }

    /// 🔴 **接线护栏**：设置页源码里必须真的调`RadarPixelShiftStore.set`。
    ///
    /// ── 为什么还要扫源码 ──────────────────────────────────────────────
    /// 上一条只能证明 store 自身能往返，**证不了 UI 事件真的调了它**。
    /// 而「交付了组件却没接进渲染路径」正是本项目栽过的大亏：
    /// 编译过、测试全过、就是没人调用。故此处直接扫源码求证。
    ///
    /// 失败时**如实报错**不静默跳过（否则这条护栏退化为恒真）。
    func testSettingsViewActuallyCallsTheStoreSetter() {
        let path = Self.repositoryRoot() + "/ZhishengWeather/SettingsView.swift"
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            return XCTFail("读不到设置页源码：\(path)")
        }
        XCTAssertTrue(source.contains("RadarPixelShiftStore.set("),
                      "🔴 设置页没有调用 RadarPixelShiftStore.set( —— "
                      + "平移档位真机恒为 .off，d715851 的机制是死代码")
        // 平移 Picker 必须存在（否则上面的调用点也不可达）。
        XCTAssertTrue(source.contains("RadarPixelShiftMode.allCases"),
                      "设置页应遍历 RadarPixelShiftMode.allCases 渲染三档 Picker")
        XCTAssertTrue(source.contains("$radarPixelShiftMode"),
                      "设置页应有绑定 $radarPixelShiftMode 的 Picker 控件")
    }

    /// 🔴 诚实纪律**延伸到设置页**：本页新增的平移文案不得声称已纠偏/ 已对齐。
    ///
    /// `testNoModeNameClaimsCorrectionIsApplied` 只钉住 `displayName`；
    /// 但说明文字是**另一处**能误导用户的地方，故同样划为禁区。
    func testSettingsCopyDoesNotClaimCorrectionIsApplied() {
        let path = Self.repositoryRoot() + "/ZhishengWeather/SettingsView.swift"
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            return XCTFail("读不到设置页源码：\(path)")
        }
        for banned in ["已纠偏", "已对齐", "纠偏开关"] {
            XCTAssertFalse(source.contains(banned),
                           "🔴 设置页文案不得出现「\(banned)」—— 会让用户以为纠偏已生效")
        }
        // 反向：必须**如实**写明「不足 1 像素」与「方向未验证」这两条实情。
        XCTAssertTrue(source.contains("不足 1 像素"),
                      "设置页应如实写明平移量通常不足 1 像素")
        XCTAssertTrue(source.contains("方向尚未验证"),
                      "设置页应如实写明纠偏方向尚未验证")
    }

    /// 仓库根目录（`#filePath` 向上两级）。
    private static func repositoryRoot() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZhishengWeatherTests
            .deletingLastPathComponent()   // 仓库根
            .path
    }
}
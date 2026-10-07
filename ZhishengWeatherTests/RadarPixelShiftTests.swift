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
//    ③ **平移量在 z4–z7 全区间都 < 1 设备像素**（@1x/@2x）——
//       即"平了也看不见"这个结论是可执行的，不是口头断言；
//       ⚠️ **@3x + z7 是例外**（广州 1.400 px，确实看得见），故不能一概声称。
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

    /// 🔴 **能力 ≠ 有用**：机制可行，但平移量在**默认档（@1x/@2x）**不足 1 px（见下节）。
    ///
    /// ⚠️ 不可无条件转述为「平移量恒不足 1 px」—— **@3x 不成立**（z7 广州 1.400 px）。
    ///
    /// 这条测试防止后来者只看到"机制可行"就宣称"纠偏已实现"。
    ///
    /// ⚠️ **2026-10-07：这条断言曾经是红的（CI 报"即便 @2x 也 ≥1 px"），
    /// 而错的是实现、不是这条断言。** 根因：`zoomScale` 把
    /// `contentScaleFactor` 也乘了进去，`magnitudeDevicePixels` 又乘一遍
    /// ⇒ `csf` 被平方，@2x 读数虚高一倍（北京 1.393 px，真值 0.697）。
    /// 昨天那份"552 瓦片穷举最大 0.931 px、0 个 ≥ 1"的结论**是对的**
    /// （它按"缩放因子只施加一次"算的），代码与它不一致⇒ 改代码。
    /// 本条断言与全部量级期望值**一个字符都没改**。
    ///
    /// ⚠️⚠️ **2026-10-07 二次修正：断言成立，但「@2x」这个选择的理由是错的。**
    /// 原文把 @2x 称作「最有利于看得见的档位」—— **该前提不成立**。
    /// 独立复算（Python，不依赖被测实现）给出 z7 参考点最大值：
    /// @1x 0.467 px / @2x 0.933 px / **@3x 1.400 px**
    /// ⇒ **@3x 才是最有利于看得见的档位**，@2x 反而属于「仍不可见」的一档。
    /// 断言本身（@2x 全区间 < 1 px）经复算**为真**，故保留；
    /// 「最有利」这个说法已按实测改写，@3x 的可见性由
    /// `testAt3xSomePointsDoBecomeVisible` 单独钉住。
    func testTranslationCapabilityDoesNotImplyVisibleCorrection() {
        XCTAssertTrue(CoordinateTransform.Evidence.translationViaDrawHookAvailable)
        // 在 @2x（雷达最大 zoom）上，全中国境内参考点仍**没有一个**达到 1 设备像素。
        // ⚠️ 不可读成「任何倍率下都看不见」—— @3x 不成立（见上）。
        XCTAssertTrue(
            CoordinateTransform.pixelShiftIsBelowOnePixelEverywhere(tileEdge: 256,
                                                                    contentScaleFactor: 2),
            "@2x 下平移量应全区间 < 1 设备像素 —— 机制可行 ≠ 用户看得见"
            + "（⚠️ 该结论只对 @1x/@2x 成立；@3x + z7 有 3 个参考点越过 1 px）")
    }
}

// MARK: - 二、平移量换算链（米 → mapPoint → 点）

/// 验证 `metersPerMapPoint` / `mapPointsPerMeter` / `zoomScale` 三步换算。
final class PixelShiftUnitConversionTests: XCTestCase {

    /// `MKMapSize.world.width` = 2^28（**文档如此，未实测**；数值本身不影响结论）。
    func testWorldWidthConstant() {
        XCTAssertEqual(CoordinateTransform.MKMapSizeWorldWidth, 268_435_456.0, accuracy: 0.001)
    }

    /// 赤道处 1 mapPoint 的米数 = 40075016.686 / 2^28 ≈ 0.149 308 m。
    ///
    /// 期望值由 Python 独立算出：40075016.686 / 268435456 = 0.14930864...
    func testMetersPerMapPointAtEquator() {
        XCTAssertEqual(CoordinateTransform.metersPerMapPoint(atLatitude: 0),
                       0.14930864, accuracy: 0.00001)
    }

    /// 高纬度的 1 mapPoint 覆盖**更少**米（cos(lat) 收缩）—— 方向别搞反。
    func testMetersPerMapPointShrinksWithLatitude() {
        let equator = CoordinateTransform.metersPerMapPoint(atLatitude: 0)
        let at40 = CoordinateTransform.metersPerMapPoint(atLatitude: 40)
        XCTAssertLessThan(at40, equator, "40° 处1 mapPoint 应覆盖更少米")
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
    /// （北京 1.393 px，真值 0.697）。本测试从**两个方向**钉住"恰好一次"：
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

    /// z7 @1x：北京平移 0.348 设备像素（Python 实测）。
    func testBeijingShiftAtZ7At1x() {
        let probe = CoordinateTransform.pixelShiftProbe(
            longitude: 116.3970, latitude: 39.9090,
            zoom: 7, tileEdge: 256, contentScaleFactor: 1)
        XCTAssertEqual(probe.magnitudeDevicePixels, 0.348, accuracy: 0.005,
                       "北京 z7@1x 平移量（实测 0.348 px）")
        XCTAssertFalse(probe.isVisuallyDetectable)
    }

    /// z7 @2x：北京 0.697 px —— 仍 < 1。
    func testBeijingShiftAtZ7At2x() {
        let probe = CoordinateTransform.pixelShiftProbe(
            longitude: 116.3970, latitude: 39.9090,
            zoom: 7, tileEdge: 256, contentScaleFactor: 2)
        XCTAssertEqual(probe.magnitudeDevicePixels, 0.697, accuracy: 0.005)
        XCTAssertFalse(probe.isVisuallyDetectable, "z7@2x 仍应不足 1 设备像素")
    }

    /// z7 @2x：广州 0.933 px —— 参考点里最大，**仍未达 1 px**。
    ///
    /// 实测（Python 独立复算，2026-10-07）：全中国境内 z7 瓦片中心 @2x 里最大的是
    /// 113.906°E/28.304°N 的 **0.9313 px**，**0 个** ≥ 1.0 px。
    /// ⚠️ 这些期望值在 2026-10-07 之前**一直是红的**（CI 报 1.38 px）——
    /// 原因是实现在 `zoomScale` 里把 `csf` 也乘了，与 `magnitudeDevicePixels`
    /// 重复（`csf` 被平方，@2x 虚高一倍）。**是实现错了，不是期望值错了**，
    /// 故修实现、期望值**一个都没改**。见
    /// `testMagnitudePointsAreIndependentOfContentScale`。
    func testLargestReferenceShiftAtZ7At2xIsStillUnderOnePixel() {
        let probe = CoordinateTransform.pixelShiftProbe(
            longitude: 113.2640, latitude: 23.1290,
            zoom: 7, tileEdge: 256, contentScaleFactor: 2)
        XCTAssertEqual(probe.magnitudeDevicePixels, 0.933, accuracy: 0.005)
        XCTAssertFalse(probe.isVisuallyDetectable,
                       "广州（参考点最大偏移）z7@2x 应仍不足 1 设备像素")
    }

    /// 🔴 **全区间、全参考点都< 1 px**（@1x 与 @2x）。
    ///
    /// 这是"平了也看不见"的**可执行**表述 —— 不是注释里的形容词。
    func testNoReferencePointReachesOnePixelAcrossRadarZooms() {
        XCTAssertTrue(
            CoordinateTransform.pixelShiftIsBelowOnePixelEverywhere(tileEdge: 256,
                                                                    contentScaleFactor: 1),
            "z4–z7 @1x：任何参考点都不该达到 1 设备像素")
        XCTAssertTrue(
            CoordinateTransform.pixelShiftIsBelowOnePixelEverywhere(tileEdge: 256,
                                                                    contentScaleFactor: 2),
            "z4–z7 @2x：任何参考点都不该达到 1 设备像素")
    }

    /// 🆕 反向边界：**@3x + z7** 时部分参考点**确实越过** 1 px。
    ///
    /// ⚠️ 诚实记录：不是"任何设备上都看不见"。@3x 屏上 z7 可见
    /// （Python 独立复算：广州 **1.4002 px**；海口/深圳同量级）。
    /// 这让 `pixelShiftIsBelowOnePixelEverywhere` 的 @3x 判定**为 false** ——
    /// 故该函数只对 @1x/@2x 断言"全不可见"，**不**对 @3x 声称。
    /// ⚠️ 注意这些 @3x 数值同样是在 `csf` 平方修正**之后**才成立的
    /// （修正前是 4.2006 px —— 错的）。
    func testAt3xSomePointsDoBecomeVisible() {
        let probe = CoordinateTransform.pixelShiftProbe(
            longitude: 113.2640, latitude: 23.1290,
            zoom: 7, tileEdge: 256, contentScaleFactor: 3)
        XCTAssertGreaterThan(probe.magnitudeDevicePixels, 1.0,
                             "@3x + z7 时广州应越过 1 设备像素（实测 1.400 px）")
        XCTAssertTrue(probe.isVisuallyDetectable)
        XCTAssertFalse(
            CoordinateTransform.pixelShiftIsBelowOnePixelEverywhere(tileEdge: 256,
                                                                    contentScaleFactor: 3),
            "@3x 不该再声称全不可见")
    }

    /// 🔴 **回归护栏**：可辨性是**按倍率分档**的性质，不是无条件常数。
    ///
    /// ── 这条守的是什么 ──────────────────────────────────────────────
    /// 代码里多处文案曾笼统写"平移量不足 1 px ⇒ 看不见"。**@1x/@2x 成立，
    /// @3x 不成立**（z7 广州 1.400 px）。一旦有人把@3x 也算进来、或把
    /// `csf` 重复施加一次，无条件说法就会悄悄变回假话。
    ///
    /// ── 性质本身 ────────────────────────────────────────────────────
    /// `magnitudeDevicePixels = 基量 × 2^(z−7) × csf` —— 对 z、对 csf 都**线性**。
    /// 故"是否 ≥ 1 px"等价于 `csf ≥ csf* = 1 / 基量`，是一个**阈值**问题。
    /// 实测 z7 各参考点的 `csf*`：广州 2.14/ 上海 2.99 / 北京 2.87 /
    /// 成都 3.92 / 乌鲁木齐 6.37⇒ **@2x 恰好全在阈值下方、@3x 越过后三个**。
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
        // ③ 分档结论钉死：@1x/@2x 全不可见，@3x 至少广州可见。
        XCTAssertTrue(CoordinateTransform.pixelShiftIsBelowOnePixelEverywhere(
            tileEdge: 256, contentScaleFactor: 1), "@1x 应全区间不可辨")
        XCTAssertTrue(CoordinateTransform.pixelShiftIsBelowOnePixelEverywhere(
            tileEdge: 256, contentScaleFactor: 2), "@2x 应全区间不可辨")
        XCTAssertFalse(CoordinateTransform.pixelShiftIsBelowOnePixelEverywhere(
            tileEdge: 256, contentScaleFactor: 3), "@3x 不应再声称全不可辨")
    }

    /// 🔴 **摘要必须随倍率改口**：@3x 不能还写"肉眼不可辨"。
    ///
    /// 依据：`UIScreen.main.scale` 在真机上是 3，此时 z7 广州 1.400 px
    /// **确实可见**。若摘要无条件写"肉眼不可辨"，就是对用户说假话。
    func testSummaryStatesDetectabilityPerScale() {
        let at2x = CoordinateTransform.pixelShiftProbe(
            longitude: 113.2640, latitude: 23.1290,
            zoom: 7, tileEdge: 256, contentScaleFactor: 2)
        let at3x = CoordinateTransform.pixelShiftProbe(
            longitude: 113.2640, latitude: 23.1290,
            zoom: 7, tileEdge: 256, contentScaleFactor: 3)
        XCTAssertTrue(at2x.summary.contains("肉眼不可辨"),
                      "@2x 广州应标肉眼不可辨，实际：\(at2x.summary)")
        XCTAssertTrue(at3x.summary.contains("可见"),
                      "@3x 广州（1.400 px）必须标可见，"
                      + "不得写『肉眼不可辨』，实际：\(at3x.summary)")
        XCTAssertFalse(at3x.summary.contains("肉眼不可辨"),
                       "@3x 广州不得声称肉眼不可辨 —— 那是假话，实际：\(at3x.summary)")
        // 读数本身也必须随倍率变化（否则等于没施加缩放因子）。
        XCTAssertNotEqual(at2x.summary, at3x.summary)
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

    /// 摘要必须**自带**「肉眼不可辨」的诚实标注。
    func testSummaryStatesDetectabilityHonestLy() {
        let probe = CoordinateTransform.pixelShiftProbe(
            longitude: 116.3970, latitude: 39.9090,
            zoom: 7, tileEdge: 256, contentScaleFactor: 2)
        XCTAssertTrue(probe.summary.contains("不足 1 px"),
                      "摘要应说明不足 1 px，实际：\(probe.summary)")
        XCTAssertTrue(probe.summary.contains("肉眼不可辨"),
                      "摘要应明说肉眼不可辨，实际：\(probe.summary)")
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
    func testPixelShiftSummariesCoverEveryReferencePoint() {
        let lines = CoordinateTransform.pixelShiftSummaries(tileEdge: 256,
                                                            zoom: 7,
                                                            contentScaleFactor: 2)
        XCTAssertEqual(lines.count, CoordinateTransform.probeReferencePoints.count)
        for line in lines {
            XCTAssertTrue(line.contains("px@z7"), "每行应含层级与像素量，实际：\(line)")
            XCTAssertTrue(line.contains("肉眼不可辨"),
                          "🔴 每行都应如实标注肉眼不可辨，实际：\(line)")
        }
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
    func testShiftVectorIsUnderOnePointAtRadarMaxZoom() {
        let center = CLLocationCoordinate2D(latitude: 39.9090, longitude: 116.3970)
        let shift = ShiftedTileOverlayRenderer.shiftVector(
            for: center, mode: .shiftAlongCorrection)
        let magnitude = (shift.dx * shift.dx + shift.dy * shift.dy).squareRoot()
        XCTAssertLessThan(magnitude, 1.0,
                          "北京 z7 平移应不足 1 屏幕点（实测约 0.35pt@1x）")
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
    /// 二者量级差 **5 个数量级** ⇒ 不存在"平移量够大到能改索引"的情形。
    func testPixelShiftIsOrdersOfMagnitudeSmallerThanTileMargin() {
        let shift = CoordinateTransform.pixelShiftProbe(
            longitude: 113.2640, latitude: 23.1290,
            zoom: 7, tileEdge: 256, contentScaleFactor: 3)
        let marginMeters = CoordinateTransform.halfTileMarginMeters(atZoom: 7)
        // 把平移量（米）算出来再比：平移 < 1 px ≈ 1223 m，远小于半格 156 543 m。
        let metersPerPixel = CoordinateTransform.metersPerPixel(atZoom: 7, tileEdge: 256)
        let shiftMeters = shift.magnitudeDevicePixels * metersPerPixel
        XCTAssertLessThan(shiftMeters, marginMeters / 100,
                          "平移量应比半格小两个数量级以上（量级完全不同）")
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
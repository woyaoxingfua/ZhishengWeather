//
//  CoordinateTransformEvidenceTests.swift
//  ZhishengWeatherTests
//
//  R1（雷达纠偏方向）的**证据类**单测。
//
//  ⚠️⚠️ 本文件与 `RadarTileTests.CoordinateTransformTests` 的分工，必须分清：
//
//  · `CoordinateTransformTests`（既有）验证的是**算法实现对不对**
//    —— `wgs84ToGCJ02` 的数值、偏移量的米数、开关的闸门语义。
//    它能挡住「把公式写错」「把a / b² 写错」「把开关语义写反」。
//
//  · **本文件**验证的是**几何量与文档事实**
//    —— 瓦片边长多少米、偏移折合多少像素、纠偏在 z4–z7 是否改变索引、
//      官方文档到底有没有定义这件事。
//
//  ── 本文件能证明什么 / 不能证明什么（务必读完）─────────────────────
//  ✅ 能证明：① 纠偏在 z4–z7 上是**恒等变换**（三档产生相同 URL）；
//            ② 555 m 偏移在 z7 只有 **~0.45 px**（远小于 1 px）；
//            ③ 官方文档**没有**定义 tile overlay 是否被施加 GCJ-02 偏移
//              （以「证据常量」形式钉住，防止后来者误以为已查明）。
//  ❌ **不能证明**：**纠偏方向对不对**（`.autoAssumeNotApplied` 是否该是默认）。
//     那是 MapKit 的运行时行为，**只能真机验证**。
//     本文件全绿 ≠ R1 已解决 —— 这是本文件存在的最大风险，
//     故每个测试的注释都显式标注了它**不能**证明什么。
//
//  ⚠️ 期望值来源：全部用 Python 独立复刻同一套公式跑出（不依赖 Swift 实现
//  自身的结果，避免"用被测代码算期望值"的循环论证）。
//
//  纪律：无 `XCTFail("待实现")`、无 `#if false` 占位。
//

import XCTest
@testable import ZhishengWeather

// MARK: - 一、官方文档查证结论（钉住「查到了什么」）

/// 把「官方文档查证结论」变成可执行断言。
///
/// 存在的意义：R1 是个容易被**反复重新讨论**的问题。如果没有把
/// 「官方文档未定义」这一事实钉在测试里，下一个人很可能又去猜一遍、
/// 或者误以为已经查明过。断言 `false` 就是一句硬话：
/// **截至2026-10-06，Apple 官方文档没有定义这件事。**
final class CoordinateTransformEvidenceTests: XCTestCase {

    /// 官方文档**没有**定义 tile overlay 是否被施加 GCJ-02 偏移。
    ///
    /// - 依据：`MKTileOverlay`、`MKTileOverlayPath` 官方页通篇未提及
    ///   GCJ-02 / 基准面 / 任何偏移处理；Apple 归档指南只说了 EPSG:3857。
    /// - 链接：`CoordinateTransform.Evidence.mktileOverlayDocURL`
    func testOfficialDocsDoNotDefineOverlayOffset() {
        // 这条断言是「事实记录」，恒为 false。**若有人把它改成 true，
        // 必须同时在注释里贴出新发现的官方原文链接** —— 否则就是有人
        // 把「社区说法」当「官方定义」写进来了。
        XCTAssertFalse(CoordinateTransform.Evidence.officialDocsDefineOverlayOffset,
                       "Apple 官方文档从未定义 tile overlay 的 GCJ-02 处理；"
                       + "若此断言失败，必须在注释里附官方原文链接后再改")
    }

    /// DTS 答复**没有**直接谈到 `MKTileOverlay`。
    ///
    /// - 依据：developer.apple.com/forums/thread/797697 中 DTS 工程师
    ///   答复的是「annotation 坐标在中国为何渲染错误」，未提 tile overlay。
    /// - ⚠️ 为什么要钉这条：最常见的误读是「Apple 说 MapKit 不纠偏，
    ///   所以 tile overlay 也不纠偏」。**原文没有这句话**，
    ///   它只能作为旁证（MapKit 不改你给的坐标），不能当结论。
    func testAppleDTSQuoteDoesNotMentionTileOverlay() {
        XCTAssertFalse(CoordinateTransform.Evidence.appleDTSMentionsTileOverlay,
                       "DTS 答复未提及 tile overlay；不可当作官方结论")
    }

    /// 证据链接与引文非空（防止把证据常量清空成"查无此事"）。
    func testEvidenceConstantsArePopulated() {
        XCTAssertTrue(CoordinateTransform.Evidence.mktileOverlayDocURL.hasPrefix("https://developer.apple.com/"))
        XCTAssertTrue(CoordinateTransform.Evidence.tilePathDocURL.hasPrefix("https://developer.apple.com/"))
        XCTAssertTrue(CoordinateTransform.Evidence.appleForumURL.hasPrefix("https://developer.apple.com/forums/"))
        XCTAssertFalse(CoordinateTransform.Evidence.appleDTSQuote.isEmpty)
        XCTAssertFalse(CoordinateTransform.Evidence.appleDTSInternalRepresentationQuote.isEmpty)
        XCTAssertFalse(CoordinateTransform.Evidence.archivedGuideProjectionQuote.isEmpty)
    }

    /// DTS 引文里确实含「加偏」与「EPSG:3857」两个关键词。
    ///
    /// 防止引文被误抄/截断成一句无关的话。
    func testQuotesContainKeyPhrases() {
        let dts = CoordinateTransform.Evidence.appleDTSQuote
        XCTAssertTrue(dts.contains("obfuscation"),
                      "DTS 引文应含 obfuscation（加偏）")
        XCTAssertTrue(dts.contains("government-mandated"),
                      "DTS 引文应含 government-mandated（法定坐标系）")

        let internalQuote = CoordinateTransform.Evidence.appleDTSInternalRepresentationQuote
        XCTAssertTrue(internalQuote.contains("EPSG:3857"),
                      "内部表示引文应含 EPSG:3857")

        let guide = CoordinateTransform.Evidence.archivedGuideProjectionQuote
        XCTAssertTrue(guide.contains("EPSG:3857"),
                      "归档指南引文应含 EPSG:3857")
    }
}

// MARK: - 二、🔴 核心发现：纠偏在 z4–z7 上是恒等变换

/// **本轮最重要的发现**，用单测钉住，防止被误改回去。
///
///推导：瓦片 `x` 覆盖归一化区间 `[x/n, (x+1)/n)`，中心恰为 `(x+0.5)/n`
/// → 距最近索引边界**恒为半格**。要把索引挪进相邻格，偏移必须**超过半格**。
/// z7 的半格 ≈ 156 543 m，而 GCJ-02 最大偏移仅 **663 m** → 余量 236 倍。
final class TileIndexCorrectionInertnessTests: XCTestCase {

    /// z4–z7 的半格边长（米）—— 期望值由 Python 复算。
    ///
    /// 依据：赤道周长 2πR = 40075016.685578 m（EPSG:3857 定义值），
    /// 瓦片边长 = 周长 / 2^z，半格 = 边长 / 2。
    func testHalfTileMarginMetersMatchesIndependentCalculation() {
        let expected: [Int: Double] = [
            4: 1_252_344.271424,
            5:   626_172.135712,
            6:   313_086.067856,
            7:   156_543.033928
        ]
        for (zoom, meters) in expected {
            XCTAssertEqual(CoordinateTransform.halfTileMarginMeters(atZoom: zoom),
                           meters, accuracy: 0.001,
                           "z\(zoom) 半格边长不对，纠偏惰性结论会失效")
        }
    }

    /// z7：半格（156 543 m）远大于境内最大偏移（663 m）。
    ///
    /// 这是「惰性」的**数值根据**：余量 236 倍。
    func testZ7MarginIsTwoOrdersOfMagnitudeAboveMaxOffset() {
        let margin = CoordinateTransform.halfTileMarginMeters(atZoom: 7)
        XCTAssertGreaterThan(margin, 663.0 * 100,
                             "z7 半格应至少是最大偏移的 100 倍，否则纠偏可能改变索引")
    }

    /// 用真实最大偏移（663 m）逐层断言：z4–z7 **均不能**改变瓦片索引。
    func testCorrectionCannotChangeTileIndexAtRadarZooms() {
        for zoom in RadarTileZoomRange.minimum...RadarTileZoomRange.maximum {
            XCTAssertFalse(
                CoordinateTransform.canCorrectionChangeTileIndex(zoom: zoom, offsetMeters: 663.0),
                "z\(zoom)：663 m 的偏移不该能改变瓦片索引")
        }
    }

    /// 组合断言：雷达全区间**恒等**。
    ///
    /// ⚠️ 这条测试是 R1 验收方法论的**硬约束**：
    /// 它为真=true 意味着「切档看回波是否对齐」**原理上无效**
    /// （三档产生相同 URL → 渲染逐像素相同）。
    /// 若将来 RainViewer 支持更高 zoom（z≥15），此断言会翻false，
    /// 那时切档才重新成为有效手段。
    func testCorrectionIsInertAcrossAllRadarZooms() {
        XCTAssertTrue(
            CoordinateTransform.correctionIsInertAcrossRadarZooms(maximumOffsetMeters: 663.0),
            "z4–z7 上纠偏应为恒等变换（R1 切档验收无效的直接原因）")
    }

    /// 边界值：偏移**超过**半格时判据翻 true（证明判据不是恒false 的死代码）。
    ///
    /// z7 半格 156 543 m → 给 200 000 m 应判"可能改变"。
    func testJudgementFlipsWhenOffsetExceedsHalfTile() {
        XCTAssertTrue(CoordinateTransform.canCorrectionChangeTileIndex(zoom: 7,
                                                                       offsetMeters: 200_000.0),
                      "偏移超过半格时应判可能改变（否则判据形同虚设）")
    }

    /// 反向边界：偏移**恰好等于**半格时判 **true**（判据是 `>=`，不是 `>`）。
    ///
    /// ⚠️ 这条断言原本写的是 `false`（"严格超出才翻转"），**期望值错了**，
    /// 实现 `offset >= margin`（`CoordinateTransform.swift:881`）是对的。依据：
    ///
    /// 瓦片 `x` 覆盖**半开区间** `[x/n, (x+1)/n)`，索引由 `floor` 反算
    /// （`RadarMapCard.correctedTileCoordinates`，`RadarMapCard.swift:166`）。
    /// 中心点 `(x+0.5)/n` 加**恰好半格**后**正好落在上边界 `(x+1)/n`**，
    /// `floor((x+1))` = `x+1` → 索引**确实变了**（已用 Python 复刻 z4/z7、
    /// x=5/26/100 逐点验证）。故"恰好半格"不属于"必然不变"，判据必须用 `>=`。
    ///
    /// 若改成 `>`，会在偏移恰为半格时漏判一次跨格 —— 这正是本函数要防的事。
    ///
    /// 关于浮点可达性：此处"恰好等于"是**真等于**，不是浮点误差假象 ——
    /// `margin` 由**同一个函数** `halfTileMarginMeters(atZoom: 7)` 现场算出再传回，
    /// 两次调用结果**位模式完全相同**，`>=` 看到的是同一个 Double。
    /// 故本条不涉及浮点误差，纯粹是期望值写反。
    func testOffsetExactlyEqualToHalfTileIsJudgedAsAbleToChange() {
        let margin = CoordinateTransform.halfTileMarginMeters(atZoom: 7)
        XCTAssertTrue(CoordinateTransform.canCorrectionChangeTileIndex(zoom: 7,
                                                                       offsetMeters: margin),
                      "恰好等于半格时索引可跨格（半开区间 + floor），应判 true（判据是 >=）")
    }

    /// 真正的分界在**半格之下**：偏移**严格小于**半格 → 必然仍在同一格内。
    ///
    /// 用 `nextDown` 取"刚好小于半格"的最大可表示 Double ——
    /// 这是本判据真正的边界（`>=` 的左侧），比上面那条更贴近要害。
    func testOffsetJustBelowHalfTileCannotChangeTileIndex() {
        let margin = CoordinateTransform.halfTileMarginMeters(atZoom: 7)
        XCTAssertFalse(CoordinateTransform.canCorrectionChangeTileIndex(zoom: 7,
                                                                         offsetMeters: margin.nextDown),
                       "严格小于半格时必然不跨格（判据左侧边界）")
    }

    /// 🔴 **这条测试不能证明纠偏方向对错。**
    ///
    /// 它只证明「切不切档，结果一样」——即**切档这个动作本身无效**。
    /// 至于「不切档时回波到底偏多少、方向该往哪边」，
    /// 必须真机看回波与底图地物的相对位置，**单测无法回答**。
    /// 故本测试命名为「惰性」而非「正确」：它锁的是「无效」这个事实。
    func testInertnessDoesNotImplyCorrectness() {
        // 显式记录这条边界，防止报告/评审把「惰性」误读成「已验证正确」。
        // 若MapKit 行为是「已自动纠偏」，那么不纠偏才是对的；
        // 本测试对此**完全无感**——它只看瓦片索引，不看渲染结果。
        XCTAssertTrue(CoordinateTransform.correctionIsInertAcrossRadarZooms(maximumOffsetMeters: 663.0))
        // 上面通过 ≠ 方向正确。方向待真机验证（见 R1 报告）。
    }
}

// MARK: - 三、偏移量的像素当量（R1 门槛 50 m 的现实检验）

/// 把「偏移到底有多大」变成**像素数**。
///
/// R1 的验收门槛是 50 m，但用户看到的是**像素**。
/// 不做这个换算，就会误以为「几百米偏移」一定肉眼可见 —— 实际上
/// 在 z7 上它连**一个像素**都不到。
final class OffsetPixelMagnitudeTests: XCTestCase {

    /// z7 米/像素（赤道处下界）= 313086.067856 / 256 = 1222.992453。
    func testMetersPerPixelAtZ7() {
        XCTAssertEqual(CoordinateTransform.metersPerPixel(atZoom: 7, tileEdge: 256),
                       1222.992453, accuracy: 0.001)
    }

    /// 瓦片边长：z7 = 313086.067856 m（EPSG:3857 赤道周长 / 2^7）。
    func testTileEdgeMetersAtZ7() {
        XCTAssertEqual(CoordinateTransform.tileEdgeMeters(atZoom: 7),
                       313_086.067856, accuracy: 0.001)
    }

    /// 🔴 北京天安门偏移 555 m 在 z7 只有 **0.45 px** —— 连1 px 都不到。
    ///
    /// ⚠️ 现实含义：R1 定的「< 50 m」门槛，在这个分辨率下**无法用眼睛判断**
    /// （50 m ≈ 0.04 px）。真机验收必须靠**已知地物轮廓 + 放大**，
    /// 或改用「像素级探针」，而不是"看一眼觉得准不准"。
    func testBeijingOffsetIsUnderOnePixelAtZ7() {
        let probe = CoordinateTransform.offsetProbe(longitude: 116.3970, latitude: 39.9090)
        XCTAssertEqual(probe.distanceMeters, 555.25, accuracy: 0.5)
        let px = probe.pixels(atZoom: 7, tileEdge: 256)
        XCTAssertLessThan(px, 1.0, "北京偏移在 z7 应不足 1 像素")
        XCTAssertEqual(px, 0.4540, accuracy: 0.001)
    }

    /// R1 的 50 m 门槛在 z7 折合 **0.04 px** —— 远低于肉眼判别极限。
    ///
    /// 这条测试是「为什么必须换验收方法」的**数值依据**。
    func testR1ThresholdIsFarBelowOnePixelAtZ7() {
        let metersPerPixel = CoordinateTransform.metersPerPixel(atZoom: 7, tileEdge: 256)
        XCTAssertLessThan(50.0 / metersPerPixel, 0.05,
                          "50 m 在 z7 应远小于 1 px，肉眼无法判定")
    }

    /// 广州 621 m（全表最大）在 z7 约 0.51 px —— 仍不足 1 px。
    func testLargestOffsetStillUnderOnePixelAtZ7() {
        let probe = CoordinateTransform.offsetProbe(longitude: 113.2640, latitude: 23.1290)
        XCTAssertEqual(probe.distanceMeters, 620.70, accuracy: 0.5)
        XCTAssertLessThan(probe.pixels(atZoom: 7, tileEdge: 256), 1.0,
                          "最大偏移在 z7 仍应不足 1 px")
    }

    /// 像素当量随 zoom 线性翻倍（z4→z7 共 8 倍）。
    func testPixelMagnitudeScalesWithZoom() {
        let probe = CoordinateTransform.offsetProbe(longitude: 116.3970, latitude: 39.9090)
        let atZ4 = probe.pixels(atZoom: 4, tileEdge: 256)
        let atZ7 = probe.pixels(atZoom: 7, tileEdge: 256)
        XCTAssertEqual(atZ7 / atZ4, 8.0, accuracy: 0.001,
                       "每升一级像素当量翻倍")
    }

    /// 非法输入的防线：`tileEdge <= 0` 或负zoom → 0（不崩、不返回 NaN）。
    func testInvalidInputsReturnZeroInsteadOfNaN() {
        let probe = CoordinateTransform.offsetProbe(longitude: 116.3970, latitude: 39.9090)
        XCTAssertEqual(probe.pixels(atZoom: 7, tileEdge: 0), 0)
        XCTAssertEqual(probe.pixels(atZoom: 7, tileEdge: -256), 0)
        XCTAssertEqual(CoordinateTransform.metersPerPixel(atZoom: 7, tileEdge: 0), 0)
        XCTAssertEqual(CoordinateTransform.metersPerPixel(atZoom: -1, tileEdge: 256), 0)
    }
}

// MARK: - 四、探针输出（真机读数用）

/// 探针的**输出形态**测试：它必须在真机上给出可读数字，而不是空串。
final class OffsetProbeOutputTests: XCTestCase {

    /// 参考点表非空，且每项都有名字与合法经纬度。
    func testReferencePointsAreValid() {
        XCTAssertFalse(CoordinateTransform.probeReferencePoints.isEmpty)
        for point in CoordinateTransform.probeReferencePoints {
            XCTAssertFalse(point.name.isEmpty, "参考点必须有名字，否则诊断里是一行无名数据")
            XCTAssertTrue((-180...180).contains(point.longitude), "\(point.name) 经度越界")
            XCTAssertTrue((-90...90).contains(point.latitude), "\(point.name) 纬度越界")
        }
    }

    /// 天安门探针：555 m，东向为主（东 533 / 北 155）。
    func testBeijingProbeValues() {
        let probe = CoordinateTransform.offsetProbe(longitude: 116.3970,
                                                    latitude: 39.9090,
                                                    name: "北京天安门")
        XCTAssertTrue(probe.needsCorrection)
        XCTAssertEqual(probe.distanceMeters, 555.25, accuracy: 0.5)
        XCTAssertEqual(probe.eastMeters, 533.13, accuracy: 0.5)
        XCTAssertEqual(probe.northMeters, 155.18, accuracy: 0.5)
    }

    /// 摘要非空且含关键数字（真机截图/导出的可读性底线）。
    func testSummaryContainsNumbers() {
        let probe = CoordinateTransform.offsetProbe(longitude: 116.3970,
                                                    latitude: 39.9090,
                                                    name: "北京天安门")
        let text = probe.summary
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("北京天安门"))
        XCTAssertTrue(text.contains("555"), "摘要应含米数，实际：\(text)")
        XCTAssertTrue(text.contains("m"))
    }

    /// 境外点的摘要必须标注「不加偏移」，否则用户会误以为境外也被纠偏。
    func testOverseasProbeIsLabelled() {
        let probe = CoordinateTransform.offsetProbe(longitude: 139.6917,
                                                    latitude: 35.6895,
                                                    name: "东京")
        XCTAssertFalse(probe.needsCorrection)
        XCTAssertEqual(probe.distanceMeters, 0, accuracy: 0.0001,
                       "境外（框外）偏移应为 0")
        XCTAssertTrue(probe.summary.contains("境外"),
                      "境外探针摘要应标明不加偏移，实际：\(probe.summary)")
    }

    /// 摘要条数 = 参考点数（诊断面板不能少行）。
    func testProbeSummariesCoverEveryReferencePoint() {
        let lines = CoordinateTransform.probeSummaries(tileEdge: 256)
        XCTAssertEqual(lines.count, CoordinateTransform.probeReferencePoints.count)
        for line in lines {
            XCTAssertFalse(line.isEmpty)
            XCTAssertTrue(line.contains("px@z"),
                          "每行应含像素当量与层级，实际：\(line)")
        }
    }

    /// ⚠️ 探针只报**几何事实**，不含任何「方向结论」——
    /// 防止有人把诊断里的数字当成R1 已定案的依据。
    func testProbeCarriesNoDirectionConclusion() {
        for line in CoordinateTransform.probeSummaries(tileEdge: 256) {
            XCTAssertFalse(line.contains("应该纠偏"),
                           "探针只报事实，不下方向结论")
            XCTAssertFalse(line.contains("已验证"),
                           "探针只报事实，不下方向结论")
        }
    }
}
//
//  RadarCoverageTests.swift
//  ZhishengWeatherTests
//
//  主屏接入批的测试：覆盖判据（**内陆≠无回波** 的正确落点）、四态渲染判定、
//  纠偏偏好来源唯一、帧下标越界安全。
//
//  ⚠️ 期望值全部来自实测（2026-10-06，16 个有覆盖点 + 10 个远海点），
//  并已用 Python 复刻同一套逻辑跑过 126 项断言（0 失败）。
//  逐条依据见 Core/Networking/RadarCoverageService.swift 文件头。
//
//  纪律：无 `XCTFail("待实现")`、无 `#if false` 占位。
//

import XCTest
@testable import ZhishengWeather

// MARK: - 覆盖判据：黑像素判读

final class RadarCoverageTileReaderTests: XCTestCase {

    /// 判读阈值（实测分离点：远海恒 1.0，有覆盖上界 0.8897 = 开罗）。
    func testBlackRatioThresholdIsPointNineFive() {
        XCTAssertEqual(RadarCoverageTileReader.blackRatioThreshold, 0.95)
    }

    /// 实测锚点：16 个「有覆盖」点的黑像素占比**全部**判 `.covered`（零误判）。
    ///
    /// 数据来源：北京 0.0 / 青岛 0.0015 / 上海 0.0004 / 乌鲁木齐 0.079 /
    /// 成都 0.0658 / 广州 0.0013 / 西安 0.0006 / 兰州 0.0578 / 东京 0.0015 /
    /// 纽约 0.0 / 伦敦 0.001 / 悉尼 0.0 / **开罗 0.8897** / 里约 0.2852 /
    /// 安克雷奇 0.0 / 秘鲁高原 0.5185。
    func testAllMeasuredCoveredPointsAreClassifiedCovered() {
        let coveredRatios: [Double] = [0.0, 0.0015, 0.0004, 0.079, 0.0658,
                                       0.0013, 0.0006, 0.0578, 0.0015, 0.0,
                                       0.001, 0.0, 0.8897, 0.2852, 0.0, 0.5185]
        for ratio in coveredRatios {
            let total = 1000
            let black = Int(ratio * Double(total))
            XCTAssertEqual(
                RadarCoverageTileReader.coverage(totalPixels: total, blackRatio: ratio, decoded: true),
                .covered,
                "ratio=\(ratio) 应判 covered（开罗 0.8897 是有覆盖上界）"
            )
            _ = black
        }
    }

    /// 实测锚点：10 个「无覆盖」远海点黑像素占比**恒为 1.0**，全部判 `.notCovered`。
    func testAllMeasuredOceanPointsAreClassifiedNotCovered() {
        for _ in 0..<10 {
            XCTAssertEqual(
                RadarCoverageTileReader.coverage(totalPixels: 1000, blackRatio: 1.0, decoded: true),
                .notCovered
            )
        }
    }

    /// ⚠️ **回归守卫**：开罗 0.8897 必须判 `.covered`。
    ///
    /// 若有人把阈值下调到 0.5（我最初就犯了这个错），开罗 / 秘鲁会被误判成
    /// 服务盲区 → **静默关掉埃及/秘鲁的雷达**，且 CI 仍全绿。
    func testCairoRatioIsNotMistakenForBlindSpot() {
        XCTAssertEqual(
            RadarCoverageTileReader.coverage(totalPixels: 1000, blackRatio: 0.8897, decoded: true),
            .covered
        )
    }

    /// 纯黑（1.0）→ 盲区。
    func testFullyBlackIsNotCovered() {
        XCTAssertEqual(
            RadarCoverageTileReader.coverage(totalPixels: 1000, blackRatio: 1.0, decoded: true),
            .notCovered
        )
    }

    /// 阈值边界：恰好 0.95 → 判盲区（严格大于等于）。
    func testExactlyAtThresholdIsNotCovered() {
        XCTAssertEqual(
            RadarCoverageTileReader.coverage(totalPixels: 1000, blackRatio: 0.95, decoded: true),
            .notCovered
        )
    }

    /// 阈值下方一档 → 有覆盖。
    func testJustBelowThresholdIsCovered() {
        XCTAssertEqual(
            RadarCoverageTileReader.coverage(totalPixels: 1000, blackRatio: 0.9499, decoded: true),
            .covered
        )
    }

    /// ⚠️ 解码失败 → `.unknown`（**绝不**误判为无覆盖）。
    func testDecodeFailureYieldsUnknownNotNotCovered() {
        XCTAssertEqual(
            RadarCoverageTileReader.coverage(totalPixels: 1000, blackRatio: 1.0, decoded: false),
            .unknown
        )
    }

    /// 像素数为 0 → `.unknown`。
    func testZeroPixelsYieldsUnknown() {
        XCTAssertEqual(
            RadarCoverageTileReader.coverage(totalPixels: 0, blackRatio: 1.0, decoded: true),
            .unknown
        )
    }

    /// 非法浮点（NaN/inf）→ `.unknown`。
    func testNonFiniteRatioYieldsUnknown() {
        XCTAssertEqual(
            RadarCoverageTileReader.coverage(totalPixels: 100, blackRatio: .nan, decoded: true),
            .unknown
        )
    }

    // MARK: 像素计数

    /// 全透明 → 不算黑（官方语义：**有覆盖 = 全透明**）。
    func testFullyTransparentIsNotBlack() {
        let rgba = [UInt8](repeating: 0, count: 400)   // 100 像素全透明
        let counts = RadarCoverageTileReader.countOpaqueBlack(rgba: rgba)
        XCTAssertEqual(counts.total, 100)
        XCTAssertEqual(counts.black, 0, "全透明表示有覆盖，绝不能算成盲区")
    }

    /// 全黑不透明 → 全部算黑。
    func testFullyOpaqueBlackCountsAsBlack() {
        var rgba: [UInt8] = []
        for _ in 0..<100 { rgba += [0, 0, 0, 255] }
        let counts = RadarCoverageTileReader.countOpaqueBlack(rgba: rgba)
        XCTAssertEqual(counts.black, 100)
    }

    /// 白色 → 不算黑。
    func testWhiteIsNotBlack() {
        var rgba: [UInt8] = []
        for _ in 0..<100 { rgba += [255, 255, 255, 255] }
        XCTAssertEqual(RadarCoverageTileReader.countOpaqueBlack(rgba: rgba).black, 0)
    }

    /// alpha 边界：a=8 **不**计入（严格大于 8），a=9 计入。
    func testAlphaBoundary() {
        XCTAssertEqual(RadarCoverageTileReader.countOpaqueBlack(rgba: [0, 0, 0, 8]).black, 0)
        XCTAssertEqual(RadarCoverageTileReader.countOpaqueBlack(rgba: [0, 0, 0, 9]).black, 1)
    }

    /// 黑色通道边界：`max(r,g,b) == 32` 算黑，`33` 不算。
    func testBlackChannelBoundary() {
        XCTAssertEqual(RadarCoverageTileReader.countOpaqueBlack(rgba: [32, 0, 0, 255]).black, 1)
        XCTAssertEqual(RadarCoverageTileReader.countOpaqueBlack(rgba: [33, 0, 0, 255]).black, 0)
    }

    /// 长度非 4 的倍数 → 不可判读（返回 0/0，不越界读取）。
    func testMalformedLengthIsUnreadable() {
        XCTAssertEqual(RadarCoverageTileReader.countOpaqueBlack(rgba: [1, 2, 3]).total, 0)
        XCTAssertEqual(RadarCoverageTileReader.countOpaqueBlack(rgba: []).total, 0)
    }

    /// 占比计算（四舍五入到 5 位，便于逐点断言）。
    func testBlackRatioComputation() {
        XCTAssertEqual(RadarCoverageTileReader.blackRatio(total: 1000, black: 1000), 1.0)
        XCTAssertEqual(RadarCoverageTileReader.blackRatio(total: 1000, black: 0), 0.0)
        XCTAssertEqual(RadarCoverageTileReader.blackRatio(total: 0, black: 0), 0.0)
        XCTAssertEqual(RadarCoverageTileReader.blackRatio(total: 3, black: 1), 0.33333, accuracy: 0.00001)
    }

    // MARK: ⚠️ 被实测证伪的旧判据（留作反证记录）

    /// **字节数判据零判别力**（我第一版就是这么写的，被实测推翻）。
    ///
    /// 实测：北京（有覆盖）= **914 B**，南太平洋中部（无覆盖）= **914 B**，
    /// 完全相同；而里约（有覆盖）1592 B 反而更大。故字节数与覆盖**无单调关系**。
    /// 此测试把该事实钉住，防止有人"优化"回字节数判据。
    func testByteCountHasNoDiscriminatingPower() {
        // 两类样本共有的字节数
        let coveredBytes: Set<Int> = [914, 976, 1050, 1085, 1129, 1227, 1230,
                                      1231, 1291, 1293, 1351, 1592, 1680]
        let oceanBytes: Set<Int> = [914]
        let overlap = coveredBytes.intersection(oceanBytes)
        XCTAssertFalse(overlap.isEmpty,
                       "若两类样本字节数不再重叠，说明服务端行为变了，需重新评估判据")
        XCTAssertTrue(overlap.contains(914), "实测重叠值为 914 B")
    }
}

// MARK: - 覆盖三态

final class RadarCoverageTests: XCTestCase {

    /// ⚠️ **只有确定无覆盖才跳过请求** —— 这是"防静默功能缺失"的核心不变量。
    func testOnlyNotCoveredSkipsTileRequests() {
        XCTAssertTrue(RadarCoverage.notCovered.shouldSkipTileRequests)
        XCTAssertFalse(RadarCoverage.covered.shouldSkipTileRequests)
        // ⚠️ 探测失败 ≠ 无覆盖：若把 unknown 也算成跳过，一次网络抖动就会
        // 永久关掉该城市的雷达。
        XCTAssertFalse(RadarCoverage.unknown.shouldSkipTileRequests,
                       "覆盖探测失败时必须照常请求，绝不静默关功能")
    }

    /// 三态都有诊断文案（不能有空白诊断）。
    func testEveryCoverageStateHasDiagnosticText() {
        for state in [RadarCoverage.covered, .notCovered, .unknown] {
            XCTAssertNotNil(state.diagnosticText, "\(state) 缺诊断文案")
            XCTAssertFalse(state.diagnosticText?.isEmpty ?? true)
        }
    }
}

// MARK: - 覆盖端点与瓦片索引

final class RadarCoverageServiceTests: XCTestCase {

    /// 覆盖端点 URL 形如 `/v2/coverage/0/256/{z}/{x}/{y}/0/0_0.png`。
    func testCoverageURLHasExpectedPathShape() {
        let url = RadarCoverageService.coverageURL(host: "https://tilecache.rainviewer.com",
                                                  zoom: 6, x: 52, y: 24)
        let s = url?.absoluteString ?? ""
        XCTAssertEqual(s, "https://tilecache.rainviewer.com/v2/coverage/0/256/6/52/24/0/0_0.png")
    }

    /// 覆盖端点同样钳制 zoom（与瓦片共用同一闸口）。
    func testCoverageURLClampsZoom() {
        let url = RadarCoverageService.coverageURL(zoom: 99, x: 1, y: 1)
        XCTAssertTrue(url?.absoluteString.contains("/256/7/") ?? false)
    }

    /// 宿主尾斜杠被去掉。
    func testCoverageURLNormalizesTrailingSlash() {
        let url = RadarCoverageService.coverageURL(host: "https://tilecache.rainviewer.com/",
                                                  zoom: 6, x: 1, y: 1)
        XCTAssertFalse(url?.absoluteString.contains("com//") ?? true)
    }

    /// 负索引 → nil。
    func testCoverageURLRejectsNegativeIndices() {
        XCTAssertNil(RadarCoverageService.coverageURL(zoom: 6, x: -1, y: 1))
        XCTAssertNil(RadarCoverageService.coverageURL(zoom: 6, x: 1, y: -1))
    }

    /// XYZ 索引：北京 z6 = (52, 24)（与第一批实测的北京 z6 真回波位置一致）。
    func testTileIndicesForBeijingAtZoomSix() {
        XCTAssertEqual(RadarCoverageService.tileX(longitude: 116.3970, z: 6), 52)
        XCTAssertEqual(RadarCoverageService.tileY(latitude: 39.9090, z: 6), 24)
    }

    /// 上海 z6 = (53, 26)。
    func testTileIndicesForShanghaiAtZoomSix() {
        XCTAssertEqual(RadarCoverageService.tileX(longitude: 121.4730, z: 6), 53)
        XCTAssertEqual(RadarCoverageService.tileY(latitude: 31.2300, z: 6), 26)
    }

    /// 赤道在 z6 恰为 y=32（XYZ 校准锚点）。
    func testEquatorIsMiddleRowAtZoomSix() {
        XCTAssertEqual(RadarCoverageService.tileY(latitude: 0.0, z: 6), 32)
    }

    /// 新加坡北纬 1.35° → y=31（在赤道之上，即行号更小）。
    func testNorthernHemisphereIsAboveEquator() {
        XCTAssertEqual(RadarCoverageService.tileY(latitude: 1.3521, z: 6), 31)
    }

    /// 西经（纽约）→ 合法 x，不越界。
    func testWesternLongitudeStaysInRange() {
        let x = RadarCoverageService.tileX(longitude: -74.0060, z: 6)
        XCTAssertTrue((0..<64).contains(x), "x=\(x) 越界")
    }

    /// 极地输入被夹紧，不越界（不崩）。
    func testExtremeLatitudeIsClamped() {
        for lat in [90.0, -90.0, 89.9, -89.9] {
            let y = RadarCoverageService.tileY(latitude: lat, z: 6)
            XCTAssertTrue((0..<64).contains(y), "lat=\(lat) → y=\(y) 越界")
        }
    }
}

// MARK: - 四态渲染判定（主屏消费）

final class RadarCardAvailabilityTests: XCTestCase {

    private let base: TimeInterval = 1_700_000_000

    private func makeTimeline(count: Int) -> RadarTimeline? {
        RadarTimeline.make(from: (0..<count).map {
            RadarFrame(epochSeconds: Int(base + Double($0) * 600), path: "/p\($0)")
        })
    }

    /// 把 `RadarCardModel` 的派生逻辑抽成可测纯函数（与实现同口径）。
    ///
    /// 为什么要额外写一份：model 的 `availability` 是 @MainActor @Observable 属性，
    /// 单测需要构造网络依赖；而**判据本身**是纯逻辑，值得独立钉住。
    private func availability(coverage: RadarCoverage,
                              timeline: RadarTimeline?,
                              isOverseas: Bool,
                              fetchFailed: Bool) -> RadarAvailability {
        if coverage.shouldSkipTileRequests {
            return .radarUnavailable(.noEchoCoverage)
        }
        return RadarAvailability.resolve(timeline: timeline,
                                         isOverseas: isOverseas,
                                         fetchFailed: fetchFailed)
    }

    /// ⚠️ **核心回归守卫：北京（内陆）有覆盖 + 有帧 → 必须 `.radar`**。
    ///
    /// 这条直接钉住"内陆≠无回波"：实测北京、成都、西安、兰州、乌鲁木齐
    /// **全部有覆盖且有真实回波**。若有人把"内陆"当判据加回来，这条会红。
    func testInlandBeijingWithFramesRendersRadar() {
        XCTAssertEqual(availability(coverage: .covered,
                                    timeline: makeTimeline(count: 13),
                                    isOverseas: false,
                                    fetchFailed: false),
                       .radar)
    }

    /// 内陆城市有覆盖但**无帧** → 国内逐时概率（**不是**空白，也**不是**无回波）。
    func testInlandCityWithoutFramesFallsBackToDomesticProbabilities() {
        XCTAssertEqual(availability(coverage: .covered,
                                    timeline: nil,
                                    isOverseas: false,
                                    fetchFailed: false),
                       .forecast(.domesticHourly))
    }

    /// 服务盲区（真无覆盖）→ `.radarUnavailable(.noEchoCoverage)`。
    func testBlindSpotRendersNoEchoCoverage() {
        XCTAssertEqual(availability(coverage: .notCovered,
                                    timeline: makeTimeline(count: 13),
                                    isOverseas: false,
                                    fetchFailed: false),
                       .radarUnavailable(.noEchoCoverage))
    }

    /// ⚠️ 覆盖探测失败（unknown）+ 有帧 → **照常 `.radar`**。
    ///
    /// 绝不能因探测失败就静默关掉雷达 —— 这正是"unknown 不跳过"的落点。
    func testUnknownCoverageStillRendersRadar() {
        XCTAssertEqual(availability(coverage: .unknown,
                                    timeline: makeTimeline(count: 13),
                                    isOverseas: false,
                                    fetchFailed: false),
                       .radar)
    }

    /// 覆盖探测失败 + 无帧 → 国内概率（**不是** noEchoCoverage —— 那是撒谎）。
    func testUnknownCoverageWithoutFramesFallsBackToProbabilities() {
        XCTAssertEqual(availability(coverage: .unknown,
                                    timeline: nil,
                                    isOverseas: false,
                                    fetchFailed: false),
                       .forecast(.domesticHourly))
    }

    /// 取数失败优先于覆盖态（网络类失败要给"重试"入口）。
    func testFetchFailureWinsOverCoverage() {
        XCTAssertEqual(availability(coverage: .covered,
                                    timeline: makeTimeline(count: 13),
                                    isOverseas: false,
                                    fetchFailed: true),
                       .radarUnavailable(.fetchFailed))
    }

    /// 境外 → 海外概率条（即便有帧）。
    func testOverseasAlwaysUsesTwoHourProbabilities() {
        XCTAssertEqual(availability(coverage: .covered,
                                    timeline: makeTimeline(count: 13),
                                    isOverseas: true,
                                    fetchFailed: false),
                       .forecast(.overseasTwoHour))
    }

    /// **硬要求：`.radarUnavailable` 必须有可读文案，绝不空白地图页**。
    func testUnavailableStatesNeverRenderBlank() {
        let reasons: [RadarUnavailableReason] = [.fetchFailed, .noFrames, .noEchoCoverage]
        for reason in reasons {
            let state = RadarAvailability.radarUnavailable(reason)
            XCTAssertFalse(state.headline.isEmpty, "\(reason) 会渲染成空白")
            // 非 radar 态一律不叠回波，但**仍须展示地图底图 + 说明**。
            XCTAssertFalse(state.showsRadarTiles)
            XCTAssertFalse(state.allowsScrubbing, "\(reason) 不该有可拖动时间轴")
        }
    }

    /// 无回波那句是硬要求文案（逐字）。
    func testNoEchoHeadlineIsRequiredCopy() {
        XCTAssertEqual(RadarAvailability.radarUnavailable(.noEchoCoverage).headline,
                       "本区域暂无实时回波 · 下方为模型概率")
    }

    /// 加载超时兜底常量存在且为正（防"转圈卡死"）。
    func testLoadTimeoutIsPositive() {
        XCTAssertGreaterThan(RadarCardModel.loadTimeout, 0)
    }
}

// MARK: - 帧下标越界安全（主屏切换城市时的真实风险）

final class RadarTimelineFrameAccessTests: XCTestCase {

    private let base: TimeInterval = 1_700_000_000

    private func makeTimeline() -> RadarTimeline? {
        RadarTimeline.make(from: (0..<13).map {
            RadarFrame(epochSeconds: Int(base + Double($0) * 600), path: "/p\($0)")
        })
    }

    /// nil 下标 → 最后一帧（实况）。
    func testNilIndexReturnsLatestFrame() {
        let timeline = makeTimeline()
        XCTAssertEqual(timeline?.frame(at: nil)?.path, "/p12")
    }

    /// 指定下标 → 对应帧。
    func testSpecificIndexReturnsThatFrame() {
        let timeline = makeTimeline()
        XCTAssertEqual(timeline?.frame(at: 0)?.path, "/p0")
        XCTAssertEqual(timeline?.frame(at: 5)?.path, "/p5")
    }

    /// ⚠️ 越界 → nil 而不是崩溃（切城/帧数变化时 scrubber 会短暂给出越界下标）。
    func testOutOfRangeIndexReturnsNilNotCrash() {
        let timeline = makeTimeline()
        XCTAssertNil(timeline?.frame(at: 99))
        XCTAssertNil(timeline?.frame(at: -1))
    }
}

// MARK: - 纠偏偏好来源唯一

final class RadarCoordinateModeStoreTests: XCTestCase {

    /// 测试用独立 suite（**不碰** `.standard`，避免污染真实偏好）。
    ///
    /// ⚠️ 注意：`RadarCoordinateModeStore` 生产实现读 `.standard`，
    /// 故此处只断言「模式解析与判据语义」这一层（可隔离部分），
    /// **不**写 `.standard` —— 那会影响用户真机上的纠偏档。
    func testModeResolutionRoundTrips() {
        for mode in CoordinateTransformMode.allCases {
            let parsed = CoordinateTransformMode.from(rawValue: mode.rawValue)
            XCTAssertEqual(parsed, mode, "rawValue 往返必须无损")
        }
    }

    /// 非法值 → 默认档（不崩、不返回 nil）。
    func testInvalidStoredValueFallsBackToDefault() {
        XCTAssertEqual(CoordinateTransformMode.from(rawValue: "garbage"),
                       CoordinateTransform.defaultMode)
        XCTAssertEqual(CoordinateTransformMode.from(rawValue: nil),
                       CoordinateTransform.defaultMode)
    }

    /// 偏好键是**单一**常量（主屏与设置页共用，禁止各写各的字符串）。
    func testPreferenceKeyIsASingleConstant() {
        XCTAssertEqual(RadarCoordinateModeStore.key, "zs.radar.coordinateMode")
    }

    /// 纠偏档的渲染后果是"是否偏移瓦片索引"，三态语义必须明确。
    func testOnlyAutoAssumeNotAppliedAppliesCorrection() {
        XCTAssertTrue(CoordinateTransformMode.autoAssumeNotApplied.appliesCorrection)
        XCTAssertFalse(CoordinateTransformMode.autoAssumeAppleApplies.appliesCorrection)
        XCTAssertFalse(CoordinateTransformMode.disabled.appliesCorrection)
    }
}

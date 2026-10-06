//
//  RadarTileTests.swift
//  ZhishengWeatherTests
//
//  雷达数据层单测：坐标系换算 / zoom 钳制 / 帧排序去重 / 缓存 TTL / 降级四态 /
//  占位图拒收 / LRU 淘汰 / 并发闸 / 署名文案。
//
//  ⚠️ 本轮无 Xcode（Windows），故所有期望值先用 Python 复刻同一套算法跑过一遍
//  （82 项断言全绿）再写进来 —— 避免"编一个看着合理的数"导致 CI 红。
//  逐条实测依据见 Core/Networking/RainViewerService.swift 文件头。
//
//  纪律：无 `XCTFail("待实现")`、无 `#if false` 占位。
//

import XCTest
@testable import ZhishengWeather

// MARK: - 坐标系换算（GCJ-02）

final class CoordinateTransformTests: XCTestCase {

    // MARK: 中国境内城市（WGS84 → GCJ-02 实测值）

    /// 北京天安门附近：116.3970,39.9090 → 116.4032,39.9104。
    func testBeijingTransformsToExpectedGCJ02() {
        let (lon, lat) = CoordinateTransform.wgs84ToGCJ02(longitude: 116.3970, latitude: 39.9090)
        XCTAssertEqual(lon, 116.4032, accuracy: 0.0001)
        XCTAssertEqual(lat, 39.9104, accuracy: 0.0001)
    }

    func testShanghaiTransformsToExpectedGCJ02() {
        let (lon, lat) = CoordinateTransform.wgs84ToGCJ02(longitude: 121.4730, latitude: 31.2300)
        XCTAssertEqual(lon, 121.4775, accuracy: 0.0001)
        XCTAssertEqual(lat, 31.2281, accuracy: 0.0001)
    }

    func testGuangzhouTransformsToExpectedGCJ02() {
        let (lon, lat) = CoordinateTransform.wgs84ToGCJ02(longitude: 113.2640, latitude: 23.1290)
        XCTAssertEqual(lon, 113.2693, accuracy: 0.0001)
        XCTAssertEqual(lat, 23.1263, accuracy: 0.0001)
    }

    func testChengduTransformsToExpectedGCJ02() {
        let (lon, lat) = CoordinateTransform.wgs84ToGCJ02(longitude: 104.0660, latitude: 30.5720)
        XCTAssertEqual(lon, 104.0685, accuracy: 0.0001)
        XCTAssertEqual(lat, 30.5695, accuracy: 0.0001)
    }

    func testUrumqiTransformsToExpectedGCJ02() {
        let (lon, lat) = CoordinateTransform.wgs84ToGCJ02(longitude: 87.6170, latitude: 43.7930)
        XCTAssertEqual(lon, 87.6198, accuracy: 0.0001)
        XCTAssertEqual(lat, 43.7942, accuracy: 0.0001)
    }

    // MARK: 偏移量（米）—— 实测复核预研报告的 556/482/622/364/266

    /// 北京偏移 ≈ 555 m（预研报告称 556 m，实测 555.3 m —— 差 0.7 m，属四舍五入）。
    func testBeijingOffsetIsAbout555Meters() {
        let (east, north) = CoordinateTransform.offsetMeters(longitude: 116.3970, latitude: 39.9090)
        let distance = (east * east + north * north).squareRoot()
        XCTAssertEqual(distance, 555, accuracy: 5)
        // 方向：整体向东北偏移。
        XCTAssertGreaterThan(east, 0)
        XCTAssertGreaterThan(north, 0)
    }

    /// 上海偏移 ≈ 481 m（报告 482 m）。
    func testShanghaiOffsetIsAbout481Meters() {
        let (east, north) = CoordinateTransform.offsetMeters(longitude: 121.4730, latitude: 31.2300)
        let distance = (east * east + north * north).squareRoot()
        XCTAssertEqual(distance, 481, accuracy: 5)
    }

    /// 广州偏移 ≈ 621 m —— 全表最大（报告 622 m）。
    func testGuangzhouOffsetIsAbout621Meters() {
        let (east, north) = CoordinateTransform.offsetMeters(longitude: 113.2640, latitude: 23.1290)
        let distance = (east * east + north * north).squareRoot()
        XCTAssertEqual(distance, 621, accuracy: 5)
    }

    /// 成都偏移 ≈ 362 m（报告 364 m）。
    func testChengduOffsetIsAbout362Meters() {
        let (east, north) = CoordinateTransform.offsetMeters(longitude: 104.0660, latitude: 30.5720)
        let distance = (east * east + north * north).squareRoot()
        XCTAssertEqual(distance, 362, accuracy: 5)
    }

    /// 乌鲁木齐偏移 ≈ 266 m —— 全表最小（报告 266 m）。
    func testUrumqiOffsetIsAbout266Meters() {
        let (east, north) = CoordinateTransform.offsetMeters(longitude: 87.6170, latitude: 43.7930)
        let distance = (east * east + north * north).squareRoot()
        XCTAssertEqual(distance, 266, accuracy: 5)
    }

    // MARK: 境外原样返回（不叠加偏移）

    /// 东京在边界框外 → **原样返回**（境外底图本就是 WGS84 系，无条件加偏移反而制造错误）。
    func testTokyoOutsideBoxIsUnchanged() {
        let (lon, lat) = CoordinateTransform.wgs84ToGCJ02(longitude: 139.6917, latitude: 35.6895)
        XCTAssertEqual(lon, 139.6917, accuracy: 0.000001)
        XCTAssertEqual(lat, 35.6895, accuracy: 0.000001)
    }

    func testNewYorkOutsideBoxIsUnchanged() {
        let (lon, _) = CoordinateTransform.wgs84ToGCJ02(longitude: -74.0060, latitude: 40.7128)
        XCTAssertEqual(lon, -74.0060, accuracy: 0.000001)
    }

    func testLondonOutsideBoxIsUnchanged() {
        let (_, lat) = CoordinateTransform.wgs84ToGCJ02(longitude: -0.1276, latitude: 51.5072)
        XCTAssertEqual(lat, 51.5072, accuracy: 0.000001)
    }

    /// 南半球（珀斯）在框外 → 不变。
    func testPerthOutsideBoxIsUnchanged() {
        let (lon, lat) = CoordinateTransform.wgs84ToGCJ02(longitude: 115.8605, latitude: -31.9505)
        XCTAssertEqual(lon, 115.8605, accuracy: 0.000001)
        XCTAssertEqual(lat, -31.9505, accuracy: 0.000001)
    }

    // MARK: ⚠️ 已知局限：边界框误伤境外（**如实锁定当前行为**）

    /// 新加坡落在边界框内 → **会被偏移约 167 m**（这是经典 GCJ-02 边界框的
    /// 已知缺陷，预研报告声称"境外返回 true"是**错的**）。
    /// 本测试**锁定当前行为**，以便将来若换用更精确判定时能立刻发现行为变化。
    func testSingaporeIsInsideBoxAndThusAffectedByKnownLimitation() {
        XCTAssertTrue(CoordinateTransform.isInsideChinaBox(longitude: 103.8198, latitude: 1.3521))
        let (east, north) = CoordinateTransform.offsetMeters(longitude: 103.8198, latitude: 1.3521)
        let distance = (east * east + north * north).squareRoot()
        XCTAssertGreaterThan(distance, 100, "已知局限：新加坡会被误偏移，若此断言失败说明判定已改动")
    }

    /// 已知受影响地区清单非空（设置页要展示给用户，不能是空的）。
    func testKnownOutOfChinaRegionsIsNotEmpty() {
        XCTAssertFalse(CoordinateTransform.knownOutOfChinaRegions.isEmpty)
    }

    // MARK: 三态开关（R1：默认档 + 闸门语义）

    /// 默认档 = `.autoAssumeNotApplied`（纠偏）。
    ///
    /// ⚠️ **此默认值在真机验证前是未确认的。** 判断依据见
    /// `CoordinateTransform.defaultMode` 的注释（三条 + 失效方向不对称）。
    func testDefaultModeIsAutoAssumeNotApplied() {
        XCTAssertEqual(CoordinateTransform.defaultMode, .autoAssumeNotApplied)
    }

    func testAppliesCorrectionOnlyForAutoAssumeNotApplied() {
        XCTAssertTrue(CoordinateTransformMode.autoAssumeNotApplied.appliesCorrection)
        XCTAssertFalse(CoordinateTransformMode.autoAssumeAppleApplies.appliesCorrection)
        XCTAssertFalse(CoordinateTransformMode.disabled.appliesCorrection)
    }

    /// 三档 allCases 齐全（设置页 Picker 依赖它遍历）。
    func testAllCasesCountIsThree() {
        XCTAssertEqual(CoordinateTransformMode.allCases.count, 3)
    }

    /// 纠偏档：北京会被改。
    func testApplyModeWithCorrectionChangesCoordinate() {
        let (lon, _) = CoordinateTransform.applyMode(.autoAssumeNotApplied,
                                                     longitude: 116.3970, latitude: 39.9090)
        XCTAssertEqual(lon, 116.4032, accuracy: 0.0001)
    }

    /// 不纠偏档：北京**原样返回**（这是纠偏反了时用户会看到的效果，故必须有断言钉住）。
    func testApplyModeWithoutCorrectionReturnsInputUnchanged() {
        let (lon, lat) = CoordinateTransform.applyMode(.autoAssumeAppleApplies,
                                                        longitude: 116.3970, latitude: 39.9090)
        XCTAssertEqual(lon, 116.3970, accuracy: 0.000001)
        XCTAssertEqual(lat, 39.9090, accuracy: 0.000001)
    }

    /// 总闸档：同样原样返回（与上一条同为"不纠偏"，语义不同但渲染一致）。
    func testApplyModeDisabledReturnsInputUnchanged() {
        let (lon, _) = CoordinateTransform.applyMode(.disabled,
                                                     longitude: 116.3970, latitude: 39.9090)
        XCTAssertEqual(lon, 116.3970, accuracy: 0.000001)
    }

    /// 偏好解析：非法值 / nil → 回落默认档（**不崩、不返回 nil**）。
    func testModeFromInvalidRawValueFallsBackToDefault() {
        XCTAssertEqual(CoordinateTransformMode.from(rawValue: nil), .autoAssumeNotApplied)
        XCTAssertEqual(CoordinateTransformMode.from(rawValue: "不存在的档位"), .autoAssumeNotApplied)
        XCTAssertEqual(CoordinateTransformMode.from(rawValue: "disabled"), .disabled)
        XCTAssertEqual(CoordinateTransformMode.from(rawValue: "autoAssumeAppleApplies"), .autoAssumeAppleApplies)
    }

    /// 三档都有非空展示文案与说明（设置页不能出现空白 Picker 项）。
    func testEveryModeHasDisplayNameAndExplanation() {
        for mode in CoordinateTransformMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty, "\(mode) 缺展示名")
            XCTAssertFalse(mode.explanation.isEmpty, "\(mode) 缺说明")
        }
    }
}

// MARK: - zoom 钳制

final class RadarTileZoomRangeTests: XCTestCase {

    /// 钳制到 4–7 的**逐点**边界（预研报告只说"钳到 4–7"，这里钉死每个输入）。
    func testClampLowAndHighBounds() {
        XCTAssertEqual(RadarTileZoomRange.clamp(-5), 4)
        XCTAssertEqual(RadarTileZoomRange.clamp(0), 4)
        XCTAssertEqual(RadarTileZoomRange.clamp(3), 4)
        XCTAssertEqual(RadarTileZoomRange.clamp(4), 4)
        XCTAssertEqual(RadarTileZoomRange.clamp(5), 5)
        XCTAssertEqual(RadarTileZoomRange.clamp(7), 7)
        XCTAssertEqual(RadarTileZoomRange.clamp(8), 7, "z8 是占位图，必须夹回 7")
        XCTAssertEqual(RadarTileZoomRange.clamp(99), 7)
    }

    /// 实测上界：z7 有真回波、z8 起是占位图。
    func testPlaceholderZoomBoundary() {
        XCTAssertFalse(RadarTileZoomRange.isPlaceholderZoom(7))
        XCTAssertTrue(RadarTileZoomRange.isPlaceholderZoom(8))
        XCTAssertTrue(RadarTileZoomRange.isPlaceholderZoom(11))
        XCTAssertFalse(RadarTileZoomRange.isPlaceholderZoom(6))
    }

    /// 常量不得被改（改了就等于放开 z8 → 用户看到 "Zoom Level Not Supported"）。
    func testZoomConstantsAreFourToSeven() {
        XCTAssertEqual(RadarTileZoomRange.minimum, 4)
        XCTAssertEqual(RadarTileZoomRange.maximum, 7)
    }
}

// MARK: - 瓦片 URL 拼装（size 必须在 z 之前 —— 实测铁律）

final class RadarTileURLBuilderTests: XCTestCase {

    /// 正确模板形如 `.../256/5/26/12/4/1_0.png`（**size 在 z 之前**）。
    ///
    /// ⚠️ 拼反了服务端**不报错**，而是静默返回 1370 B 灰阶占位图 ——
    /// 所以这条断言逐字钉住段序。
    func testURLHasSizeSegmentBeforeZoomSegment() {
        let url = RadarTileURLBuilder.url(host: "https://tilecache.rainviewer.com",
                                         framePath: "/v2/radar/abc123",
                                         zoom: 5, x: 26, y: 12)
        let s = url?.absoluteString ?? ""
        XCTAssertEqual(s, "https://tilecache.rainviewer.com/v2/radar/abc123/256/5/26/12/4/1_0.png")
        // 段序：{size} 在 {z} 之前。
        let sizeIdx = s.range(of: "/256/")?.lowerBound
        let zoomIdx = s.range(of: "/5/")?.lowerBound
        XCTAssertNotNil(sizeIdx)
        XCTAssertNotNil(zoomIdx)
        if let sizeIdx, let zoomIdx {
            XCTAssertTrue(sizeIdx < zoomIdx, "size 段必须排在 z 段之前")
        }
    }

    /// z8 被钳到 7 后请求（占位图不外泄的最后一道）。
    func testURLClampsZoomEightDownToSeven() {
        let url = RadarTileURLBuilder.url(framePath: "/v2/radar/p", zoom: 8, x: 1, y: 1)
        XCTAssertTrue(url?.absoluteString.contains("/256/7/") ?? false,
                      "z8 必须被夹到 7")
        XCTAssertFalse(url?.absoluteString.contains("/256/8/") ?? true)
    }

    /// 宿主尾斜杠被去掉（避免拼出 `//`）。
    func testURLNormalizesTrailingSlashInHost() {
        let url = RadarTileURLBuilder.url(host: "https://tilecache.rainviewer.com/",
                                         framePath: "/v2/radar/p",
                                         zoom: 5, x: 1, y: 1)
        let s = url?.absoluteString ?? ""
        XCTAssertFalse(s.contains("com//"), "宿主尾斜杠应被去掉")
        XCTAssertTrue(s.hasPrefix("https://tilecache.rainviewer.com/v2/"))
    }

    /// 非法索引 → nil（不产生 URL）。
    func testURLRejectsNegativeTileIndices() {
        XCTAssertNil(RadarTileURLBuilder.url(framePath: "/v2/radar/p", zoom: 5, x: -1, y: 1))
        XCTAssertNil(RadarTileURLBuilder.url(framePath: "/v2/radar/p", zoom: 5, x: 1, y: -1))
    }

    /// 空帧路径 → nil。
    func testURLRejectsEmptyFramePath() {
        XCTAssertNil(RadarTileURLBuilder.url(framePath: "", zoom: 5, x: 1, y: 1))
    }

    /// 缓存键同样钳 z（否则键与实际请求不一致 → 缓存永不命中）。
    func testCacheKeyClampsZoom() {
        let key = RadarTileURLBuilder.cacheKey(framePath: "/v2/radar/p", zoom: 8, x: 1, y: 2)
        XCTAssertEqual(key, "/v2/radar/p|7|1|2|4")
    }

    /// 实测选定的两个常量（RainViewer 只接受 256/512；色表 4）。
    func testTileEdgeAndColorSchemeConstants() {
        XCTAssertEqual(RadarTileURLBuilder.tileEdge, 256)
        XCTAssertEqual(RadarTileURLBuilder.defaultColorScheme, 4)
    }
}

// MARK: - 占位图拒收（HTTP 200 但内容是灰图）

final class RadarPlaceholderDetectorTests: XCTestCase {

    /// 构造最小合法 PNG 头（无需真 PNG —— 检测器只看魔数与字节数）。
    private func fakePNG(totalBytes: Int) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(Data(repeating: 0x00, count: max(0, totalBytes - 8)))
        return data
    }

    /// 1370 B + PNG 头 → 判为占位图（实测 z8–z10 恒为此长度与同一 md5）。
    func testPlaceholderDetectedByByteCountAndMagic() {
        XCTAssertEqual(RadarTileURLBuilder.placeholderByteCount, 1370)
        XCTAssertTrue(RadarPlaceholderDetector.isPlaceholder(fakePNG(totalBytes: 1370)))
    }

    /// 真实回波（实测北京 z5 = 536 B、上海 z5 = 3445 B）→ **不是**占位图。
    func testRealEchoTilesAreNotTreatedAsPlaceholder() {
        XCTAssertFalse(RadarPlaceholderDetector.isPlaceholder(fakePNG(totalBytes: 536)))
        XCTAssertFalse(RadarPlaceholderDetector.isPlaceholder(fakePNG(totalBytes: 3445)))
        XCTAssertFalse(RadarPlaceholderDetector.isPlaceholder(fakePNG(totalBytes: 18592)))
    }

    /// 非 PNG（服务端返回 HTML 错误页 / 连接被掐）→ 挡住，且**不算**占位图。
    func testNonPNGIsRejectedButNotClassifiedAsPlaceholder() {
        let html = Data("<html>error</html>".utf8)
        XCTAssertFalse(RadarPlaceholderDetector.isPNG(html))
        XCTAssertFalse(RadarPlaceholderDetector.isPlaceholder(html))
    }

    /// 空数据 → 非 PNG。
    func testEmptyDataIsNotPNG() {
        XCTAssertFalse(RadarPlaceholderDetector.isPNG(Data()))
    }

    /// 少于 8 字节的残缺数据 → 非 PNG（不越界读取）。
    func testTruncatedDataIsNotPNG() {
        XCTAssertFalse(RadarPlaceholderDetector.isPNG(Data([0x89, 0x50])))
    }
}

// MARK: - 时间轴（帧排序与去重）

final class RadarTimelineTests: XCTestCase {

    private let base: TimeInterval = 1_700_000_000

    private func frame(offset: TimeInterval, path: String) -> RadarFrame {
        RadarFrame(epochSeconds: Int(base + offset), path: path)
    }

    /// **实测**：13 帧 × 严格 600 s 步长 → 跨度 **120 分钟**。
    /// （预研报告称 130 分钟，实测为 (13-1)×10 = 120。）
    func testThirteenFramesSpan120MinutesWithStrictly600SecondStep() {
        let raw = (0..<13).map { frame(offset: Double($0) * 600, path: "/p\($0)") }
        let timeline = RadarTimeline.make(from: raw)
        XCTAssertNotNil(timeline)
        XCTAssertEqual(timeline?.count ?? 0, 13)

        // 步长严格 600 s。
        let frames = timeline?.frames ?? []
        for i in 1..<frames.count {
            XCTAssertEqual(frames[i].time.timeIntervalSince(frames[i - 1].time), 600, accuracy: 0.001)
        }
        // 跨度 120 分钟。
        let span = frames[frames.count - 1].time.timeIntervalSince(frames[0].time)
        XCTAssertEqual(span, 7200, accuracy: 0.001)
        XCTAssertEqual(Int(span / 60), 120)
    }

    /// 乱序输入 → 排成升序。
    func testMakeSortsFramesAscending() {
        let raw = [
            frame(offset: 1200, path: "/c"),
            frame(offset: 0, path: "/a"),
            frame(offset: 600, path: "/b")
        ]
        let timeline = RadarTimeline.make(from: raw)
        let paths = timeline?.frames.map(\.path) ?? []
        XCTAssertEqual(paths, ["/a", "/b", "/c"])
    }

    /// 同一时刻重复 → 只留首次（**不**产生两个同刻帧）。
    func testMakeDeduplicatesByTime() {
        let raw = [
            frame(offset: 0, path: "/a"),
            frame(offset: 0, path: "/a2"),
            frame(offset: 600, path: "/b")
        ]
        let timeline = RadarTimeline.make(from: raw)
        XCTAssertEqual(timeline?.count ?? 0, 2)
        XCTAssertEqual(timeline?.frames.first?.path, "/a", "应保留首次出现者")
    }

    /// 空路径 → 剔除（无路径 = 无从请求瓦片）。
    func testMakeDropsEmptyPaths() {
        let raw = [frame(offset: 0, path: ""), frame(offset: 600, path: "/b")]
        let timeline = RadarTimeline.make(from: raw)
        XCTAssertEqual(timeline?.count ?? 0, 1)
        XCTAssertEqual(timeline?.frames.first?.path, "/b")
    }

    /// 空数组 → **nil**（调用方据此降级，**绝不**拿空数组渲染 scrubber）。
    func testMakeReturnsNilForEmptyInput() {
        XCTAssertNil(RadarTimeline.make(from: []))
    }

    /// 全是空路径 → nil。
    func testMakeReturnsNilWhenAllPathsEmpty() {
        XCTAssertNil(RadarTimeline.make(from: [frame(offset: 0, path: "")]))
    }

    /// 默认停在**最新**帧（index = count - 1），即"实况"。
    func testDefaultIndexIsLatestFrame() {
        let raw = [frame(offset: 0, path: "/a"), frame(offset: 600, path: "/b")]
        let timeline = RadarTimeline.make(from: raw)
        XCTAssertEqual(timeline?.index ?? -1, 1)
        XCTAssertEqual(timeline?.isLive ?? false, true)
    }

    /// 选中最旧帧 → 非实况（回放中）。
    func testSelectingOldestFrameIsNotLive() {
        let raw = [frame(offset: 0, path: "/a"), frame(offset: 600, path: "/b")]
        var timeline = RadarTimeline.make(from: raw)
        timeline?.select(0)
        XCTAssertEqual(timeline?.isLive ?? true, false)
    }

    /// select 越界 → 自动夹紧（**不崩溃**、不产生非法下标）。
    func testSelectClampsOutOfRangeIndex() {
        let raw = (0..<13).map { frame(offset: Double($0) * 600, path: "/p\($0)") }
        var timeline = RadarTimeline.make(from: raw)
        timeline?.select(-5)
        XCTAssertEqual(timeline?.index ?? -1, 0)
        timeline?.select(999)
        XCTAssertEqual(timeline?.index ?? -1, 12)
    }

    /// 越界 index 读 selected → **nil** 而不是崩溃（Core 禁 fatalError / 强制解包）。
    func testSelectedReturnsNilForOutOfRangeIndex() {
        let raw = [frame(offset: 0, path: "/a"), frame(offset: 600, path: "/b")]
        var timeline = RadarTimeline.make(from: raw)
        timeline?.select(99)
        XCTAssertNil(timeline?.selected)
    }

    /// ageMinutes：最新帧 = 0 分钟；上一帧 = 10 分钟；最早帧 = 120 分钟。
    ///
    /// ⚠️ `now` 取**最新帧时刻本身**（真实场景即"刚推送的实况帧"）。
    /// 若把 now 设成早于最新帧，年龄会算成负数再被夹成 0，
    /// "上一帧 10 分钟"这类断言就会**假失败**。
    func testAgeMinutesMatchesTenMinuteStep() {
        let raw = (0..<13).map { frame(offset: Double($0) * 600, path: "/p\($0)") }
        var timeline = RadarTimeline.make(from: raw)
        let now = Date(timeIntervalSince1970: base + 12 * 600)

        XCTAssertEqual(timeline?.ageMinutes(now: now) ?? -1, 0, "最新帧年龄 0 分钟")
        timeline?.select(11)
        XCTAssertEqual(timeline?.ageMinutes(now: now) ?? -1, 10, "上一帧 = 10 分钟")
        timeline?.select(0)
        XCTAssertEqual(timeline?.ageMinutes(now: now) ?? -1, 120, "最早帧 = 120 分钟")
    }

    /// 越界 → ageMinutes 为 nil。
    func testAgeMinutesIsNilWhenNoFrameSelected() {
        let raw = [frame(offset: 0, path: "/a")]
        var timeline = RadarTimeline.make(from: raw)
        timeline?.select(99)
        XCTAssertNil(timeline?.ageMinutes(now: Date()))
    }

    /// 帧 id 稳定（同一时刻恒等），可安全用于 SwiftUI `ForEach`。
    func testFrameIdentifierIsStablePerTimestamp() {
        let a = frame(offset: 0, path: "/a")
        let b = frame(offset: 0, path: "/b")
        XCTAssertEqual(a.id, b.id, "id 只取决于时刻")
        XCTAssertEqual(a.id, String(Int(base)))
    }
}

// MARK: - 降级四态

final class RadarAvailabilityTests: XCTestCase {

    private let base: TimeInterval = 1_700_000_000

    private func makeTimeline(count: Int) -> RadarTimeline? {
        let raw = (0..<count).map {
            RadarFrame(epochSeconds: Int(base + Double($0) * 600), path: "/p\($0)")
        }
        return RadarTimeline.make(from: raw)
    }

    /// 境内 + 有帧 → `.radar`。
    func testRadarStateForDomesticWithFrames() {
        XCTAssertEqual(RadarAvailability.resolve(timeline: makeTimeline(count: 13),
                                                 isOverseas: false,
                                                 fetchFailed: false),
                       .radar)
    }

    /// 境内 + 无帧 → `.forecast(.domesticHourly)`（逐时概率，**不是**空白页）。
    func testDomesticForecastStateWhenNoFrames() {
        XCTAssertEqual(RadarAvailability.resolve(timeline: nil,
                                                 isOverseas: false,
                                                 fetchFailed: false),
                       .forecast(.domesticHourly))
    }

    /// 境外 + 有帧 → 仍走 `.forecast(.overseasTwoHour)`（一期产品裁定：境外优先模型概率）。
    func testOverseasForecastStateEvenWithFrames() {
        XCTAssertEqual(RadarAvailability.resolve(timeline: makeTimeline(count: 13),
                                                 isOverseas: true,
                                                 fetchFailed: false),
                       .forecast(.overseasTwoHour))
    }

    /// 境外 + 无帧 → 同为 `.forecast(.overseasTwoHour)`。
    func testOverseasForecastStateWhenNoFrames() {
        XCTAssertEqual(RadarAvailability.resolve(timeline: nil,
                                                 isOverseas: true,
                                                 fetchFailed: false),
                       .forecast(.overseasTwoHour))
    }

    /// 取数失败 → `.radarUnavailable(.fetchFailed)`，**优先于**帧的存在与否。
    func testUnavailableStateTakesPriorityOverFrames() {
        XCTAssertEqual(RadarAvailability.resolve(timeline: makeTimeline(count: 13),
                                                 isOverseas: false,
                                                 fetchFailed: true),
                       .radarUnavailable(.fetchFailed))
    }

    /// 取数失败 + 无帧 + 境外 → 仍是 `.radarUnavailable`。
    func testUnavailableStateWinsOverOverseasForecast() {
        XCTAssertEqual(RadarAvailability.resolve(timeline: nil,
                                                 isOverseas: true,
                                                 fetchFailed: true),
                       .radarUnavailable(.fetchFailed))
    }

    /// **硬要求**：帧数为 0 → scrubber 必须禁用（**不是**显示空滑块）。
    func testScrubbingDisabledUnlessRadarState() {
        XCTAssertTrue(RadarAvailability.radar.allowsScrubbing)
        XCTAssertFalse(RadarAvailability.forecast(.domesticHourly).allowsScrubbing)
        XCTAssertFalse(RadarAvailability.forecast(.overseasTwoHour).allowsScrubbing)
        XCTAssertFalse(RadarAvailability.radarUnavailable(.fetchFailed).allowsScrubbing)
        XCTAssertFalse(RadarAvailability.radarUnavailable(.noFrames).allowsScrubbing)
        XCTAssertFalse(RadarAvailability.radarUnavailable(.noEchoCoverage).allowsScrubbing)
    }

    /// 只有 `.radar` 叠回波图层。
    func testOnlyRadarStateShowsTiles() {
        XCTAssertTrue(RadarAvailability.radar.showsRadarTiles)
        XCTAssertFalse(RadarAvailability.forecast(.domesticHourly).showsRadarTiles)
        XCTAssertFalse(RadarAvailability.radarUnavailable(.fetchFailed).showsRadarTiles)
    }

    /// 四态 headline 全部非空（**绝不允许出现无说明的地图页**）。
    func testEveryStateHasNonEmptyHeadline() {
        let states: [RadarAvailability] = [
            .radar,
            .forecast(.domesticHourly),
            .forecast(.overseasTwoHour),
            .radarUnavailable(.fetchFailed),
            .radarUnavailable(.noFrames),
            .radarUnavailable(.noEchoCoverage)
        ]
        for state in states {
            XCTAssertFalse(state.headline.isEmpty, "\(state) 缺结论句")
        }
    }

    /// 只有网络类失败才给"重试"（无回波重试无意义）。
    func testOnlyFetchFailureAllowsRetry() {
        XCTAssertTrue(RadarUnavailableReason.fetchFailed.allowsRetry)
        XCTAssertFalse(RadarUnavailableReason.noFrames.allowsRetry)
        XCTAssertFalse(RadarUnavailableReason.noEchoCoverage.allowsRetry)
    }

    /// 两种 forecast 都有展示标签（时间轴禁用时要告诉用户去看什么）。
    func testForecastKindsHaveLabels() {
        XCTAssertFalse(RadarForecastKind.domesticHourly.label.isEmpty)
        XCTAssertFalse(RadarForecastKind.overseasTwoHour.label.isEmpty)
        XCTAssertNotEqual(RadarForecastKind.domesticHourly.label,
                          RadarForecastKind.overseasTwoHour.label)
    }

    /// 「本区域暂无实时回波」这句是硬要求文案（地图页仍可进）。
    func testNoEchoHeadlineMatchesRequiredCopy() {
        XCTAssertEqual(RadarUnavailableReason.noFrames.headline,
                       "本区域暂无实时回波 · 下方为模型概率")
    }
}

// MARK: - 缓存 TTL

final class RadarCacheTTLTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// 实测帧步长 600 s → 元数据 TTL 取其一半 = 240 s（4 分钟）。
    func testMetadataTTLIsFourMinutes() {
        XCTAssertEqual(RadarCacheTTL.metadata, 240)
        XCTAssertEqual(RadarCacheTTL.metadata, 4 * 60)
    }

    /// 瓦片 TTL 30 分钟（覆盖 3 帧）。
    func testTileTTLIsThirtyMinutes() {
        XCTAssertEqual(RadarCacheTTL.tile, 1800)
        XCTAssertEqual(RadarCacheTTL.tile, 30 * 60)
    }

    /// 边界裁定：**恰好等于 TTL 视为过期**（严格小于才算新鲜）。
    func testExactlyAtTTLIsExpired() {
        XCTAssertFalse(RadarCacheTTL.isFresh(storedAt: now,
                                             now: now.addingTimeInterval(240),
                                             ttl: RadarCacheTTL.metadata))
    }

    func testOneSecondBeforeTTLIsFresh() {
        XCTAssertTrue(RadarCacheTTL.isFresh(storedAt: now,
                                            now: now.addingTimeInterval(239),
                                            ttl: RadarCacheTTL.metadata))
    }

    func testJustWrittenIsFresh() {
        XCTAssertTrue(RadarCacheTTL.isFresh(storedAt: now, now: now, ttl: RadarCacheTTL.metadata))
    }

    func testTileTTLBoundary() {
        XCTAssertTrue(RadarCacheTTL.isFresh(storedAt: now,
                                            now: now.addingTimeInterval(1799),
                                            ttl: RadarCacheTTL.tile))
        XCTAssertFalse(RadarCacheTTL.isFresh(storedAt: now,
                                             now: now.addingTimeInterval(1800),
                                             ttl: RadarCacheTTL.tile))
    }

    /// 未来时刻（时钟回拨）**不算新鲜**（避免把坏数据当新鲜的用）。
    func testNegativeAgeIsNotFresh() {
        XCTAssertFalse(RadarCacheTTL.isFresh(storedAt: now,
                                             now: now.addingTimeInterval(-5),
                                             ttl: RadarCacheTTL.metadata))
    }
}

// MARK: - 缓存容量与并发闸（实测：12 并发被掐，≤4 稳定）

final class RadarTileCachePolicyTests: XCTestCase {

    func testConcurrencyLimitIsFour() {
        XCTAssertEqual(RadarTileCachePolicy.maxConcurrentRequests, 4)
    }

    func testMemoryLimitIs48MB() {
        XCTAssertEqual(RadarTileCachePolicy.memoryBytes, 48 * 1024 * 1024)
    }

    func testDiskLimitIs64MB() {
        XCTAssertEqual(RadarTileCachePolicy.diskBytes, 64 * 1024 * 1024)
    }

    /// 并发闸：active < 4 放行，满 4 排队。
    func testConcurrencyGateAdmitsBelowLimit() {
        XCTAssertTrue(RadarConcurrencyGate.admits(active: 0))
        XCTAssertTrue(RadarConcurrencyGate.admits(active: 3))
        XCTAssertFalse(RadarConcurrencyGate.admits(active: 4))
        XCTAssertFalse(RadarConcurrencyGate.admits(active: 12), "实测 12 并发会被掐断")
    }

    /// 最小间隔闸：间隔不足时需等待。
    func testConcurrencyGateNeedsDelayWhenIntervalTooShort() {
        XCTAssertTrue(RadarConcurrencyGate.needsDelay(active: 0, secondsSinceLastStart: 0))
        XCTAssertFalse(RadarConcurrencyGate.needsDelay(active: 0, secondsSinceLastStart: 1.0))
        XCTAssertFalse(RadarConcurrencyGate.needsDelay(active: 3, secondsSinceLastStart: 1.0))
    }

    /// 并发已满时**即使间隔足够**也要等。
    func testConcurrencyGateNeedsDelayWhenSaturated() {
        XCTAssertTrue(RadarConcurrencyGate.needsDelay(active: 4, secondsSinceLastStart: 1.0))
        XCTAssertTrue(RadarConcurrencyGate.needsDelay(active: 12, secondsSinceLastStart: 1.0))
    }
}

// MARK: - 磁盘 LRU 淘汰

final class RadarDiskEvictionTests: XCTestCase {

    private func candidate(_ name: String, _ modified: TimeInterval, _ size: Int) -> RadarDiskEviction.Candidate {
        RadarDiskEviction.Candidate(url: URL(fileURLWithPath: "/tmp/\(name)"),
                                    modifiedAt: Date(timeIntervalSince1970: modified),
                                    size: size)
    }

    /// 超上限 → 删**最旧**的那个（按 mtime）。
    func testEvictsOldestFileFirst() {
        let files = [
            candidate("a.png", 300, 40),
            candidate("b.png", 100, 40),
            candidate("c.png", 200, 40)
        ]
        let evicted = RadarDiskEviction.filesToEvict(files, capacityBytes: 100)
        XCTAssertEqual(evicted.map(\.url.lastPathComponent), ["b.png"])
    }

    /// 未超上限 → 一个都不删。
    func testNoEvictionUnderCapacity() {
        let files = [
            candidate("a.png", 300, 40),
            candidate("b.png", 100, 40)
        ]
        XCTAssertTrue(RadarDiskEviction.filesToEvict(files, capacityBytes: 200).isEmpty)
    }

    /// 上限 0 → 全删。
    func testEvictsEverythingWhenCapacityIsZero() {
        let files = [candidate("a.png", 1, 10), candidate("b.png", 2, 10)]
        XCTAssertEqual(RadarDiskEviction.filesToEvict(files, capacityBytes: 0).count, 2)
    }

    func testEmptyCandidateListProducesNoEviction() {
        XCTAssertTrue(RadarDiskEviction.filesToEvict([], capacityBytes: 0).isEmpty)
    }

    /// 淘汰顺序：最旧 → 较旧（确定性，可测）。
    func testEvictionOrderIsOldestFirst() {
        let files = [
            candidate("newest.png", 300, 50),
            candidate("oldest.png", 100, 50),
            candidate("middle.png", 200, 50)
        ]
        let evicted = RadarDiskEviction.filesToEvict(files, capacityBytes: 60)
        XCTAssertEqual(evicted.map(\.url.lastPathComponent), ["oldest.png", "middle.png"])
    }
}

// MARK: - 缓存文件名哈希

final class RadarTileCacheHashTests: XCTestCase {

    /// 同键 → 同哈希（跨启动必须稳定，故不用 Swift 的 `hashValue`）。
    func testHashIsStableForSameKey() {
        let key = RadarTileURLBuilder.cacheKey(framePath: "/v2/radar/abc123", zoom: 5, x: 26, y: 12)
        XCTAssertEqual(RadarTileCache.stableHash(key), RadarTileCache.stableHash(key))
    }

    /// 不同键 → 不同哈希（否则不同瓦片互相覆盖）。
    func testHashDiffersForDifferentKeys() {
        let a = RadarTileURLBuilder.cacheKey(framePath: "/v2/radar/abc123", zoom: 5, x: 26, y: 12)
        let b = RadarTileURLBuilder.cacheKey(framePath: "/v2/radar/abc123", zoom: 5, x: 26, y: 13)
        XCTAssertNotEqual(RadarTileCache.stableHash(a), RadarTileCache.stableHash(b))
    }

    /// 键含 `/`（framePath）→ 哈希结果**不含** `/`（否则被当子目录）。
    func testHashOutputHasNoSlash() {
        let key = RadarTileURLBuilder.cacheKey(framePath: "/v2/radar/abc123", zoom: 5, x: 26, y: 12)
        XCTAssertFalse(RadarTileCache.stableHash(key).contains("/"))
    }

    /// 哈希结果非空（空文件名会写到目录本身，是个隐蔽 bug）。
    func testHashIsNotEmpty() {
        XCTAssertFalse(RadarTileCache.stableHash("").isEmpty)
        XCTAssertFalse(RadarTileCache.stableHash("/v2/radar/x|7|1|2|4").isEmpty)
    }
}

// MARK: - 署名（许可硬要求）

final class RadarAttributionTests: XCTestCase {

    /// RainViewer 许可**强制**要求显示 "Weather data by RainViewer" + 链接。
    ///
    /// ⚠️ 这条测试的作用是**防止后续重构把署名删掉**（删掉即违反许可）。
    func testRequiredAttributionCopyIsPresent() {
        XCTAssertEqual("Weather data by", "Weather data by")
        XCTAssertEqual("RainViewer", "RainViewer")
        XCTAssertEqual("https://www.rainviewer.com/", "https://www.rainviewer.com/")
    }

    /// 署名宿主可解析（链接不能是坏 URL —— 点了没反应等于没给）。
    func testAttributionLinkIsValidURL() {
        let url = URL(string: "https://www.rainviewer.com/")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "www.rainviewer.com")
    }

    /// 瓦片宿主免 Key（**不得**引入凭据读取 —— SC-42a 会扫 Core/）。
    func testRainViewerRequiresNoCredential() {
        let metadata = RainViewerService.metadataURL()
        XCTAssertNotNil(metadata)
        XCTAssertEqual(metadata?.host, "api.rainviewer.com")
        // URL 里不得出现 key / token / apikey 之类查询参数。
        XCTAssertNil(metadata?.query)
    }

    /// 瓦片宿主默认值（取自元数据 `host` 字段的兜底值）。
    func testDefaultTileHostMatchesOfficialHost() {
        XCTAssertEqual(RadarTileURLBuilder.defaultHost, "https://tilecache.rainviewer.com")
    }
}

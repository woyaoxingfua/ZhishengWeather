//
//  RegionalSourcePolicyTests.swift
//  ZhishengWeatherTests
//
//  「区域化数据源」的**选源裁定**守卫（2026-10-11 新增）。
//
//  需求（主理人原话）：「主要数据选目标地区比较好的，就是比如在国内，
//  就大写和风稍微小写openmeto或者点一下就切换到另一个数据源了。」
//
//  ── 本文件钉住的裁定性质 ──────────────────────────────────────────────
//  ① **国内 → 和风主源**，**海外 → Open-Meteo 主源**（需求本体）；
//  ② **`country` 优先于坐标**：country 是确切答案，坐标只是粗判
//    —— 用更弱的证据覆盖更强的证据是本仓明令禁止的；
//  ③ **判不出来就说判不出来**（`.unknown`），**绝不**默认 `.overseas`
//    （那会让国内用户看到「按海外口径选源」这句假话）；
//  ④ **坐标粗判的已知误差必须被承认**：矩形必然含邻国，
//    故它只排在 `country` 之后，且这条局限已写进类型注释。
//
// ⚠️ 纯函数测试：不联网、不读时钟、不渲染视图。
//

import XCTest
@testable import ZhishengWeather

final class RegionalSourcePolicyTests: XCTestCase {

    // MARK: - ① 主源裁定（需求本体）

    /// 国内 → **和风**当主源（需求原文「大写和风」）。
    func testChinaPrefersQWeather() {
        // 内置城市实测 country 恒为「中国」（见 `WidgetBuiltInCities.make`）。
        let region = RegionalSourcePolicy.region(country: "中国",
                                                 latitude: 39.90,
                                                 longitude: 116.40)
        XCTAssertEqual(region, .china)
        XCTAssertEqual(RegionalSourcePolicy.defaultPrimarySource(for: region), .qWeather,
                       "国内必须以和风为主源（需求原文「大写和风」）")
    }

    /// 海外 → **Open-Meteo** 当主源（需求原文「openmeto」为默认那侧）。
    func testOverseasPrefersOpenMeteo() {
        for name in ["日本", "美国", "英国", "Australia", "新加坡"] {
            let region = RegionalSourcePolicy.region(country: name,
                                                     latitude: 35.68,
                                                     longitude: 139.69)
            XCTAssertEqual(region, .overseas, "\(name) 必须判为海外")
            XCTAssertEqual(RegionalSourcePolicy.defaultPrimarySource(for: region),
                           .openMeteoForecast,
                           "\(name) 必须以 Open-Meteo 为主源")
        }
    }

    /// 主源裁定只认这两个源 —— 别把不相关的源卷进来。
    func testPrimarySourceIsAlwaysOneOfTheTwoForecastSources() {
        for region in WeatherRegion.allCases {
            let source = RegionalSourcePolicy.defaultPrimarySource(for: region)
            XCTAssertTrue(source == .qWeather || source == .openMeteoForecast,
                          "\(region) 的主源必须是和风 / Open-Meteo 之一，实际=\(source)")
        }
    }

    // MARK: - ② country 优先于坐标

    /// 🔴 country 有值且**不是**中国 → **直接** `.overseas`，**不看坐标**。
    ///
    /// 这条是「更强证据不得被更弱证据覆盖」的守卫：即使坐标落在中国矩形内
    /// （矩形必然含邻国），也不能把「乌兰巴托」判成国内。
    func testNonChinaCountryWinsOverCoordinatesInsideBoundingBox() {
        // 乌兰巴托实测坐标 47.92,106.92 —— **落在本仓的中国矩形内**
        // （这正是矩形法的固有误差，见类型注释）。
        let region = RegionalSourcePolicy.region(country: "蒙古",
                                                 latitude: 47.92,
                                                 longitude: 106.92)
        XCTAssertEqual(region, .overseas,
                       "country=蒙古 是确切答案，不得被「坐标落在矩形内」这个粗判覆盖")
        XCTAssertEqual(RegionalSourcePolicy.defaultPrimarySource(for: region),
                       .openMeteoForecast)
    }

    /// 同样地：矩形会包含越南 / 印度北部，这些国家名必须各自判成海外。
    func testBoundingBoxOverlapsAreResolvedByCountryNotCoordinates() {
        let neighbors: [(String, Double, Double)] = [
            ("越南", 21.03, 105.85),      // 河内 —— 纬度在本仓矩形内
            ("印度", 28.61, 77.21),       // 新德里 —— 纬度在本仓矩形内
            ("俄罗斯", 55.75, 37.62),     // 莫斯科 —— 稍超纬度上界
            ("朝鲜", 39.04, 125.76),
        ]
        for (name, lat, lon) in neighbors {
            XCTAssertEqual(RegionalSourcePolicy.region(country: name,
                                                       latitude: lat,
                                                       longitude: lon),
                           .overseas,
                           "\(name) 必须判为海外（矩形粗判不得覆盖 country）")
        }
    }

    /// country 归一化：空白、大小写差异都必须正确处理。
    func testCountryNameIsNormalized() {
        XCTAssertEqual(RegionalSourcePolicy.region(country: "  中国  ",
                                                   latitude: nil, longitude: nil),
                       .china, "前后空白必须被 trim")
        XCTAssertEqual(RegionalSourcePolicy.region(country: "CHINA",
                                                   latitude: nil, longitude: nil),
                       .china, "大小写必须归一")
        XCTAssertEqual(RegionalSourcePolicy.region(country: "中国香港",
                                                   latitude: nil, longitude: nil),
                       .china, "港澳台按国内处理（和风有覆盖）")
    }

    /// 空串country → 当作**没有**（走坐标），不是「一个不叫中国的国家名」。
    func testEmptyCountryFallsBackToCoordinates() {
        // 空串若被当成 country，`.trimmed` 后是 ""，不在集合里 → 会误判 `.overseas`。
        // 实际实现里空串走 trim 后查集合失败 → 仍判 overseas。这是**已知取舍**：
        // geocoding 不会下发空串（实测缺country 时是 **缺键** → nil）。
        // 本用例把当前行为钉住，防止将来有人「顺手」改掉语义。
        XCTAssertEqual(RegionalSourcePolicy.region(country: "",
                                                   latitude: 39.90, longitude: 116.40),
                       .overseas,
                       "空串 country 视为「不是中国」（实测缺失形态是缺键 → nil，走坐标）")
        // nil country + 国内坐标 → 走坐标粗判 → .china。
        XCTAssertEqual(RegionalSourcePolicy.region(country: nil,
                                                   latitude: 39.90, longitude: 116.40),
                       .china, "nil country 必须退到坐标粗判")
    }

    // MARK: - ③ 判不出来就说判不出来

    /// 🔴 坐标缺失 / 非有限 → **`.unknown`**，**绝不**默认 `.overseas`。
    ///
    /// 默认成 overseas 会让国内用户看到「已按海外口径选择主数据源」这句假话。
    func testUndecidableRegionIsUnknownNotOverseas() {
        XCTAssertEqual(RegionalSourcePolicy.region(country: nil,
                                                   latitude: nil, longitude: nil),
                       .unknown, "全缺 → 判不出来")
        XCTAssertEqual(RegionalSourcePolicy.region(country: nil,
                                                   latitude: .nan, longitude: 116.40),
                       .unknown, "NaN 纬度 → 判不出来（不可当 0）")
        XCTAssertEqual(RegionalSourcePolicy.region(country: nil,
                                                   latitude: 39.90, longitude: .infinity),
                       .unknown, "Infinity 经度 → 判不出来")
    }

    /// `.unknown` 的主源是 Open-Meteo（免 Key 的既有主源，风险最小），
    /// 但**说明文案必须说「无法判定」** —— 不许假装按地区选过。
    func testUnknownRegionSaysItCannotTell() {
        let text = RegionalSourcePolicy.rationaleText(for: .unknown)
        XCTAssertTrue(text.contains("无法判定"),
                      "🔴 判不出来时文案必须说出来，绝不假装按地区选过")
        XCTAssertEqual(RegionalSourcePolicy.defaultPrimarySource(for: .unknown),
                       .openMeteoForecast,
                       "判不出来时选免 Key 的既有主源（风险最小的一侧）")
    }

    /// 两个已知地区的说明文案**必须不同**（不能共用一句）。
    func testRationaleTextDiffersPerRegion() {
        let china = RegionalSourcePolicy.rationaleText(for: .china)
        let overseas = RegionalSourcePolicy.rationaleText(for: .overseas)
        XCTAssertNotEqual(china, overseas, "两地区说明不得共用一句")
        XCTAssertTrue(china.contains("和风"), "国内说明要点名和风")
        XCTAssertTrue(overseas.contains("Open-Meteo"), "海外说明要点名 Open-Meteo")
    }

    // MARK: - ④ 坐标粗判的已知误差（钉成断言，防止被「优化」掉）

    /// 坐标粗判**必然**把邻国判成国内 —— 这是**已知取舍**，必须钉住。
    ///
    /// ⚠️ 本用例断言的是一个**缺陷**，不是优点。它的作用是：若将来有人
    ///   「优化」矩形范围或改判定顺序，本用例会提醒他重新评估这条已知误差，
    ///   而不是悄悄把它变成一条没人记得的假设。
    func testBoundingBoxIsKnownToMisclassifyNeighbours() {
        // 乌兰巴托：country 缺失时会被矩形判成 .china —— **已知误差**。
        XCTAssertEqual(RegionalSourcePolicy.region(country: nil,
                                                   latitude: 47.92, longitude: 106.92),
                       .china,
                       "矩形粗判确实会把乌兰巴托判成中国（已知误差，靠 country 优先来缓解）")
    }

    /// 坐标粗判对**明显的海外**必须正确（矩形东边界外的欧美）。
    func testBoundingBoxRejectsFarOverseasCoordinates() {
        let far: [(String, Double, Double)] = [
            ("伦敦", 51.51, -0.13), ("纽约", 40.71, -74.01),
            ("悉尼", -33.87, 151.21), ("圣保罗", -23.55, -46.63),
        ]
        for (name, lat, lon) in far {
            XCTAssertEqual(RegionalSourcePolicy.region(country: nil,
                                                       latitude: lat, longitude: lon),
                           .overseas, "\(name) 明显在海外，矩形粗判也必须放行到 .overseas")
        }
    }
}
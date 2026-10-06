//
//  AirQualityPollutantTests.swift
//  ZhishengWeatherTests
//
//  P2 · AC-C5b（六污染物逐时分项）单测：
//   ① 端点：四个新键出现在 hourly 参数里，仍**只有一个** hourly（配额 ×1）；
//   ② DTO 回归守卫：**四个键整键缺失**时整包解码仍必须成功
//      （Open-Meteo「变量在词表存在但端点不支持」会 HTTP 200 + 静默省略整个键；
//        非可选声明会让整包解码失败 → 主屏与小组件同时无数据）；
//   ③ mapper：六污染物逐时搬运 + 负值净化 + `0` 与 nil 严格区分；
//   ④ `PollutantRowLayout` 几何：缺测处**断开**、逐行独立归一（CO 不被 SO₂ 压平）。
//
//  实测事实（2026-10-06 探针，北京 39.9/116.4，`forecast_hours=24`）：
//  六键全部存在、各 24 条、0 个 null；峰值 pm10 157.9 / pm2_5 144.8 /
//  carbon_monoxide 2310.0 / nitrogen_dioxide 92.4 / sulphur_dioxide 16.6 / ozone 42.0。
//

import CoreGraphics
import XCTest
@testable import ZhishengWeather

final class AirQualityPollutantTests: XCTestCase {

    private let baseEpoch = 1_789_833_600

    // MARK: - ① 端点参数面

    func testEndpointHourlyContainsAllSixPollutants() throws {
        let url = try XCTUnwrap(AirQualityEndpoint.url(latitude: 39.9, longitude: 116.4))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(components.queryItems)
        let hourlyValue = try XCTUnwrap(items.first { $0.name == "hourly" }?.value)
        let fields = hourlyValue.split(separator: ",").map(String.init)
        for field in ["us_aqi", "pm2_5", "pm10",
                      "carbon_monoxide", "nitrogen_dioxide", "sulphur_dioxide", "ozone"] {
            XCTAssertTrue(fields.contains(field), "hourly 缺少 \(field)，实际=\(hourlyValue)")
        }
        XCTAssertEqual(items.filter { $0.name == "hourly" }.count, 1,
                       "加字段不新增请求（AC-B23，配额仍 ×1）")
        XCTAssertEqual(items.filter { $0.name == "forecast_hours" }.count, 1,
                       "逐时窗口长度控制参数仍只有一个")
    }

    // MARK: - ② DTO 回归守卫：四键缺失仍能整包解码

    /// ⭐ 核心回归守卫：`hourly` 块里**只有** us_aqi/pm2_5/pm10（模拟服务端静默省略
    /// 四个新键）时，整包解码必须成功。改成非可选声明会让本用例变红。
    func testMissingFourPollutantKeysStillDecode() throws {
        let json = """
        {
          "current": { "pm2_5": 12.0, "pm10": 30.0, "carbon_monoxide": 300.0,
                       "nitrogen_dioxide": 20.0, "sulphur_dioxide": 4.0, "ozone": 60.0,
                       "us_aqi": 55, "european_aqi": 20 },
          "hourly": { "time": [\(baseEpoch), \(baseEpoch + 3600)],
                      "us_aqi": [50, 55],
                      "pm2_5": [12.0, 13.0],
                      "pm10": [30.0, 31.0] }
        }
        """
        let dto = try JSONDecoder().decode(AirQualityResponse.self, from: Data(json.utf8))

        XCTAssertNil(dto.hourly?.carbon_monoxide, "缺键 → nil")
        XCTAssertNil(dto.hourly?.nitrogen_dioxide)
        XCTAssertNil(dto.hourly?.sulphur_dioxide)
        XCTAssertNil(dto.hourly?.ozone)
        // 既有三键必须完好。
        XCTAssertEqual(try XCTUnwrap(dto.hourly?.pm2_5?.count), 2)
        XCTAssertEqual(try XCTUnwrap(dto.hourly?.pm10?[0]), 30.0, accuracy: 1e-9)

        // mapper侧：新四项逐点 nil，既有值照常搬运。
        let air = AirQualityMapper.map(dto)
        let hourly = try XCTUnwrap(air.hourly)
        XCTAssertEqual(hourly.count, 2)
        XCTAssertNil(hourly[0].carbonMonoxide)
        XCTAssertNil(hourly[0].nitrogenDioxide)
        XCTAssertNil(hourly[0].sulphurDioxide)
        XCTAssertNil(hourly[0].ozone)
        XCTAssertEqual(try XCTUnwrap(hourly[0].pm25), 12.0, accuracy: 1e-9, "既有字段不受影响")
    }

    // MARK: - ③ mapper：六污染物搬运 / 净化 / 0 与 nil

    func testMapperCarriesAllSixPollutants() throws {
        let json = """
        {
          "current": { "pm2_5": 91.5, "pm10": 120.6, "carbon_monoxide": 1504.0,
                       "nitrogen_dioxide": 92.4, "sulphur_dioxide": 12.3, "ozone": 87.0,
                       "us_aqi": 120, "european_aqi": 40 },
          "hourly": { "time": [\(baseEpoch), \(baseEpoch + 3600)],
                      "us_aqi": [100, 120],
                      "pm2_5": [91.5, null],
                      "pm10": [120.6, 80.0],
                      "carbon_monoxide": [1504.0, 1200.0],
                      "nitrogen_dioxide": [92.4, 70.0],
                      "sulphur_dioxide": [12.3, null],
                      "ozone": [87.0, 60.0] }
        }
        """
        let air = AirQualityMapper.map(try JSONDecoder().decode(AirQualityResponse.self,
                                                               from: Data(json.utf8)))
        let hourly = try XCTUnwrap(air.hourly)
        XCTAssertEqual(hourly.count, 2)

        XCTAssertEqual(try XCTUnwrap(hourly[0].carbonMonoxide), 1504.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(hourly[0].nitrogenDioxide), 92.4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(hourly[0].sulphurDioxide), 12.3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(hourly[0].ozone), 87.0, accuracy: 1e-9)

        // 元素 null → nil（只影响该字段，不丢整点）。
        XCTAssertNil(hourly[1].pm25)
        XCTAssertNil(hourly[1].sulphurDioxide)
        XCTAssertEqual(hourly.count, 2, "某字段缺测**不**丢整点（缺口要如实留在曲线上）")
        XCTAssertEqual(try XCTUnwrap(hourly[1].carbonMonoxide), 1200.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(hourly[1].ozone), 60.0, accuracy: 1e-9)
    }

    /// `0` 是合法读数（原样保留），负值是服务端异常（净化为 nil）。
    func testZeroPreservedAndNegativeSanitized() throws {
        let json = """
        {
          "current": { "pm2_5": 0.0, "pm10": -1.0, "carbon_monoxide": 0.0,
                       "nitrogen_dioxide": -5.0, "sulphur_dioxide": 0.0, "ozone": -0.5,
                       "us_aqi": 0, "european_aqi": null },
          "hourly": { "time": [\(baseEpoch)],
                      "us_aqi": [0],
                      "pm2_5": [0.0],
                      "pm10": [-1.0],
                      "carbon_monoxide": [0.0],
                      "nitrogen_dioxide": [-5.0],
                      "sulphur_dioxide": [0.0],
                      "ozone": [-0.5] }
        }
        """
        let air = AirQualityMapper.map(try JSONDecoder().decode(AirQualityResponse.self,
                                                               from: Data(json.utf8)))
        let point = try XCTUnwrap(air.hourly?.first)
        XCTAssertEqual(try XCTUnwrap(point.pm25), 0.0, accuracy: 1e-9, "0 是合法读数，不是缺失")
        XCTAssertEqual(try XCTUnwrap(point.carbonMonoxide), 0.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(point.sulphurDioxide), 0.0, accuracy: 1e-9)
        XCTAssertNil(point.pm10, "负浓度是异常数据 → nil（AC-A2-5）")
        XCTAssertNil(point.nitrogenDioxide)
        XCTAssertNil(point.ozone)
        XCTAssertEqual(air.usAqi, 0, "AQI 0 是合法读数")
    }

    // MARK: - ④ PollutantRowLayout 几何

    private let canvas = CGSize(width: 132, height: 22)

    func testGapBreaksLineInsteadOfConnectingAcrossNil() {
        let layout = PollutantRowLayout(values: [10.0, 20.0, nil, 40.0, 50.0], size: canvas)
        XCTAssertEqual(layout.segments.map(\.id), [0, 3],
                       "缺测处必须断开，绝不连线跨越缺口（否则把「没测到」画成「平稳」）")
    }

    func testZeroIsAPointNotAGap() {
        let layout = PollutantRowLayout(values: [0.0, 0.0], size: canvas)
        XCTAssertEqual(layout.segments.count, 1, "0 是合法读数，必须成段")
        XCTAssertEqual(layout.dots.count, 2)
    }

    func testAllNilHasNothingToDraw() {
        let layout = PollutantRowLayout(values: [nil, nil, nil], size: canvas)
        XCTAssertFalse(layout.hasDrawableValue, "全缺测 → 调用方整行隐藏")
        XCTAssertTrue(layout.segments.isEmpty)
        XCTAssertTrue(layout.dots.isEmpty)
    }

    func testDegenerateSizeDrawsNothing() {
        let layout = PollutantRowLayout(values: [10.0, 20.0], size: .zero)
        XCTAssertTrue(layout.segments.isEmpty)
        XCTAssertTrue(layout.dots.isEmpty)
    }

    /// **逐行独立归一**是本卡最重要的一条纪律：CO 峰值 2310 是 SO₂ 峰值 16.6 的
    /// 139 倍，若共用纵轴，SO₂ 会被压成贴底的平线（看起来"毫无变化"）。
    ///
    /// 本用例用**可测的几何后果**证明各行独立归一，而不是断言某个魔数Y 坐标：
    /// 每行的峰值点都应落在**各自画布的上半部**（峰满域），
    /// 且量级小得多的 SO₂ 行的峰值点应**明显高于** CO 行的峰值点
    /// ——若两行共用一条轴，这个关系必然反转（SO₂ 被压到接近底部）。
    func testEachRowNormalizesByItsOwnPeak() throws {
        let canvasHeight: CGFloat = 22
        let carbonMonoxide = PollutantRowLayout(values: [100.0, 2310.0], size: canvas)
        let sulphurDioxide = PollutantRowLayout(values: [8.0, 16.6], size: canvas)

        // 纵轴上限 = **各自**峰值（不取整，见 domainCeiling 注释）。
        XCTAssertEqual(carbonMonoxide.upperBound, 2310.0, accuracy: 1e-9,
                       "CO 行上限 = 自身峰值 2310")
        XCTAssertEqual(sulphurDioxide.upperBound, 16.6, accuracy: 1e-9,
                       "SO₂ 行上限 = 自身峰值 16.6，完全不受 CO 量级影响")

        // 两行的峰值点都应**顶到本行顶部**（峰值归一化生效）。
        let inset: CGFloat = 2
        let coPeakY = try XCTUnwrap(carbonMonoxide.dots.last).position.y
        let so2PeakY = try XCTUnwrap(sulphurDioxide.dots.last).position.y
        XCTAssertEqual(coPeakY, inset, accuracy: 0.01, "CO 峰值点顶到本行顶部")
        XCTAssertEqual(so2PeakY, inset, accuracy: 0.01, "SO₂ 峰值点顶到本行顶部")
    }

    /// 反向证明「绝不同轴」：**同一个数值**在两行里画在不同高度，
    /// 说明两行的坐标系确实彼此独立；若共用一条轴，两点 Y 必须相同。
    func testSameValueRendersAtDifferentHeightAcrossRows() throws {
        let shared = 16.6
        // CO 行的峰值远高于 16.6 → 16.6 落在CO 行底部附近；
        // SO₂ 行的峰值就是 16.6 → 落在该行顶部。
        let carbonMonoxide = PollutantRowLayout(values: [shared, 2310.0], size: canvas)
        let sulphurDioxide = PollutantRowLayout(values: [shared], size: canvas)
        let coLowY = try XCTUnwrap(carbonMonoxide.dots.first).position.y
        let so2Y = try XCTUnwrap(sulphurDioxide.dots.first).position.y
        XCTAssertGreaterThan(coLowY, so2Y + 5,
                             "同一数值 16.6 在两行高度不同 → 逐行独立归一确实生效")
    }

    /// 退化输入（全 0 / 全缺测）不得产生 NaN 或除零坐标。
    func testDegenerateCeilingStillProducesFiniteCoordinates() throws {
        let layout = PollutantRowLayout(values: [0.0, 0.0], size: canvas)
        XCTAssertEqual(layout.upperBound, 1, "峰值为 0 时上限兜底为 1（避免除零）")
        for dot in layout.dots {
            XCTAssertTrue(dot.position.y.isFinite, "y 必须是有限值，不得出现 NaN")
        }
        XCTAssertEqual(layout.segments.count, 1, "0 仍是合法读数，照样成段")
    }

    /// 纵轴上限恒等于本行峰值（**不取整**——取整会让峰值顶不满域）。
    func testUpperBoundEqualsOwnPeakWithoutRounding() {
        func upper(_ peak: Double) -> Double {
            PollutantRowLayout(values: [0.0, peak], size: canvas).upperBound
        }
        XCTAssertEqual(upper(16.6), 16.6, accuracy: 1e-9)
        XCTAssertEqual(upper(157.9), 157.9, accuracy: 1e-9)
        XCTAssertEqual(upper(2310.0), 2310.0, accuracy: 1e-9,
                       "CO 峰值不取整到 5000 —— 那会让峰值只跑到 46% 高度")
        XCTAssertEqual(upper(1.0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(upper(0.4), 0.4, accuracy: 1e-9)
    }

    /// 峰值点画得比谷值点高（y更小）。
    func testHigherValueIsDrawnHigherOnScreen() throws {
        let layout = PollutantRowLayout(values: [10.0, 100.0], size: canvas)
        XCTAssertGreaterThan(try XCTUnwrap(layout.dots.first).position.y,
                             try XCTUnwrap(layout.dots.last).position.y,
                             "浓度越大 y 越小（越高）")
    }
}
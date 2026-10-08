//
//  SourceCapability.swift
//  Core / Logic  [App + Widget 共用]
//
//  源能提供哪一类「能力」（不是「能替代整包」）。
//  第二源 sunrise-sunset.org 只声明 `.solarEvents`，故只能补日出/日落那一格，
//  无法挂上温度/降水/风——这正是「按能力挂载」而非「按整源替换」的落点（ARCH §3.2）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 数据源能力（按能力挂载的寻址单位）。
enum SourceCapability: String, Codable, CaseIterable, Sendable {
    case currentObservation      // 实况标量
    case hourlyForecast          // 逐时序列
    case dailyForecast           // 逐日序列
    case minutelyPrecipitation   // 短时降水（15min）
    case airQuality
    case historicalArchive
    case ensemble
    case geocoding
    case solarEvents             // 日出/日落/昼长/太阳正午 ← 第二源只需这一项
    case basicNumericFields      // 基础数值标量：温/压/湿/云量/风速/风向
                                 // ← 第三源 MET Norway（compact）只声明这一项。
                                 //   单列一个 case 而不复用 `.currentObservation`：
                                 //   `.currentObservation` 隐含体感温度 / 天气码 / 降水等
                                 //   本轮并不提供 → 复用会**虚报能力**（下游按能力寻址时会误信）。
                                 //   同一条纪律在此复述一次，因为下面两个 case 面临**完全相同**的诱惑：
    case marineWaveConditions    // 海浪要素：浪高 / 浪向 / 周期 / 涌浪 ← 第四源 marine。
                                 //   ⚠️ **不复用 `.dailyForecast`**（它隐含高低温 / 天气码 / 降水概率，
                                 //   marine 端点一条都不提供）→ 复用即虚报能力。
                                 //   也**不复用 `.currentObservation`**：marine 无温度 / 气压 / 湿度。
    case riverDischarge          // 河道流量（river_discharge，m³/s）← 第五源 flood。
                                 //   ⚠️ 这是**逐日**序列，但语义与天气逐日预报毫无关系
                                 //   （无高低温、无天气码），故同样单列而不复用 `.dailyForecast`。
    case officialWarning         // 官方气象预警（预警信号 / 颜色等级 / 防御指南）
                                 //   ← 第六源 NMC（中国气象局）。
                                 //   ⚠️ **不复用 `.currentObservation`**（它隐含温压湿 /
                                 //   天气码 / 降水，预警一条都不提供）→ 复用即虚报能力。
                                 //   也**不复用 `.dailyForecast`**（预警是**即时事件**、
                                 //   随时增删，与逐日预报序列无关）。
                                 //   单列的另一个理由：预警的领域模型是**列表**而非
                                 //   `WeatherFieldKey` 域内的标量，混进既有能力枚举
                                 //   会逼出一个假字段（见 `SourceCapability` 文件头）。
    case typhoonTrack           // 台风路径与官方预报（路径点/ 强度 / 风圈 / BABJ 预报）
                                 //   ← 第七源 NMC 台风网。
                                 //   ⚠️ **不复用 `.officialWarning`**（预警是**信号**，
                                 //   台风是**连续轨迹 + 预报序列**，语义完全不同）；
                                 //   也**不复用 `.dailyForecast`**（台风路径是**逐 3~6 小时**
                                 //   的高频轨迹，不是逐日预报，且含经纬度坐标 ——
                                 //   那是 `WeatherFieldKey` 域里根本没有的维度）。
                                 //   与预警同款：领域模型是**列表**且在 `WeatherFieldKey`
                                 //   域之外 → `requiredFields` 诚实留空。
    case marineTide             // 潮汐（`sea_level_height_msl`，逐 15 分钟）← 第四源 marine。
                                 //   ⚠️ **不复用 `.hourlyForecast`**（那隐含温度/降水/风量纲，
                                 //   潮高是**米**、且是相对全球平均海平面的**水位**，
                                 //   复用即虚报能力）。
                                 //   也**不复用 `.marineWaveConditions`**：浪是**瞬时**标量、
                                 //   潮是**逐时序列**且基准面完全不同（一个是波高，一个是水位）。
                                 //   单列的第三个理由：潮汐有独立的**语义边界**
                                 //   （数值含倒压效应、基准面为全球平均海平面），
                                 //   必须能被单独署名 —— 见 `TideForecast` 文件头。
    case coarseFallbackFields   // 兜底标量：2 米气温 + 修正海平面气压 + 风向 ← 第八源 7timer!
                                 //  （`www.7timer.info`，免 Key，与主源**不同 CDN / 不同服务端软件**）。
                                 //  ⚠️ **绝不复用 `.basicNumericFields`**（第三源 MET Norway 那一位）：
                                 //   后者含温/压/湿/云/风**五项**，而本源的湿度 / 云量 / 风速
                                 //   上游给的是**档位码**（`rh2m` 实测 −3…10、`cloudcover` 1…9、
                                 //   `wind10m.speed` 仅 {2,3,5}）而**不是**百分比 / m/s
                                 //   （逐条实测 + 官方 doc 的值定义表，见 `SevenTimerMapper`
                                 //   文件头的诚实性对照表）→ 复用即**虚报能力**，
                                 //   且会让下游把档位码当物理量渲染出**错误数据**。
                                 //  单列同时也是「兜底源」这个**角色**的显式声明：
                                 //   它与「参与常规链路的源」在语义与触发时机上都不同。
}

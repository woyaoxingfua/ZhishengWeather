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

    case qWeatherDailyForecast   // 和风侧逐日预报（高低温/现象/昼夜分块/天文）← 第九源 和风天气。
                                 //  ⚠️ **不复用 `.dailyForecast`**：那一条隐含的是
                                 //  **本项目既有逐日域**（`WeatherFieldKey` 内的
                                 //  温度 / 天气码 / 降水概率等标量），而和风的逐日结构是
                                 //  **自带单位的量纲对象 + 昼夜分块 + 天文时刻**
                                 //  （`temperatureMax.value` 与 `unit` 成对、
                                 //  `humidity` / `cloudCover` 是 **[0,1] 而非 0–100**、
                                 //  `daytime` / `nighttime` **同构但分块**）——
                                 //  语义与既有逐日预报**不同源、不同量纲**。
                                 //  复用即虚报能力，且会让下游按既有逐日域去寻址，
                                 //  把 [0,1] 的湿度当成百分数渲染（**量纲事故**）。
                                 //  单列的另一个理由（与 warning / typhoon 同款）：
                                 //  和风逐日要素**不在** `WeatherFieldKey` 域内
                                 //  （它属于 `QWeatherDailyForecast` 模型），
                                 //  → `requiredFields` 必须**诚实留空**。
                                 //  ⚠️ 本条仅覆盖**逐日**端点 `/weather/v1/daily/...`；
                                 //  实况端点是 `/weather/v1/current/{lat}/{lon}`
                                 //  （**不是** `/now/`，主理人 2026-10-08 逐字核实官方文档
                                 //  并**真实请求实测 200** 确认），本轮**未接入**，
                                 //  故**不**声明 `.currentObservation`（未接即不声明）。

    case earthquakeEvents        // 地震事件（震级/震中/深度/时刻/PAGER警报）← 第十源 USGS。
                                 //  ⚠️ **不复用任何既有 case**：地震要素**完全不在**
                                 //  天气域内（既不是标量气象量，也不是海洋/预警/台风），
                                 //  属于**另一个学科域**（地震学）。
                                 //  复用 `.officialWarning` 是**语义错配**——
                                 //  预警是「官方发布的警示信息」，地震是「自然界发生的物理事件」，
                                 //  两者的权威性、时效性、用户心智都不同；
                                 //  且 USGS 是**美国地质调查局**、不是气象机构。
                                 //  单列的另一个理由（同marine / flood / typhoon / warning）：
                                 //  地震要素不在 `WeatherFieldKey` 域内
                                 //  （属于 `EarthquakeEvent` 模型）
                                 //  → `requiredFields` 必须**诚实留空**。
                                 //  ⚠️ 本源**免 Key、免注册、零鉴权**（实测 2026-10-08）。

    case qWeatherHourlyForecast  // 和风侧逐时预报（温度/体感/湿度/云量/降水/气压/能见度/风/UV）← 第九源 和风天气。
                                 //  🔴 **绝不复用 `.hourlyForecast`**（那一条隐含的是
                                 //  **本项目既有逐时域**：`WeatherFieldKey` 内的
                                 //  温度 / 降水概率 / 风速等**裸标量**）。
                                 //  和风逐时的结构完全不同：
                                 //  ① 温度 / 体感 / 气压 / 能见度 / 风速 / 阵风
                                 //     全都是**自带单位的量纲对象**（`value` 与 `unit` 成对）；
                                 //  ② `humidity` / `cloudCover` 是 **[0,1] 而非 0–100**
                                 //     （实测 `humidity = 0.33`），降水概率同样 [0,1]
                                 //     但**只存在于 `precipitation.probability`** ——
                                 //     顶层**没有** `precipProbability` 这个键（实测查过）；
                                 //  ③ 时刻是 **UTC ISO8601 原始串**（不在本域内解析）。
                                 //  复用即**虚报能力**，且会让下游按既有逐时域寻址，
                                 //  把 0.33 当百分数渲染成 0.33%（**量纲事故**）。
                                 //  单列的第三个理由（同 `qWeatherDailyForecast`）：
                                 //  和风逐时要素**不在** `WeatherFieldKey` 域内
                                 //  （属于 `QWeatherHourlyForecast` 模型）
                                 //  → `requiredFields` 必须**诚实留空**。
                                 //  ⚠️ 端点 `/weather/v1/hourly/{lat}/{lon}?hours=N`
                                 //  （实测 2026-10-09 HTTP 200；`hours` 官方上限 360，
                                 //  本仓默认取 24）。🔴 **响应顶层键是 `hours` 不是 `hourly`**。
}

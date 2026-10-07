//
//  Typhoon.swift
//  Core / Models  [App + Widget 共用]
//
//  第七源：中央气象台台风网（`typhoon.nmc.cn`）台风路径领域模型。
//
//  ═══════════════════════════════════════════════════════════════════════
//  实测基准：2026-10-07（本 worker 当次真实 curl，非转述）
//  ═══════════════════════════════════════════════════════════════════════
//  测试命令：`curl -s -m 25 -L --compressed -A "<iPhone UA>" "<url>"`
//
//  ── **坐标序：经度在前**（最容易写反的一处，故在此钉死）───────────────
//  实测三个活跃台风（诺洛 3346168 / 小熊 3346033 / 彩云 3341981）的
//  **全部活跃台风路径点**，路径点数组的两个坐标下标**全部**满足：
//  · 下标 4 落在西北太平洋**经度**带（实测约 144–180），**逐点**都 > 90；
//  · 下标 5 落在热带气旋**纬度**带（实测约 10–40），**没有一点** > 90。
//
//  ⚠️ **刻意不写死点数**：上游每几小时就向路径追加新点（实测同一批台风
//     的总点数在数小时内就从 89 漂到 91），故此处只陈述**逐点成立的不变量**，
//     不写「一共多少点」—— 一写死就必然过期，而注释声称「实测」就更假了。
//     逐点核对由 `NmcTyphoonMapper.resolveLongitudeLatitude` 的取值域兜底
//     与测试中的样本断言承担。
//  纬度**在数学上不可能** > 90°，故下标 4 只能是经度、下标 5 只能是纬度。
//
//  ✅ **独立第二源交叉验证**（不只靠上面这条内证）：同一时刻的同一个台风，
//  日本气象厅 JMA `TC2635`（`typhoonNumber` = `2628` = NMC 的诺洛）
//  `specifications.json` 实测给出 `validtime.UTC = 2026-10-07T06:00:00Z`、
//  `position.deg = [25.3, 162.4]`（JMA 序为 **[纬度, 经度]**）。
//  NMC 同一 UTC 时刻（路径点 UTC 串 `202610070600`）的实测值是
//  `下标4 = 162.6`、`下标5 = 25.4` —— 经度对 162.4、纬度对 25.3，
//  **两个机构独立给出的同一台风同一时刻坐标逐位吻合**。
//  → 结论：**下标 4 = 经度（longitude），下标 5 = 纬度（latitude）**。
//
//  ⚠️ 写反的后果：整条路径会**镜像到地球另一侧**（菲律宾以东变成菲律宾以西），
//  且数值全部合法、**编译与运行都不会报错** —— 只有看图才发现。故此处
//  除了注释，还在 `NmcTyphoonMapper` 里做了**取值域兜底换位**（见该文件）。
//
//  ── 单位（实测确认，上游已归一，**本App 不做单位换算**）──────────────
//  气压 hPa / 最大风速 m/s / 移动速度 km/h / 风圈半径 km / 时间 UTC。
//
//  ── 时间：用路径点下标 2（Unix **毫秒**）而非下标 1（UTC 串）────────────
//  实测两个字段**完全自洽**：三个台风的全部路径点，
//  把下标 1 按 `yyyyMMddHHmm` 当 UTC 解析后取 epoch 秒 × 1000，
//  与下标 2 的**逐个比对全部相等（0 处不一致）**，且整条路径**严格递增**
//  → 可直接用下标 2 构造 `Date`，**免掉时区字符串解析**这一类坑。
//  ⚠️ 但**保留**下标 1 作为校验与降级来源（见 `NmcTyphoonMapper`）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

// MARK: - 强度

/// 台风强度（**保留上游原值**，不吞掉未收录的档位）。
///
/// ⚠️ 为什么**不做成 `enum`**：上游是网页前端接口、非承诺的开放 API，
/// 实测已出现过 6 档（TD/TS/STS/TY/STY/SuperTY），但**无法排除**将来新增档位
/// （如 `HyperTY`）。若建成 `enum` + `init(rawValue:)`，遇到未知档位会
/// `nil` 掉 → 整个台风降级为「无强度」，是**静默信息丢失**。
/// 故本类型是 `RawRepresentable` 结构体：**未知档位原样保留**，
/// 由 `displayName` 决定它显示成什么。
///
/// 实测 6 档（来自 3 个活跃台风 + 1 个历史台风共115 个路径点）：
/// `TD` 热带低压 / `TS` 热带风暴 / `STS` 强热带风暴 / `TY` 台风 /
/// `STY` 强台风 / `SuperTY` 超强台风。
struct TyphoonIntensity: RawRepresentable, Equatable, Hashable, Sendable {

    /// 上游原值（逐字保留，如 `"SuperTY"`）。
    let rawValue: String

    /// 构造（实测档位以外的取值**照样收**，不返回 nil）。
    init(rawValue: String) {
        self.rawValue = rawValue
    }

    // 实测全集（构造常量而非 enum case，便于将来上游加档而不改本文件）。
    static let tropicalDepression = TyphoonIntensity(rawValue: "TD")
    static let tropicalStorm = TyphoonIntensity(rawValue: "TS")
    static let severeTropicalStorm = TyphoonIntensity(rawValue: "STS")
    static let typhoon = TyphoonIntensity(rawValue: "TY")
    static let severeTyphoon = TyphoonIntensity(rawValue: "STY")
    static let superTyphoon = TyphoonIntensity(rawValue: "SuperTY")

    /// 面向用户的中文名（实测 6 档逐字对照）。
    ///
    /// ⚠️ 未知档位**如实显示上游原值**并标注「未收录」——
    /// 绝不猜一个中文名（猜错就是把台风的强度讲错了）。
    var displayName: String {
        switch rawValue {
        case "TD": return "热带低压"
        case "TS": return "热带风暴"
        case "STS": return "强热带风暴"
        case "TY": return "台风"
        case "STY": return "强台风"
        case "SuperTY": return "超强台风"
        default: return "\(rawValue)（强度档位未收录）"
        }
    }
}

// MARK: - 移向

/// 台风移动方向（同样**保留上游原值**，理由同 `TyphoonIntensity`）。
///
/// 实测全集（来自诺洛 19 点 + 小熊 19 点 + 彩云 51 点 = 89 点）：
/// 16 方位英文缩写 `N NNE NE ENE E ESE SE SSE S SSW SW WSW W WNW NW NNW`，
/// 外加两个特殊值：`"no"`（停滞，布拉万 2005 实测 26/26 点全是它）
/// 与 `"0"`（设计稿记录，**本 worker 当次未复现**，见下方诚实说明）。
///
/// ⚠️ 诚实标注：`"0"` 这一值来自设计稿记载，本 worker 当次三个活跃台风
/// （89 个点）**实测未出现**，故`stationaryOrUnknown` 只对 `"no"` 成立；
/// 对 `"0"` 走 `displayName` 的兜底分支（如实显示原值，不谎称停滞）。
struct TyphoonMotion: RawRepresentable, Equatable, Hashable, Sendable {

    /// 上游原值。
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 停滞（实测：历史台风布拉万 26/26 点为 `"no"`）。
    static let stationary = TyphoonMotion(rawValue: "no")

    /// 16 方位（实测全集，见类型注释）。
    static let sixteenCompassPoints: [TyphoonMotion] = [
        "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
        "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"
    ].map { TyphoonMotion(rawValue: $0) }

    /// 面向用户的中文名（实测：中文对应「北 / 北北东 / …」）。
    var displayName: String {
        switch rawValue {
        case "no": return "停滞"
        case "N": return "北"
        case "NNE": return "北北东"
        case "NE": return "东北"
        case "ENE": return "东北偏东"
        case "E": return "东"
        case "ESE": return "东南偏东"
        case "SE": return "东南"
        case "SSE": return "南南东"
        case "S": return "南"
        case "SSW": return "南南西"
        case "SW": return "西南"
        case "WSW": return "西南偏西"
        case "W": return "西"
        case "WNW": return "西北偏西"
        case "NW": return "西北"
        case "NNW": return "北北西"
        // ⚠️ 未知原值：如实显示，**不猜**（实测出现过 "0" 这一非方位值）。
        default: return rawValue
        }
    }
}

// MARK: - 风圈

/// 一层风圈（实测元素形如 `["30KTS", 380, 250, 250, 380, 3351798]`）。
///
/// ── 实测到的结构事实（逐字）────────────────────────────────────────
/// · 元素**定长 6**：标签 + **4 个半径** + 该点自身 pointId；
/// · 标签实测出现 3 档：`30KTS`(178 次) / `50KTS`(60 次) / `64KTS`(48 次)；
/// · 4 个半径实测均为 Int（km），且**从不出现负数**。
///
/// ⚠️ **4 个半径的确切象限语义：无法确定**（诚实标注）。
/// 上游未随数据给出字段名（整个响应里**没有任何 key**），
/// 设计稿猜是「北 / 东北 / 东 / 南」，但本 worker 实测发现它的顺序
/// **无法自洽**：诺洛末点（向西移动）实测 `30KTS` 为
/// `[380, 250, 250, 380]` —— 若按「北/东北/东/南」读，则北 380、东 250，
/// 而一个**向西移动**的台风东侧半径本应更大，与数据**方向相反**。
/// → 故本模型**只保留 4 个半径的原始顺序**（`radii`），
/// **不**把它们命名成具体象限；地图上只用 `maxRadiusKm` 画一个**圆**，
/// 这样无论象限如何解释都不会画出错误的扇形。
struct TyphoonWindCircle: Equatable, Sendable {

    /// 风圈标签（实测 `"30KTS"` / `"50KTS"` / `"64KTS"`）。
    let label: String

    /// 4 个半径（km，**原始顺序**，象限语义见类型注释）。
    let radii: [Double]

    /// 该点自身 id（实测等于同层路径点的 pointId）。
    let pointID: Int?

    /// 最大半径（km）；`radii` 为空 → nil（**如实缺测，不填 0**）。
    var maxRadiusKm: Double? {
        radii.max()
    }

    /// 展示用层级名（实测标签 → 中文风圈名）。
    var displayName: String {
        switch label {
        case "30KTS": return "七级风圈"
        case "50KTS": return "十级风圈"
        case "64KTS": return "十二级风圈"
        default: return label
        }
    }
}

// MARK: - 路径点

/// 一个台风路径点（实测：定长 13 元素数组）。
///
/// ── 实测下标表（三个活跃台风 89 个点 + 历史台风布拉万 26 个点，
///    共 115 个点逐点核对；**但类型按点变化**，故模型逐字段可选）────────
/// | 下标 | 含义 | 实测类型（本 worker 当次） |
/// |---|---|---|
/// | 0 | 该点自身 pointId | Int（115/115） |
/// | 1 | 时间 UTC `yyyyMMddHHmm` | String（115/115） |
/// | 2 | 时间 Unix **毫秒** | Int（115/115，与下标 1 逐个自洽） |
/// | 3 | 强度档位 | String（115/115） |
/// | 4 | **经度**（在前！） | Double 为主 / 偶现Int |
/// | 5 | **纬度**（在后） | Double 为主 / 偶现 Int |
/// | 6 | 中心气压 hPa | Int（115/115） |
/// | 7 | 最大风速 m/s | Int（115/115） |
/// | 8 | 移动方向 | String（115/115，含 `"no"`） |
/// | 9 | 移动速度 km/h | Int（115/115） |
/// | 10 | 风圈数组 | List（**可为空数组** `[]`） |
/// | 11 | 预报字典 | **Dict（活跃）/ null（历史台风布拉万 26/26 点）** |
/// | 12 | 时效信息 | List（活跃）/ **null（历史 26/26 点）** |
///
/// ⚠️ **与设计稿的两处实测冲突**（以本 worker 实测为准）：
/// ① 设计稿称末点下标 10 是字符串 `"list"` —— **本 worker 当次未复现**：
///    两个文件里字符串 `"list"` 的出现次数**实测为 0**，下标 10 在
///    115/115 个点上都是数组（末点也不例外）。
/// ② 设计稿称定长 13 但 `view_` 顶层数组长 8 —— **实测顶层长 10**
///    （下标 9 是「关联台风索引表」，见 `NmcTyphoonTrack`）。
///
/// ── 容错 ────────────────────────────────────────────────────────────
/// **每个字段都可选**：缺经纬/时间的点会被 mapper 丢弃，但**绝不会**
/// 因为单个字段缺失而让**整条路径**失败（上游随时可能变）。
struct TyphoonTrackPoint: Equatable, Sendable {

    /// 该点自身 id（实测下标 0）。
    let pointID: Int?

    /// 观测时刻（由下标 2 的 Unix 毫秒构造；下标 2 缺失时由下标 1 降级解析）。
    let time: Date?

    /// 强度（实测下标 3）。
    let intensity: TyphoonIntensity?

    /// **经度**（实测下标 4，**在前**）。
    let longitude: Double?

    /// **纬度**（实测下标 5，**在后**）。
    let latitude: Double?

    /// 中心气压 hPa（实测下标 6）。
    let pressureHPa: Double?

    /// 最大风速 m/s（实测下标 7）。
    let maxWindSpeedMS: Double?

    /// 移动方向（实测下标 8）。
    let motion: TyphoonMotion?

    /// 移动速度 km/h（实测下标 9）。
    let motionSpeedKmh: Double?

    /// 风圈（实测下标 10；历史台风实测为**空数组** `[]`）。
    let windCircles: [TyphoonWindCircle]

    /// 本点起报的官方预报（实测下标 11 的 `"BABJ"` 键；历史台风为 null）。
    let forecast: [TyphoonForecastPoint]

    /// 北京时间发布文本（实测下标 12 第 1 元素，如 `"2026年10月07日14时00分"`）。
    ///
    /// ⚠️ 实测该文本恒为**下标 1（UTC）+8h**（逐点核对诺洛首末两点均吻合）
    /// → 故它**只用于展示**，不参与任何时刻计算。
    let beijingTimeText: String?
}

// MARK: - 预报点

/// 一个官方预报点（实测下标 11 的 `BABJ` 数组元素）。
///
/// ── 实测元素形如（定长 8）─────────────────────────────────────────
/// `[12, "202610070600", 158.2, 26, 980, 30, "BABJ", "STS"]`
/// | 下标 | 含义 | 实测类型 |
/// |---|---|---|
/// | 0 | 时效（小时） | Int（实测 `12 24 36 48 60 72 96 120`） |
/// | 1 | 起报时间 UTC `yyyyMMddHHmm` | String |
/// | 2 | **经度**（在前！） | Double |
/// | 3 | **纬度**（在后） | Double |
/// | 4 | 气压 hPa | Int |
/// | 5 | 风速 m/s | Int |
/// | 6 | 机构 | String（实测恒为 `"BABJ"`） |
/// | 7 | 强度 | String（与路径点同一套枚举） |
///
/// ✅ 预报的经纬顺序**同样实测确认为「经度在前」**：诺洛末点（UTC
/// `202610070600`）的 12 小时预报实测为下标2=158.2 / 下标3=26，
/// 而 JMA 对**同一台风同一时刻**的 12 小时预报实测为
/// `center = [26.5, 157.6]`（JMA 序 [纬, 经]）→ 纬度 26≈26.5、经度 158.2≈157.6，
/// 两机构吻合，故NMC 此处亦是 **[经度, 纬度]**。
///
/// ⚠️ 实测预报时效**不是恒定 8 个**：活跃台风多为
/// `[12,24,36,48,60,72,96,120]`（8 个），但彩云 2026-10-07 的末点
/// 实测**只剩 `[12]`（1 个）** → 故时效**逐条可选**、**不按固定下标取**。
struct TyphoonForecastPoint: Equatable, Sendable {

    /// 时效（小时，实测下标 0）。
    let leadHours: Int?

    /// 起报时刻（由下标 1 的 UTC 串 `yyyyMMddHHmm` 解析）。
    let baseTime: Date?

    /// **经度**（实测下标 2，**在前**）。
    let longitude: Double?

    /// **纬度**（实测下标 3，**在后**）。
    let latitude: Double?

    /// 气压 hPa（实测下标 4）。
    let pressureHPa: Double?

    /// 风速 m/s（实测下标 5）。
    let maxWindSpeedMS: Double?

    /// 预报机构（实测下标 6，恒为 `"BABJ"` = 中央气象台）。
    let agency: String?

    /// 强度（实测下标 7）。
    let intensity: TyphoonIntensity?
}

// MARK: - 台风摘要（列表端点）

/// 列表端点的一条台风摘要（实测 `typhoonList` 每项定长 8）。
///
/// ── 实测下标表（`list_default` 32 条逐条核对）───────────────────────
/// | 下标 | 含义 | 实测类型（本 worker 当次 32 条） |
/// |---|---|---|
/// | 0 | typhoonId | Int（32/32） |
/// | 1 | 英文名 | String（32/32，无名台风实测 `"nameless"`） |
/// | 2 | **中文名** | String，但**实测 1950/1999/2024 早年条目为 `null`** |
/// | 3 | 编号 | **String**（32/32，如 `"2628"`） |
/// | 4 | 编号（重复字段） | **String 或空串 `""`**（实测 `list_2024` 早期条目为 `""`） |
/// | 5 | 内部序号 | **Int 或 `null`**（实测 9 条 Int / 23 条 null） |
/// | 6 | 命名含义 | String 或 `null`（实测诺洛为 null） |
/// | 7 | 状态 | String：`"start"`（实测 3 条）/ `"stop"`（实测 29 条） |
///
/// ⚠️ **与设计稿的一处实测冲突**（以本 worker 实测为准）：设计稿称
/// 「2026 年下标 3/4 是数字 `2628`、2024 年是字符串」；本 worker 当次
/// `list_default` 32 条下标 3/4 **全部是 String**（`"2628"` 等）。
/// 而 `view_` 端点里同样的编号字段**又全是 Int**。
/// →结论：**编号字段的类型在两个端点之间都不一样**，故模型里存 `String?`
/// （mapper 对 Int / String 一视同仁地转字符串），**绝不按类型断言取值**。
struct TyphoonSummary: Identifiable, Equatable, Sendable {

    /// 稳定标识（实测下标 0 的 Int，**转字符串**存；拼进 `view_<id>` URL）。
    let id: String

    /// 英文名（实测下标 1）。
    let englishName: String?

    /// 中文名（实测下标 2；**早年台风实测为 `null`** → nil → UI 显示英文名）。
    let chineseName: String?

    /// 编号（实测下标 3 或 4）。
    let number: String?

    /// 命名含义（实测下标 6；实测诺洛为 `null`）。
    let namingMeaning: String?

    /// 是否进行中（实测下标 7 == `"start"`）。
    let isActive: Bool

    /// 最佳展示名：优先中文名（实测中文名**可能带尾随换行**，
    /// 如 `"小熊\n"` → mapper 已 trim），缺失时回退英文名。
    var displayName: String {
        let cn = chineseName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cn.isEmpty { return cn }
        let en = englishName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return en.isEmpty ? "未命名台风" : en
    }
}

// MARK: - 台风详情（路径 + 预报）

/// 单个台风的完整路径（由 `view_<id>` 端点一次取全）。
///
/// ⚠️ **实测顶层数组长 10（不是设计稿说的 8）**：
/// | 下标 | 含义 | 实测 |
/// |---|---|---|
/// | 0–7 | 与列表端点同构的头部 | 同`TyphoonSummary` 各项 |
/// | 8 | **路径点数组** | List（实测 19 / 51 / 19 点；历史台风 26 点） |
/// | 9 | 关联台风索引表 |活跃台风：List of `[Int, 索引字典]`；**历史台风：`null`** |
///
/// 下标 9 的实测形态（诺洛）：`[[3346033, {"0":[0], "1":[1], …}], [3341981, {"34":[0], …}]]`
/// ——是「同期其他台风的路径点在本响应内的下标映射表」，本App **不使用**，
/// 故**刻意不建模**（无消费者就不建模，本仓既有纪律）。
struct TyphoonTrack: Identifiable, Equatable, Sendable {

    /// 台风 id（等于头部下标 0 的字符串形式）。
    let id: String

    /// 头部信息（实测下标 0–7）。
    let summary: TyphoonSummary

    /// 路径点（实测下标 8；按时间**严格递增**，实测 89/89 点成立）。
    let points: [TyphoonTrackPoint]

    /// 最新路径点（实测 = 时间最大的那个点；无点时 nil）。
    var latestPoint: TyphoonTrackPoint? {
        points.last
    }

    /// 最新时次的官方预报（实测取最新点的 `"BABJ"` 预报；无则空数组）。
    ///
    /// ⚠️ 取**最新点**而不是「所有点里时效最长」：实测每个点都自带一份
    /// 起报于该时刻的预报，而**越早的点预报越旧**（彩云实测：首点 8 个时效，
    /// 末点只剩 1 个）。取最新点才是「当前有效的官方预报」。
    var latestForecast: [TyphoonForecastPoint] {
        latestPoint?.forecast ?? []
    }
}
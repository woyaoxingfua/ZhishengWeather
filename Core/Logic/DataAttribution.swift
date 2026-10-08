//
//  DataAttribution.swift
//  Core / Logic  [App + Widget 共用]
//
//  **数据署名（CC BY 4.0 合规义务）** —— App 必须向用户展示「数据由谁提供 +
//  官网链接 + 本应用做了哪些转换」。
//
//  ── 为什么这是义务而不是可选项 ───────────────────────────────────────────
//  Open-Meteo 官方定价页 "Is it necessary to provide attribution to Open-Meteo?"
//  一节的原文（2026-10-06 实测抓取自 https://open-meteo.com/en/pricing ，非转述）：
//
//    "Open-Meteo relies on open data that is licenced under **Attribution 4.0
//     International (CC BY 4.0)**. **This licence mandates giving appropriate
//     credit and indicating any modifications made to the data.**"
//
//  即「署名」与「说明改动」**两项都是强制**的。本App 确实做了大量改动
//  （单位换算 / WMO 码映射 / 多源合并 / 字段级降级），故两项都必须展示。
//
//  ── 为什么单列一份Attribution 而不是直接读 SourceDirectory ────────────────
//  **源目录 ≠ 数据出处**，两者范围不同，硬合并会立刻说谎：
//  · `SourceDirectory` 是**多源降级链**的注册表（只有参与 FieldFallbackResolver
//    合并的源才在那儿：forecast / airQuality / sunriseSunset / metNorway）；
//  · 而本App **实际还调用**了三个**未注册**端点（见`unregisteredEndpointSources`）：
//    历史天气（archive-api）、集合概率（ensemble-api）、城市检索（geocoding-api）。
//    它们不在降级链里、故不在 `SourceDirectory`，但**数据确实到了用户眼前** ——
//    CC BY 4.0 义务不因「没注册成降级源」而消失。
//  故本文件按**「实际在用」**列全部出处，并对未注册端点**显式标注性质**。
//
//  ⚠️ 付费源**仅在「已接线」时才出现在此列**——
//  列一个没在用的源等于虚假署名，比不署名更糟。
//  · **和风天气（QWeather）已于 2026-10-08 接线**（第九源，需用户自备凭据）：
//    它经 `SourceDirectory` 派生获得署名条目，其 `usageNote` 如实写明
//    「需自备凭据 + 尚未经真机核验」。⚠️ 另：和风官方要求
//    `metadata.attributions`（响应里逐条下发的署名 URL）**必须与数据共同显示**，
//    那是**许可条件**、不是可选项 → 由 `QWeatherCard` 在卡片上逐条渲染。
//  · **彩云 / 心知等仍未接入**，故**不在**此列（保持原纪律）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 一条数据署名（一个实际在用的数据出处）。
struct DataAttributionEntry: Identifiable, Equatable, Sendable {

    /// 稳定标识（供测试锚定，不用于持久化）。
    let id: String
    /// 源展示名（用户看到的名字）。
    let displayName: String
    /// 官网 / 文档地址（**必须可点**——只显示网址字符串不满足 "giving credit"
    /// 的可追溯性，故设置页用 `Link` 渲染本字段）。
    ///
    /// ⚠️ 声明为**可选**是为了让「URL 字面量写错」退化为「该条被丢弃 + 测试报错」，
    /// 而不是 `URL(string:)!` 的运行期崩溃（与 SC-10 的纪律同族）。
    /// 生产构造路径（`registeredSourceEntries` / `unregisteredEndpointSources`）
    /// 末尾都做了compactMap，故**面向用户的 `allEntries` 里不会有 nil**——
    /// 由 `DataAttributionTests` 逐条断言这一点。
    let websiteURL: URL?
    /// 该源在本App 里实际提供的**字段 / 能力**（中文，面向用户）。
    let provides: String
    /// 如实备注（如「现状可用但官方矩阵不含」，非免责声明）。
    let note: String?
}

/// 数据署名目录 + 统一声明（**文案的单一真源**）。
///
/// 设置页只负责渲染，**绝不**在视图里另写一份署名文案 —— 否则文案会与本文件
/// 漂移，而漂移的合规文案等于没有合规文案（且测试锚的是本文件，视图那份没人管）。
enum DataAttribution {

    // MARK: - 统一声明

    /// 顶部**统一声明**（CC BY 4.0 + 本应用做了转换）。
    ///
    /// ⚠️ 措辞里**必须**同时出现三件事，缺一即不满足 CC BY 4.0：
    ///①出处（开放数据源）②许可（CC BY 4.0）③**已做改动**（"indicating any
    /// modifications"）。只写前两件是最常见的缺口 —— 本仓的现状正是如此。
    static let unifiedStatement: String =
        "本应用的天气、空气质量、日出日落与历史数据来自 Open-Meteo 等开放数据源，"
        + "遵循知识共享署名 4.0 国际（CC BY 4.0）许可发布。"
        + "我们对这些数据做了如下转换：温度、风速与气压的单位换算；"
        + "WMO 天气代码到中文现象与图标的映射；风向角度到八方位中文的转换；"
        + "降水与降雪深度的单位固定；以及多个数据源之间的逐字段补全"
        + "（主源优先，缺失字段才由辅助源填补，不做平均）。"
        + "每项数据的具体来源见下方列表。"

    /// 本App 实际做的转换类别（**逐条可核**，每条都对应真实代码）。
    ///
    /// 纪律：这份清单**必须与代码一致**，故每行都注明实现处；改文案时顺手核一下
    /// 那个文件还在不在、能力有没有变（否则就是一条新的不实陈述）。
    static let modificationCategories: [String] = [
        "单位换算：℃↔℉、m/s→km/h、hPa→mmHg/inHg（Core/Models/UnitPreference.swift）",
        "WMO 天气代码（0–99）→ 中文现象名与天气图标（Core/Logic/WMOCodeMapper.swift）",
        "风向角度 → 八方位中文（Core/Logic/WeatherFieldFormatters.swift 的WindDirectionFormatter）",
        "秒 → 「X 小时 Y 分」时长文案；降水锁定 mm、降雪锁定 cm（WeatherFieldFormatters.swift）",
        "多源逐字段补全：主源优先、缺失才降级、**从不平均**（Core/Logic/FieldFallbackResolver.swift）"
    ]

    /// CC BY 4.0 许可全文链接（署名区底部给出，让用户能自行核对许可条款）。
    static let licenseURL: URL? = URL(string: "https://creativecommons.org/licenses/by/4.0/")

    static let licenseDisplayName = "CC BY 4.0 许可全文"

    // MARK: - 已注册源（派生自 SourceDirectory，**不写死清单**）

    /// 已注册源的署名条目：**从 `SourceDirectory.all` 派生**。
    ///
    /// 派生而非写死的理由与`SourceCatalog.all` 同源：写死清单会与真实降级链漂移
    /// —— 新增一个源却忘了加署名，用户看到的出处就是**不完整**的（而CC BY 的
    /// 缺口恰恰是这种「漏一条」）。故此处逐条读描述符，新增源**自动**获得署名。
    static let registeredSourceEntries: [DataAttributionEntry] =
        SourceDirectory.all.compactMap { descriptor in
            guard let url = descriptor.websiteURL else { return nil }
            return DataAttributionEntry(
                id: descriptor.id.rawValue,
                displayName: descriptor.displayName,
                websiteURL: url,
                provides: providesText(for: descriptor),
                note: descriptor.usageNote)
        }

    // MARK: - 未注册端点（**在用但不在降级链**，故必须显式列出）

    /// 实际在调用、但**未注册进 `SourceDirectory`** 的端点。
    ///
    /// ⚠️ 为什么不把它们塞进 `SourceDirectory`：`SourceID` 是**持久化键**
    /// （`SourcePreferences` 把用户停用偏好以 `Set<SourceID>` 落盘、
    /// `SourceHealthLedger` 用rawValue 反序列化），擅自加 case 会改动这些语义，
    /// 且它们**不参与** `FieldFallbackResolver` 的逐字段合并 —— 硬塞进去会让
    /// `SourceDirectoryCoverageTests` 的双射守卫与「多源管理」面板**说谎**
    /// （显示成一个参与降级的源，实际不是）。故在此**如实单列**。
    /// ⚠️ 刻意**不**写 `URL(string: "...")!`：那是运行期崩溃路径，与本仓禁
    /// `try!` / `fatalError`（SC-10）的纪律同族。URL 字面量若写错会**解析成nil**
    /// （条目被 `compactMap` 掉），再由 `DataAttributionTests` 断言「一条都没被掉」
    /// —— **声明处强约束 + 解析处可失败 + 测试兜住**，而不是运行期炸弹。
    static let unregisteredEndpointSources: [DataAttributionEntry] = [
        DataAttributionEntry(
            id: "open-meteo-geocoding",
            displayName: "Open-Meteo 城市检索",
            websiteURL: urlOrNil("https://open-meteo.com/en/docs/geocoding-api"),
            provides: "城市名称与经纬度检索（搜索城市时使用）",
            note: "Open-Meteo 官方定价页把 Geocoding 列入免费档可用。"),
        DataAttributionEntry(
            id: "open-meteo-archive",
            displayName: "Open-Meteo 历史天气（ERA5 再分析）",
            websiteURL: urlOrNil("https://open-meteo.com/en/docs/historical-weather-api"),
            provides: "历史逐日气温与降水（历史天气页）",
            // ↓ 诚实纪律：archive/ensemble 是「现状可用、官方矩阵不含」，
            //   必须让用户知道，不许假装是长期免费承诺。
            note: "注意：该端点目前免 Key 可用，但 Open-Meteo 官方定价页的功能矩阵"
                + "**未**把 Historical 列入免费档。此为现状可用，不作长期免费承诺。"),
        DataAttributionEntry(
            id: "open-meteo-ensemble",
            displayName: "Open-Meteo 集合预报",
            websiteURL: urlOrNil("https://open-meteo.com/en/docs/ensemble-api"),
            provides: "温度与降水的概率区间（概率视图）",
            // ↓ 同上：不假装它是稳定承诺。
            note: "注意：该端点目前免 Key 可用，但 Open-Meteo 官方定价页的功能矩阵"
                + "**未**把 Ensemble 列入免费档。此为现状可用，不作长期免费承诺。")
    ].compactMap { entry in
        // 字面量非法 → 整条丢弃（而不是崩）。测试保证不会发生。
        entry.websiteURL.map {
            DataAttributionEntry(id: entry.id, displayName: entry.displayName,
                                 websiteURL: $0, provides: entry.provides, note: entry.note)
        }
    }

    /// 可失败地解析 URL 字面量（**不用 `!`**；非法字面量 → nil，由测试兜住）。
    private static func urlOrNil(_ string: String) -> URL? {
        URL(string: string)
    }

    /// 全部署名条目（设置页按此顺序渲染）。
    ///
    /// 顺序：已注册降级源（主源在前）→ 未注册端点。
    static var allEntries: [DataAttributionEntry] {
        registeredSourceEntries + unregisteredEndpointSources
    }

    // MARK: - 派生

    /// 该描述符的能力集 → 面向用户的中文字段说明。
    ///
    /// 按 `SourceCapability` **枚举**逐项映射（而非按源写死一句话），故新增能力
    /// 会自动出现在说明里；未知能力落到`other` 分支的兜底文案，不会静默消失。
    private static func providesText(for descriptor: SourceDescriptor) -> String {
        var names: [String] = []
        // 稳定输出：按 capability 的 CaseIterable 顺序遍历，与 Set 的存储顺序无关。
        for capability in SourceCapability.allCases
        where descriptor.capabilities.contains(capability) {
            names.append(capabilityText(capability))
        }
        return names.isEmpty ? "（未声明能力）" : names.joined(separator: "、")
    }

    /// 单个能力 → 用户可读字段名（**能力是单一真源**，此处只做展示映射）。
    ///
    /// ⚠️ 带 `@unknown default` 兜底：本函数**穷举** `SourceCapability`，而那个枚举
    /// 会随新源接入而长（如 marine / flood）。若不留兜底，将来别人加一个 case 就会
    /// 让本文件**编译不过** —— 而一个署名文件编译失败等于「合规展示整体消失」，
    /// 后果比「某个能力没有中文名」严重得多。兜底文案保证新能力**显式可见**
    /// （"（未命名能力）"）而不是被静默吞掉。
    static func capabilityText(_ capability: SourceCapability) -> String {
        switch capability {
        case .currentObservation: return "实况天气"
        case .hourlyForecast: return "逐小时预报"
        case .dailyForecast: return "逐日预报"
        case .minutelyPrecipitation: return "短时降水（15 分钟）"
        case .airQuality: return "空气质量"
        case .historicalArchive: return "历史天气"
        case .ensemble: return "集合概率"
        case .geocoding: return "城市检索"
        case .solarEvents: return "日出日落与昼长"
        case .basicNumericFields: return "温度/气压/湿度/云量/风速/风向"
        case .marineWaveConditions: return "海浪要素（浪高/浪向/周期）"
        case .riverDischarge: return "河道流量"
        case .typhoonTrack: return "台风路径与官方预报（含风圈）"
        case .marineTide: return "潮汐（逐15 分钟潮高，含高低潮极值）"
        case .coarseFallbackFields: return "兜底标量（气温/气压/风向）"
        case .qWeatherDailyForecast: return "逐日预报（和风：逐日高低温/天气现象/昼夜分块/天文，含和风指定署名）"
        case .qWeatherHourlyForecast: return "逐时预报（和风：逐时温度/体感/湿度/云量/降水/气压/能见度/风/UV，含和风指定署名）"
        @unknown default: return "（未命名能力）"
        }
    }
}
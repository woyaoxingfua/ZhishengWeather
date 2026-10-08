//
//  RegionalSourcePolicy.swift
//  Core / Logic  [App + Widget 共用]
//
//  🔴 区域化数据源：**同一张卡里两个源，谁当主源**（纯函数，2026-10-11 新增）。
//
//  ══════════════════════════════════════════════════════════════════════════
//  需求来源（主理人原话）
//  ══════════════════════════════════════════════════════════════════════════
//  「区域化数据源就同一张卡里显示吧，然后主要数据选目标地区比较好的，就是比如
//   在国内，就大写和风稍微小写openmeto或者点一下就切换到另一个数据源了。」
//
//  拆成三件事（各自独立可测）：
//   ① **谁当主源**：国内以和风为主、海外以 Open-Meteo 为主（本文件）；
//   ② **两个源都显示**：主源大字号、次源小字（`QWeatherCard`）；
//   ③ **点一下切换**：用户可把次源升为主（`QWeatherCard`，会话内有效）。
//
//  ── 为什么「国内」优先看 `City.country`，坐标只作兜底 ────────────────────
//  `City.country: String?` 是**既有字段**（由 geocoding 下发，见 `GeocodingMapper`
//  透传），语义精确。坐标包围盒是**粗判**：中国境内的矩形（见下方常量）
//  必然包含蒙古 / 俄罗斯远东 / 印度北部 / 越南等邻国 —— 用它当**首选**判据
//  就等于把「乌兰巴托」判成国内。故优先级是：
//     `country` 有值 → 用它（精确）；`country` 为 nil → 才退到坐标粗判。
//
//  ⚠️ **坐标粗判的已知误差必须承认**：它分不清「国境内的邻国」与「国内」。
//  它只在「country 缺失」时生效（实测：内置城市恒为「中国」；`当前位置`
//  与搜索结果通常有 country；country 缺失主要是「当前位置」这一条路径），
//  而此时**另一个选择是不判**—— 那会让海外用户默认拿和风当主源，
//  而和风对海外的覆盖与本地化都不如 Open-Meteo。两者皆不完美，
//  故取「错判范围更小」的一方，并把这条局限写在这里而不是藏起来。
//
// ── 「和风更权威」的理由（不是凭偏好）────────────────────────────────────
//  · 和风天气的逐日预报源自**中国气象局 / 中央气象台**体系，对国内城市
//    的预报口径与本地化文案（`condition.text` 直接下发中文）更贴合；
//  · Open-Meteo 是**全球统一模式**，对国内无本地化优势，但**免 Key**、
//    全球覆盖一致，且是本仓既有的**主源**（`SourceID.openMeteoForecast`）。
//  → 故国内和风为主、海外 Open-Meteo 为主。**这不是「谁数据更好」的断言**，
//    而是「在该地区谁的口径更合适」的取舍；两者都同时显示，用户可自行切换。
//
// Core 纪律：仅 import Foundation；纯函数（无 I/O、无内部时钟）；
// 禁 UIKit / try! / fatalError / as!。
//

import Foundation

/// 目标地区（决定「哪个源当主源」）。
enum WeatherRegion: String, Codable, Equatable, Sendable, CaseIterable {

    /// 中国大陆及港澳台（和风的主场）。
    case china

    /// 中国境外（Open-Meteo 的主场：全球统一模式、免 Key）。
    case overseas

    /// **判不出来**（既无 country、坐标又缺失 / 非有限）。
    ///
    /// ⚠️ 刻意**不并入 overseas**：本枚举会被 UI 用来显示
    /// 「按地区选源」这句话，`unknown` 时那句文案必须换成
    /// 「无法判定地区，已按默认源显示」—— 混进 `overseas` 就是谎报。
    case unknown
}

/// 区域 → 主源 的裁定（纯函数）。
enum RegionalSourcePolicy {

    // MARK: - 中国判定

    /// 视为「中国」的国家名（**小写、已 trim**）。
    ///
    /// ⚠️ 只收**能确定是中国**的写法。geocoding 下发的 `country` 实测是
    ///   中文名（如「中国」）。这里同时收英文 / 代码是因为不同部署可能给
    ///   `country_code` 形态（实测 Open-Meteo geocoding 确有 `country_code`），
    ///   两种都收比只收一种更稳；**收不全的风险是「退到坐标粗判」**，
    ///   不会造成「把中国判成海外」这种更糟的错判。
    private static let chinaCountryNames: Set<String> = [
        "中国", "中华人民共和国", "中国大陆",
        "china", "people's republic of china", "prc", "cn", "zh",
        // 港澳台：和风对它们有覆盖，且用户预期与大陆一致。
        "中国香港", "中国澳门", "中国台湾",
        "香港", "澳门", "台湾", "香港特别行政区", "澳门特别行政区",
        "hong kong", "macau", "macao", "taiwan",
    ]

    /// 中国大陆的**粗略**包围盒（WGS84，**仅在 `country` 缺失时使用**）。
    ///
    /// ⚠️ **它必然包含邻国**（蒙古 / 俄远东 / 印度北部 / 越南 / 朝鲜半岛北部）。
    ///   这是「用矩形表达一个形状不规则的区域」的固有代价，已在类型注释里
    ///   写明；正因为有误差，才排在 `country` **之后**。
    static let chinaLatitudeRange: ClosedRange<Double> = 18.0...54.0
    /// 同上：中国大陆粗略经度范围（**含误差，见上**）。
    static let chinaLongitudeRange: ClosedRange<Double> = 73.0...135.0

    /// 判定目标地区。
    ///
    /// 优先级：`country`（精确） → 坐标包围盒（粗判） → `.unknown`。
    ///
    /// - Parameters:
    ///   - country: `City.country`（**可缺**；不做任何猜测，nil 就走坐标）。
    ///   - latitude: WGS84 纬度（可缺；非有限值视为缺失）。
    ///   - longitude: WGS84 经度（可缺）。
    /// - Returns: 地区；**判不出来时返回 `.unknown`**（绝不默认 `.overseas`）。
    static func region(country: String?,
                       latitude: Double?,
                       longitude: Double?) -> WeatherRegion {
        if let country {
            let normalized = country.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if chinaCountryNames.contains(normalized) { return .china }
            // ⚠️ country 有值但**不**是中国 → 直接 `.overseas`，**不再看坐标**：
            //   坐标只能说出「大概在哪」，而 country 是确切答案 —— 用更弱的
            //   证据去覆盖更强的证据是本仓明令禁止的（`Snapshot` 系列的同款纪律）。
            return .overseas
        }

        // country 缺失 → 坐标粗判（两条都在且落在矩形内才算中国）。
        guard let latitude, let longitude,
              latitude.isFinite, longitude.isFinite,
              chinaLatitudeRange.contains(latitude),
              chinaLongitudeRange.contains(longitude) else {
            // ⚠️ 坐标缺失 / 非有限 → **判不出来**，如实返回 `.unknown`。
            //   绝不因为「拿不准」就默认 `.overseas` —— 那会让国内用户
            //   看到「按海外选择数据源」这句假话。
            return .unknown
        }
        return .china
    }

    /// 该地区**默认**的主源（用户未手动切换时生效）。
    ///
    /// ⚠️ `.unknown` → **Open-Meteo**：它是本仓**免 Key 的既有主源**，
    ///   在「判不出地区」时选它是风险最小的一侧（不依赖任何凭据，全球一致）。
    ///   ⚠️ 这**不是**「判成海外」，`.unknown` 的文案会另行如实说明。
    static func defaultPrimarySource(for region: WeatherRegion) -> SourceID {
        switch region {
        case .china: return .qWeather
        case .overseas, .unknown: return .openMeteoForecast
        }
    }

    /// 「当前地区为什么这样选源」→ 用户可读说明（**主源侧文案**）。
    static func rationaleText(for region: WeatherRegion) -> String {
        switch region {
        case .china:
            return "已按国内口径选择主数据源（和风天气）；另一数据源同时显示，可点按切换。"
        case .overseas:
            return "已按海外口径选择主数据源（Open-Meteo）；另一数据源同时显示，可点按切换。"
        case .unknown:
            // 🔴 「判不出来」必须**说出来** —— 绝不假装按地区选过。
            return "无法判定当前地区（缺国家信息），已默认使用 Open-Meteo；"
                + "另一数据源同时显示，可点按切换。"
        }
    }
}
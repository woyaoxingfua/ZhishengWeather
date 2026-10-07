//
//  NmcTyphoonMapper.swift
//  Core / Networking  [App + Widget 共用]
//
//  第七源 DTO → 领域模型映射（**纯函数**，无 IO / 无日志 / 不读 `Date()`)。
//
//  ═══════════════════════════════════════════════════════════════════════
//  实测基准：2026-10-07（本 worker 当次真实 curl）
//  实测样本：列表端 4 个（list_default 32 条 / list_1950 42 条 /
//            list_1999 28 条 / list_2024 28 条）+详情端 4 个
//            （诺洛 3346168 / 彩云 3341981 / 小熊 3346033 /
//            布拉万 3227033）→ 逐点核对过全部活跃台风路径点与列表条目。
//
// ⚠️ **刻意不写死点数/条数**：上游每几小时向路径追加新点（实测同一批台风
//    总点数数小时内从 89 漂到 91），写死必然过期、且「实测」二字会更假。
//    下文「实测 N/N」一律指**该次样本内逐点成立**，不是全局计数。
//  ═══════════════════════════════════════════════════════════════════════
//
//  ── 本文件的三条核心纪律 ────────────────────────────────────────────
//  ① **按类型取值，绝不按固定下标强解**（上游可能改字段顺序）：
//     每个字段都走 `JSONValue` 的 `intValue` / `doubleValue` /
//     `stringValue` / `arrayValue`，取不到就是 nil，**不猜、不填占位**。
//  ② **单字段失败不拖垮整批**：一个路径点坏 → 只丢该点（并计数）；
//     一个台风条目坏 → 只丢该条。绝不让整包变成空。
//  ③ **经度在前**：见本文件 `resolveLongitudeLatitude` 的取值域兜底 ——
//     这是「写反了会镜像到地球另一侧且不报错」的唯一自证点。
//
//  ── 实测与设计稿冲突之处（**以本文件实测为准**）────────────────────
//  · `view_` 的 JSONP 是**单层**（设计稿说双层）；
//  · `view_` 顶层数组长 **10**（设计稿说 8）；
//  · 路径点下标 10 在**全部**样本点上都是**数组**
//    （设计稿说末点是字符串 `"list"` → 本 worker 实测该字符串出现 **0** 次）；
//  · 列表端点下标 3/4 在 **32/32** 条上都是 **String**
//    （设计稿说 2026 年是 Int），而 `view_` 端点同字段是 Int。
//
//  Core 纪律：仅 import Foundation；纯函数；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 台风网 DTO → 领域模型映射器（纯函数）。
enum NmcTyphoonMapper {

    // MARK: - 实测下标常量（集中声明，避免散落魔数）

    /// 列表条目 / 详情头部的下标（实测两处同构）。
    enum HeadIndex {
        static let id = 0            // Int typhoonId
        static let englishName = 1   // String
        static let chineseName = 2   // String 或 null（早年台风实测 null）
        static let numberPrimary = 3 // String（list_）/ Int（view_）→ 一律转文本
        static let numberSecondary = 4 // 同上；实测 list_2024 早期条目为 ""
        static let internalSequence = 5  // Int 或 null（实测 9 Int / 23 null）
        static let namingMeaning = 6     // String 或 null
        static let status = 7            // "start" / "stop"
        /// 头部**最少**需要的元素数（实测恒 ≥ 8）。
        static let minimumCount = 8
    }

    /// 路径点下标（实测**定长 13**，全部样本点成立）。
    enum PointIndex {
        static let pointID = 0        // Int
        static let utcString = 1      // String "yyyyMMddHHmm"（UTC）
        static let epochMilliseconds = 2 // Int
        static let intensity = 3      // String
        static let longitude = 4      // 🔴 经度（**在前**）
        static let latitude = 5       // 🔴 纬度（在后）
        static let pressure = 6       // Int hPa
        static let maxWind = 7        // Int m/s
        static let motion = 8         // String（16 方位 / "no"）
        static let motionSpeed = 9    // Int km/h
        static let windCircles = 10   // Array（实测历史台风为空数组 []）
        static let forecast = 11      // Object（历史台风为 null）
        static let issueTime = 12     // Array（历史台风为 null）
        /// 路径点**最少**需要的元素数（实测恒 13）。
        static let minimumCount = 13
    }

    /// 预报字典里我们认识的机构键（实测恒为 `"BABJ"` = 中央气象台）。
    static let babjAgencyKey = "BABJ"

    /// 预报数组元素下标（实测**定长 8**）。
    enum ForecastIndex {
        static let leadHours = 0      // Int
        static let baseTimeUTC = 1   // String "yyyyMMddHHmm"
        static let longitude = 2     // 🔴 经度（**在前**，已用 JMA 交叉验证）
        static let latitude = 3      // 🔴 纬度（在后）
        static let pressure = 4      // Int hPa
        static let maxWind = 5       // Int m/s
        static let agency = 6        // String
        static let intensity = 7     // String
        static let minimumCount = 8
    }

    /// 风圈元素下标（实测**定长 6**：`["30KTS",380,250,250,380,3351798]`）。
    enum WindCircleIndex {
        static let label = 0
        static let firstRadius = 1   // 之后连续 4 个半径（1…4）
        static let radiusCount = 4
        static let pointID = 5
        static let minimumCount = 6
    }

    // MARK: - 列表端点

    /// 映射台风列表。
    ///
    /// - Parameter response: 已剥壳并解码的响应。
    /// - Returns: 摘要数组（保持上游顺序；空数组 = 「取到了但确实没有」）。
    static func summaries(from response: NmcTyphoonResponse) -> [TyphoonSummary] {
        guard let list = response.typhoonList else { return [] }
        return list.compactMap { entry in
            // ⚠️ `compactMap` 只解**一层** Optional；`entry` 是**非可选**
            // `JSONValue`（数组元素类型已是无Optional），故直接用即可。
            mapSummary(from: entry)
        }
    }

    /// 只保留进行中的台风（实测下标 7 == `"start"`；`list_default` 32 条里3 条）。
    ///
    /// - Parameter summaries: 全部摘要。
    /// - Returns: 进行中的那些（**空数组是合法业务结果**：实测 `list_1950` /
    ///   `list_1999` / `list_2024` 各28–42 条**全部是 `"stop"`**）。
    static func activeOnly(_ summaries: [TyphoonSummary]) -> [TyphoonSummary] {
        summaries.filter(\.isActive)
    }

    /// 单条列表条目 → 摘要（任一必需字段缺失 → nil，**只丢这一条**）。
    static func mapSummary(from entry: JSONValue) -> TyphoonSummary? {
        guard let row = entry.arrayValue, row.count >= HeadIndex.minimumCount else {
            return nil
        }
        // 🔴 必需字段：没有 id 无法拼 `view_<id>` URL → 该条**不可用**，
        // 如实丢弃（而不是造一个假 id 去请求）。
        guard let idValue = row[HeadIndex.id].stringValue, !idValue.isEmpty else {
            return nil
        }
        // 编号：下标 3 优先，缺失/为空回退下标 4。
        // ⚠️ 实测两个下标的**类型在不同端点不同**（list_ 是 String、view_ 是 Int），
        // 且 list_2024 早期条目下标 4 实测是**空串** → 故两者都要过trim + 非空判断。
        let number = firstNonEmptyText(row, HeadIndex.numberPrimary, HeadIndex.numberSecondary)
        return TyphoonSummary(
            id: idValue,
            englishName: row[HeadIndex.englishName].stringValue?.trimmedOrNil,
            // ⚠️ 实测中文名**可能带尾随换行**（如 `"小熊\n"`），故必须 trim；
            // 且早年台风（1950/1999/2024 部分条目）实测为 **null** → nil。
            chineseName: row[HeadIndex.chineseName].stringValue?.trimmedOrNil,
            number: number,
            namingMeaning: row[HeadIndex.namingMeaning].stringValue?.trimmedOrNil,
            // 状态：实测只有 "start" / "stop"。**未知状态按非活跃处理**
            // （宁可少显示一个活跃台风，也不要谎报"正在影响我国"）。
            isActive: row[HeadIndex.status].stringValue == "start")
    }

    // MARK: - 详情端点

    /// 映射单个台风的完整路径。
    ///
    /// - Parameter response: 已剥壳并解码的响应。
    /// - Returns: 台风详情；结构不符 → nil（调用方据此显示「详情取不到」）。
    static func track(from response: NmcTyphoonResponse) -> TyphoonTrack? {
        guard let top = response.typhoon, top.count >= HeadIndex.minimumCount else {
            return nil
        }
        // 头部按**与列表端点同构**的方式解析（实测 0–7 完全一致）。
        // ⚠️ 但这里**不强制 isActive**：详情页允许查看已停止台风的完整路径
        // （实测列表里有 29 条 `"stop"`，用户点进去就该看到路径）。
        guard let summary = mapSummary(from: .array(top)) else { return nil }
        // 路径点数组实测在下标 8；下标 9 是关联台风索引表（本 App 不使用）。
        let rawPoints = top.count > TrackIndex.points ? (top[TrackIndex.points].arrayValue ?? []) : []
        let points = mapPoints(rawPoints)
        // ⚠️ **实测历史台风（布拉万3227033）下标 9 实测为 `null`**，
        // 故下标 9 既可能是数组也可能是 null —— 我们不使用它，故无需解析。
        return TyphoonTrack(id: summary.id, summary: summary, points: points)
    }

    /// 详情端点顶层数组里，**路径点数组**所在下标。
    ///
    /// ⚠️ **实测顶层数组长 10**（设计稿说 8）：0–7 头部、**8 路径点**、
    /// 9 关联台风索引表（实测活跃台风为数组、历史台风布拉万为 `null`）。
    enum TrackIndex {
        static let points = 8
        /// 下标 9 是「同期其他台风在本响应内的路径点下标映射表」。
        ///
        /// 实测诺洛形态：`[[3346033, {"0":[0], "1":[1], …}], [3341981, …]]`
        /// 本App **不使用**（无消费者就不建模，本仓既有纪律）。
        static let relatedIndexMap = 9
    }

    /// 路径点数组 → 点数组（**逐点独立解析**，坏点只丢自己）。
    static func mapPoints(_ raw: [JSONValue]) -> [TyphoonTrackPoint] {
        var result: [TyphoonTrackPoint] = []
        result.reserveCapacity(raw.count)
        for entry in raw {
            if let point = mapPoint(from: entry) {
                result.append(point)
            }
        }
        // 实测上游本就按时间严格递增（逐点成立）；此处仍**显式排序**
        // 以防上游乱序 —— 路径线画在乱序点上是折返的 nonsense 图形。
        // ⚠️ 用带 offset 的稳定排序：无时刻的点恒排末尾，同刻点保上游相对顺序。
        let indexed = result.enumerated()
        return indexed.sorted { lhs, rhs in
            switch (lhs.element.time, rhs.element.time) {
            case let (left?, right?):
                if left == right { return lhs.offset < rhs.offset }
                return left < right
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// 单个路径点（定长 13；**缺经纬或缺时刻的点直接丢弃**）。
    ///
    /// ⚠️ 为什么丢点而不是保留「半个点」：地图上**没有坐标的点画不出来**，
    /// 保留它只会让「已解析点数」虚高。用户看到的是路径线，线画不出就等于无。
    static func mapPoint(from entry: JSONValue) -> TyphoonTrackPoint? {
        guard let row = entry.arrayValue, row.count >= PointIndex.minimumCount else {
            return nil
        }
        // 🔴 经纬：必须成对拿到，且经度在前（见 resolveLongitudeLatitude）。
        guard let coordinates = resolveLongitudeLatitude(row) else { return nil }
        return TyphoonTrackPoint(
            pointID: row[PointIndex.pointID].intValue,
            // 时刻：优先下标 2（Unix 毫秒，实测与下标 1 逐点自洽），
            // 缺失时降级用下标 1 的 UTC 串。
            time: resolveTime(row),
            intensity: row[PointIndex.intensity].stringValue
                .map { TyphoonIntensity(rawValue: $0) },
            longitude: coordinates.longitude,
            latitude: coordinates.latitude,
            pressureHPa: row[PointIndex.pressure].doubleValue,
            maxWindSpeedMS: row[PointIndex.maxWind].doubleValue,
            motion: row[PointIndex.motion].stringValue.map { TyphoonMotion(rawValue: $0) },
            motionSpeedKmh: row[PointIndex.motionSpeed].doubleValue,
            windCircles: mapWindCircles(row[PointIndex.windCircles]),
            forecast: mapForecast(row[PointIndex.forecast]),
            beijingTimeText: mapBeijingTimeText(row[PointIndex.issueTime]))
    }

    // MARK: - 经纬度（🔴 最易写反的一处）

    /// 从路径点行里取经纬度。
    ///
    /// ⚠️ **实测确认「经度在前」**，两条独立依据（详见 `Typhoon.swift` 头）：
    ///   ① 三个活跃台风**全部路径点**上，下标 4 落在经度带（实测约 144–180、逐点 > 90）、
    ///      下标 5 落在纬度带（实测约 10–40、无一点 > 90）—— 纬度不可能 > 90；
    ///   ② JMA（独立机构）同一台风同一时刻实测 `position.deg = [25.3, 162.4]`
    ///      （JMA 序 [纬,经]）与 NMC的 `162.6 / 25.4` 逐位吻合。
    ///
    /// 本函数**按该顺序取值**，并额外做一次**取值域兜底**：
    /// 若「下标4 落在 ±90 内（即像纬度）而 下标5 不落在（即不像纬度）」，
    /// 则判定上游**换了顺序**，此时**交换**二者。
    ///
    /// ⚠️ 为什么这个兜底**安全**：西北太平洋台风不可能落在 ±90 经度内，
    /// 而纬度**必然**在 ±90 内。故「一个像纬度、一个不像」这个组合只可能
    /// 意味着顺序反了。实测样本中**不会触发**（逐点都走正常分支），
    /// 它只为上游改顺序时**不镜像到地球另一侧**。
    static func resolveLongitudeLatitude(_ row: [JSONValue])
        -> (longitude: Double, latitude: Double)? {
        let fourth = row[PointIndex.longitude].doubleValue
        let fifth = row[PointIndex.latitude].doubleValue
        guard let a = fourth, let b = fifth else { return nil }

        let aLooksLikeLatitude = abs(a) <= 90
        let bLooksLikeLatitude = abs(b) <= 90
        // 正常：a 像经度、b 像纬度。
        if !aLooksLikeLatitude, bLooksLikeLatitude {
            return (a, b)
        }
        // 反序兜底：a 像纬度、b 像经度 → 交换。
        if aLooksLikeLatitude, !bLooksLikeLatitude {
            return (b, a)
        }
        // 两都像纬度（|a|,|b|都 ≤ 90，通常是赤道附近）或两都不像：
        // 无法用取值域裁定→ **按实测顺序**（经度在前）取值，不猜。
        return (a, b)
    }

    // MARK: - 时刻

    /// 路径点时刻：优先下标 2（Unix 毫秒），降级下标 1（UTC 串）。
    ///
    /// 实测依据：三个台风**全部路径点**，把下标 1 按 `yyyyMMddHHmm` 当UTC 解析
    /// 后取 epoch 秒 ×1000，与下标 2 **逐个比对全部相等（0 处不一致）**。
    /// → 两者等价，但**优先用下标 2**（免去字符串解析的时区坑）。
    static func resolveTime(_ row: [JSONValue]) -> Date? {
        if let millis = row[PointIndex.epochMilliseconds].intValue {
            return Date(timeIntervalSince1970: Double(millis) / 1000)
        }
        return row[PointIndex.utcString].stringValue.flatMap(parseUTCMinute(_:))
    }

    /// 预报起报时刻（下标 1，实测同为 UTC `yyyyMMddHHmm`）。
    static func parseUTCMinute(_ text: String) -> Date? {
        Self.utcMinuteFormatter.date(from: text)
    }

    /// UTC `yyyyMMddHHmm` 解析器（**固定 locale / 固定时区**，否则设备区域设置
    /// 会让非 Gregorian 日历或非公历数字解析整体失败）。
    ///
    /// ⚠️ 纪律：本仓 `Core/` **不读内部 `Date()`**（取数时刻由调用方注入）；
    /// 此处只做「给定文本 → 绝对时刻」的纯换算，UTC 由formatter 自带。
    private static let utcMinuteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmm"
        return formatter
    }()

    // MARK: - 风圈

    /// 风圈数组 → 领域模型（实测元素定长 6；**历史台风实测为空数组 `[]`**）。
    static func mapWindCircles(_ value: JSONValue) -> [TyphoonWindCircle] {
        guard let rows = value.arrayValue else { return [] }
        return rows.compactMap { entry in
            guard let row = entry.arrayValue, row.count >= WindCircleIndex.minimumCount else {
                return nil
            }
            guard let label = row[WindCircleIndex.label].stringValue else { return nil }
            // 4 个半径逐个按类型取（实测均为 Int；缺失的位**跳过而非补 0**，
            // 否则 `max()` 会把「缺测」当成「半径 0 km」画出一个假小圈）。
            var radii: [Double] = []
            radii.reserveCapacity(WindCircleIndex.radiusCount)
            for offset in 0..<WindCircleIndex.radiusCount {
                if let radius = row[WindCircleIndex.firstRadius + offset].doubleValue, radius >= 0 {
                    radii.append(radius)
                }
            }
            return TyphoonWindCircle(label: label,
                                    radii: radii,
                                    pointID: row[WindCircleIndex.pointID].intValue)
        }
    }

    // MARK: - 预报

    /// 预报字典 → 预报点数组（**只取 `BABJ`**，实测唯一机构键）。
    ///
    /// ⚠️ 实测历史台风（布拉万3227033）下标 11 为 **`null`**（26/26 点），
    /// 非数组 → 返回空数组（**如实缺测**，不编造预报）。
    static func mapForecast(_ value: JSONValue) -> [TyphoonForecastPoint] {
        guard let dict = value.objectValue,
              let agencyRows = dict[babjAgencyKey]?.arrayValue else {
            return []
        }
        return agencyRows.compactMap { entry in
            guard let row = entry.arrayValue, row.count >= ForecastIndex.minimumCount else {
                return nil
            }
            return TyphoonForecastPoint(
                // ⚠️ 时效**逐条可选**：实测彩云末点的预报只剩 `[12]`一个，
                // 而首点是 `[12,24,36,48,60,72,96,120]` 八个 → 不按固定下标计数。
                leadHours: row[ForecastIndex.leadHours].intValue,
                baseTime: row[ForecastIndex.baseTimeUTC].stringValue
                    .flatMap(parseUTCMinute(_:)),
                // 🔴 经度在前（已用 JMA 交叉验证，见resolveLongitudeLatitude 注释）。
                longitude: row[ForecastIndex.longitude].doubleValue,
                latitude: row[ForecastIndex.latitude].doubleValue,
                pressureHPa: row[ForecastIndex.pressure].doubleValue,
                maxWindSpeedMS: row[ForecastIndex.maxWind].doubleValue,
                agency: row[ForecastIndex.agency].stringValue,
                intensity: row[ForecastIndex.intensity].stringValue
                    .map { TyphoonIntensity(rawValue: $0) })
        }
    }

    // MARK: - 发布时间文本

    /// 北京时间发布文本（实测下标 12 的第 1 元素）。
    ///
    /// 实测形态：`["202610071400", "2026年10月07日14时00分", null, null]`
    /// → 只取第 1 元素；后两个实测恒为 `null`；第 0 元素实测恒等于
    /// 「下标 1（UTC）+8h」，故**只用于展示**、不参与时刻计算。
    static func mapBeijingTimeText(_ value: JSONValue) -> String? {
        guard let row = value.arrayValue, row.count >= 2 else { return nil }
        return row[1].stringValue?.trimmedOrNil
    }

    // MARK: - 小工具

    /// 依次尝试若干下标，返回**首个非空文本**（用于编号下标 3 → 4 的回退）。
    private static func firstNonEmptyText(_ row: [JSONValue], _ indices: Int...) -> String? {
        for index in indices where index < row.count {
            if let text = row[index].stringValue?.trimmedOrNil {
                return text
            }
        }
        return nil
    }
}

// MARK: - 字符串小工具

/// 去空白；结果为空串时返回 nil（**空串与「没有」必须区分**）。
extension String {
    /// trim 后为空 → nil。
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
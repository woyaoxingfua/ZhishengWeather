//
//  UsgsEarthquakeMapper.swift
//  Core / Networking  [App + Widget 共用]
//
//  第九源 DTO → 领域模型映射（**纯函数**）。
//
//  ── 🔴 判「附近有没有地震」的唯一依据是 `features`，**不是 `metadata.count`** ──
//  实测踩过的坑：`metadata` 里**加了 `limit` 之后就不再返回 `count` 字段**
//  （改为返回 `limit` / `offset`）。故：
//  · `features` 为 **nil**（键整个缺失）→ `.empty`；
//  · `features` 为 **空数组** → `.empty`（实测北京 300km/30 天/M2.5+ 就是 0 条，
//    主理人已确认**真的没地震**）——**这是合法业务结果，不是故障**；
//  · 有条目但**每条都缺经纬/ 缺时刻**（全被丢弃）→ `.empty`
//    （此时确实是「本应用取不到可展示的内容」，但**不是**网络故障；
//    模型层据此显示 `.none` 而 `.unavailable`——见 `EarthquakeCardModel`）。
//
//  ── 一条坏 feature **只丢自己**（不拖垮整批）────────────────────────
//  USGS 的feature 是**独立对象**，一条缺 `geometry` 不该让另外 19 条陪葬。
//  故 mapper 逐条 `compactMap`，坏条目静默丢弃。
//  ⚠️ 但**必填三项**（时刻 / 经度 / 纬度）缺任一即丢该条 ——
//  没有它们这条地震**画不出来也定位不了**，硬保留只会渲染出「(null) 附近有震」。
//
//  ── ⚠️ 排序：**按距离升序**（不是端点的 `orderby=time`）─────────────
//  端点侧请求的是 `orderby=time`（时间倒序），它决定的是「**取哪20 条**」；
//  而本卡片的主题是「**附近**有感地震」—— 用户问的是「离我最近的那一次」。
//  故这里**重排为距离升序**。同距离时以**时刻倒序**为次序（新的在前），
//  保证渲染顺序**稳定可复现**（否则 SwiftUI 列表会在两次刷新间跳序）。
//
//  ── 🔴 坐标序：**经度在前**（GeoJSON 规范）────────────────────────
//  实测 `geometry.coordinates = [120.5395, -7.7761, 10]`
//  = `[经度, 纬度, 深度]`。本mapper **按下标 0=经度 / 1=纬度 / 2=深度** 取，
//  并做**取值域兜底**：若「经度」落在 ±90 内而「纬度」落在 ±90 外，
//  判定为上游顺序异常并**交换回来**（宁可不镜像，也不镜像）——与
//  `NmcTyphoonMapper.resolveLongitudeLatitude` 同款纪律。
//
//  ── 时刻：**Unix 毫秒** ────────────────────────────────────────────────
//  实测 `properties.time = 1791434939943`（13 位 = 毫秒）。
//  ⚠️ 与本仓其它源的 epoch **秒** 不同，**差 1000 倍**；
//  写错会让 2026 年的地震显示成 1970 年 + 约 5.6 万年 —— 且**不报错**。
//  故除以 1000 后再构造 `Date`，并由单测逐字锚定。
//
//  ── `tsunami` 是 **0/1 整数**不是布尔 ─────────────────────────────────
//  实测逐字 `"tsunami": 0`。用 `Int?` 收；非 0 → true，nil / 其它 → **false**
//  （**不是**「未知」—— 海啸标志本身没有第三态；上游没给就按「无」处理，
//  但**绝不**把它渲染成「有海啸风险」）。
//
//  ── `felt` 是**上报人数**，不是烈度 ─────────────────────────────────
//  实测 `felt = null` 是常态（没人主动上报有感）。
//  **绝不**把它当成烈度或震感强度展示—— 页脚会如实说明。
//
//  Core 纪律：仅 import Foundation；纯函数；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 第九源 DTO → 地震领域模型映射器（纯函数）。
enum UsgsEarthquakeMapper {

    /// 映射。
    ///
    /// - Parameters:
    ///   - response: 解码后的 DTO（`features` 可能为 nil / 空数组）。
    ///   - originLatitude: 观测点纬度（**注入**：用于算距离，Core 内不查城市）。
    ///   - originLongitude: 观测点经度（注入）。
    /// - Returns: 地震领域模型；无任何可展示事件 → `isEffectivelyEmpty == true`
    ///   （UI 显示「附近没有地震」，**不是**「取不到」）。
    static func map(_ response: UsgsEarthquakeResponse,
                    originLatitude: Double,
                    originLongitude: Double) -> EarthquakeFeed {
        // ⚠️ **不查 `metadata.count`**：实测加了 `limit` 之后该字段就没了（见文件头）。
        guard let features = response.features, !features.isEmpty else {
            return .empty
        }

        var events: [EarthquakeEvent] = []
        events.reserveCapacity(features.count)

        for feature in features {
            // 一条坏 feature 只丢自己（compactMap 逐条判空，绝不整批清空）。
            guard let event = event(from: feature,
                                    originLatitude: originLatitude,
                                    originLongitude: originLongitude) else { continue }
            events.append(event)
        }

        return EarthquakeFeed(events: sortedByDistance(events))
    }

    // MARK: - 单条

    /// 单条 feature → 领域模型；缺必填项 → nil（丢弃该条）。
    private static func event(from feature: UsgsEarthquakeResponse.Feature,
                              originLatitude: Double,
                              originLongitude: Double) -> EarthquakeEvent? {
        // 时刻（Unix 毫秒 → 秒）：缺则丢该条（无时刻无法定位，绝不编造时间）。
        guard let properties = feature.properties,
              let epochMilliseconds = properties.time,
              epochMilliseconds.isFinite else { return nil }
        let epochSeconds = epochMilliseconds / 1000
        // 合理性守卫：epoch 必须是**正数**（1970 之前 / 负值都是上游异常）。
        // ⚠️ 不是防御性洁癖：实测 `time` 单位若被误当秒（少除1000），
        // 会得到 1970 年附近的时刻 —— 那是「量纲写错」的典型症状，必须挡住。
        guard epochSeconds > 0 else { return nil }

        // 坐标：`[经度, 纬度, 深度]`（经度在前）。
        guard let coordinates = feature.geometry?.coordinates,
              coordinates.count >= 2 else { return nil }
        guard let resolved = resolveCoordinates(coordinates) else { return nil }

        // 距观测点（本App 计算，上游不提供；算不出 → 丢该条，
        // 因为「附近」这张卡片的每一条都必须能说清「离你多远」）。
        guard let distanceKm = GeoDistance.kilometers(originLatitude: originLatitude,
                                                      originLongitude: originLongitude,
                                                      targetLatitude: resolved.latitude,
                                                      targetLongitude: resolved.longitude) else {
            return nil
        }

        return EarthquakeEvent(
            id: identifier(of: feature, epochSeconds: epochSeconds, resolved: resolved),
            magnitude: finiteOrNil(properties.mag),
            magnitudeType: trimmed(properties.magType),
            placeDescription: trimmed(properties.place),
            time: Date(timeIntervalSince1970: epochSeconds),
            longitude: resolved.longitude,
            latitude: resolved.latitude,
            depthKm: depthValue(from: coordinates),
            feltReportCount: feltCount(from: properties.felt),
            pagerAlert: pagerAlert(from: properties.alert),
            hasTsunamiFlag: (properties.tsunami ?? 0) != 0,
            detailURLString: trimmed(properties.url),
            distanceKm: distanceKm
        )
    }

    // MARK: - 坐标（🔴 经度在前 + 取值域兜底）

    /// 解析出的坐标对。
    private struct ResolvedCoordinate {
        let longitude: Double
        let latitude: Double
    }

    /// `coordinates` → (经度, 纬度)，带**取值域兜底**。
    ///
    /// ⚠️ 兜底逻辑：GeoJSON 规范是 `[经, 纬]`。若实测拿到
    /// 「下标 0 落在 ±90 内（像纬度）而下标 1 落在 ±90 外（像经度）」，
    /// 说明上游顺序异常 → **交换回来**。
    /// **理由**：宁可不镜像，也不镜像（与 `NmcTyphoonMapper` 同款纪律）——
    /// 但**只**在「形态明确可判」时才交换（必须是**恰好一个**落在 ±90 内），
    /// 否则不猜（宁可丢这条，也不给出一个可能镜像的坐标）。
    private static func resolveCoordinates(_ coordinates: [Double]) -> ResolvedCoordinate? {
        let first = coordinates[0]
        let second = coordinates[1]
        guard first.isFinite, second.isFinite else { return nil }

        let firstInLatitudeRange = (first >= -90 && first <= 90)
        let secondInLatitudeRange = (second >= -90 && second <= 90)

        // 正常形态：下标 0 = 经度（可超 ±90）、下标 1 = 纬度（必在 ±90 内）。
        if secondInLatitudeRange && !firstInLatitudeRange {
            return ResolvedCoordinate(longitude: first, latitude: second)
        }
        // 反序形态：恰好一个落在 ±90 内且在下标 0 → 交换（仅此一种可判定的情况）。
        if firstInLatitudeRange && !secondInLatitudeRange {
            return ResolvedCoordinate(longitude: second, latitude: first)
        }
        // ⚠️ 两个都像纬度（如 [10, 20]）或都不像（如 [200, 300]）→
        // **形态不可判** → 不猜，丢这条（渲染一个可能镜像的坐标比不渲染更糟）。
        guard firstInLatitudeRange, secondInLatitudeRange else { return nil }
        return ResolvedCoordinate(longitude: first, latitude: second)
    }

    /// 深度（`coordinates[2]`）；数组长度不足 3 / 非有限值 → nil。
    ///
    /// ⚠️ **深度可能为负**（部分海域事件由海平面以下起始？—— 这一点
    /// **无法确定**，上游未见负值样本）。故此处**不做 `>= 0` 拒绝**，
    /// 只挡非有限值 —— 免得把一个合法但少见的样本误丢。
    /// 页脚会如实说明「深度为 USGS 给出的震源深度」。
    private static func depthValue(from coordinates: [Double]) -> Double? {
        // ⚠️ 长度检查：常量是 2（经纬），深度在下标 2 → 需长度 ≥ 3。
        let depthIndex = 2
        guard coordinates.count > depthIndex else { return nil }
        return finiteOrNil(coordinates[depthIndex])
    }

    // MARK: - 字段小工具

    /// 事件 id：优先用上游 `id`；缺失时用「时刻 + 坐标」构造**确定性兜底**。
    ///
    /// ⚠️ **不因id 缺失而丢弃这条真实地震**（那会让一次真实事件凭空消失）；
    /// 兜底 id 由**事件自身的内容**决定 → 同一事件两次查询得到同一个 id
    /// （`Identifiable` 的稳定性要求）。
    private static func identifier(of feature: UsgsEarthquakeResponse.Feature,
                                   epochSeconds: Double,
                                   resolved: ResolvedCoordinate) -> String {
        if let raw = trimmed(feature.id), !raw.isEmpty { return raw }
        let secondsText = String(Int(epochSeconds))
        return "usgs-\(secondsText)-\(String(format: "%.3f", resolved.longitude))"
            + "-\(String(format: "%.3f", resolved.latitude))"
    }

    /// 有感上报数（实测 `null` 是常态）；负数 / 非有限 → nil。
    ///
    /// ⚠️ 上游给的是 `Double`（实测可能带小数），展示时四舍五入成人数。
    private static func feltCount(from raw: Double?) -> Int? {
        guard let value = finiteOrNil(raw), value >= 0 else { return nil }
        return Int(value.rounded())
    }

    /// PAGER 警报等级（实测 `null` 是常态）；空串 → nil。
    private static func pagerAlert(from raw: String?) -> EarthquakePagerAlert? {
        guard let text = trimmed(raw) else { return nil }
        return EarthquakePagerAlert(rawValue: text)
    }

    /// 非有限值 → nil（`NaN` / `±inf` 一律当缺测，**绝不**透传到 UI）。
    private static func finiteOrNil(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    /// 去首尾空白；空串 → nil（**上游实测存在尾随换行**的先例：台风中文名）。
    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - 排序

    /// **按距离升序**；同距离时按**时刻倒序**（新的在前）。
    ///
    /// ⚠️ **不用 `sorted(by:)` 里的 `$0` / `$1`**（本仓已踩过遮蔽类问题的近亲：
    /// 谓词里写复杂比较不易读）。这里显式取两个局部常量再比较。
    ///
    /// - 稳定性：同距离同刻时保持**输入顺序** → 两次刷新顺序一致，列表不跳。
    static func sortedByDistance(_ events: [EarthquakeEvent]) -> [EarthquakeEvent] {
        events.sorted { left, right in
            if left.distanceKm != right.distanceKm {
                return left.distanceKm < right.distanceKm
            }
            return left.time > right.time
        }
    }
}
//
//  WeatherSpotlight.swift
//  Core / Logic  [App + Widget 共用]
//
//  iOS 系统级集成的**纯数据与纯组装**层：
//   ① Spotlight 搜索条目的唯一标识 / 标题 / 描述 / 关键词（不 import CoreSpotlight）；
//   ② Handoff & Siri 建议用的 NSUserActivity 常量与 userInfo 载荷（纯字典读写）。
//
//  为什么把「组装」放在 Core 而把「写入」放在 App 侧：
//  - 描述文案里有没有温度、有没有天气现象，是**诚实性判据**（无快照绝不编造），
//    这类判据必须能被单测直接断言；把它埋进 CSSearchableItem 的构造过程里就测不到。
//  - CoreSpotlight 是 App target 专属依赖（Widget 不可用），故本文件只产出
//    值类型 `WeatherSpotlightItem`，由 App 侧的 `SpotlightIndexer` 转成
//    `CSSearchableItem`（同 AppIconSwitcher 的「纯逻辑在 Core、副作用在 App」分层）。
//
//  硬纪律（本轮的红线）：
//  - **无快照的城市，描述里绝不出现温度 / 天气现象**：不写 0℃、不写「未知」冒充，
//    只写「查看天气」这类静态文案。索引是增强能力，**不是数据源**，宁可少写
//    也不能让系统搜索结果出现编造的数字（`WeatherSpotlightBuilderTests` 红卫）。
//  - **uniqueIdentifier 必须稳定**：同一城市每次生成完全相同，否则系统索引会
//    把同一城市堆成多条，且无法按 identifier 增量删除。
//
//  userInfo 键类型说明：`NSUserActivity.userInfo` 的声明类型是 `[AnyHashable: Any]?`，
//  故本文件两个 userInfo 函数**同型**使用它，避免在 App 侧依赖字典的隐式上转
//  （Swift 的字典键/值上转不是所有版本都放行，显式同型最稳）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//  （NSUserActivity 属 Foundation，本文件只读写其 userInfo 字典，不构造活动对象。）
//

import Foundation

// MARK: - 搜索条目（值类型）

/// 一条待写入系统索引的城市条目（纯数据）。
struct WeatherSpotlightItem: Equatable, Sendable {

    /// 系统索引内的唯一标识（稳定：`域前缀.城市id`）。
    let uniqueIdentifier: String
    /// 搜索结果主标题（城市名）。
    let title: String
    /// 搜索结果副标题。**可空**：无快照时只给静态文案（详见类型文档）。
    let contentDescription: String?
    /// 关键词（城市名 + 所属行政区 + 通用词），提升搜索命中率。
    let keywords: [String]
    /// 该条目对应的城市 id（深链跳转用；回程解析不经字符串切分）。
    let cityID: String
}

// MARK: - 常量与载荷（Handoff / Siri 建议）

/// Spotlight 与 Handoff 共用的常量与纯函数。
enum WeatherSpotlight {

    /// NSUserActivity 类型（Handoff / Siri 建议）。
    ///
    /// ⚠️ 同步纪律：必须与 `Config/ZhishengWeather-Info.plist` 的
    /// `NSUserActivityTypes` 数组中的字符串**逐字一致**，否则系统不会
    /// 把本活动派发给本 App（表现为 Handoff 图标不出现、建议不出现）。
    static let activityType: String = "com.zhisheng.weather.viewCity"

    /// 索引域标识（`CSSearchableItem.domainIdentifier`，按域整体删除用）。
    ///
    /// 同时是条目唯一标识的前缀；**不含** App Group 字符串（与共享容器无关）。
    static let domainIdentifier: String = "com.zhisheng.weather.city"

    /// userInfo 里城市 id 的键。
    private static let cityIDKey: String = "com.zhisheng.weather.cityID"

    // MARK: - 唯一标识

    /// 条目的唯一标识（`域前缀.城市id`）。
    ///
    /// 稳定性来源：只由 cityID 派生，不含温度 / 时间等易变值 —— 同一城市
    /// 每次生成相同，系统索引按同 identifier 覆盖更新而不是堆条。
    /// - Parameter cityID: 城市 id。
    /// - Returns: 形如 "com.zhisheng.weather.city.39.90,116.41" 的标识。
    static func uniqueIdentifier(cityID: String) -> String {
        "\(domainIdentifier).\(cityID)"
    }

    /// 从唯一标识反解城市 id（点开搜索结果时用）。
    ///
    /// - Parameter uniqueIdentifier: 系统回传的 identifier。
    /// - Returns: 城市 id；前缀不匹配 / id 段为空 → nil（绝不返回半个字符串）。
    static func cityID(fromUniqueIdentifier uniqueIdentifier: String) -> String? {
        let prefix: String = "\(domainIdentifier)."
        guard uniqueIdentifier.hasPrefix(prefix) else { return nil }
        let cityID: String = String(uniqueIdentifier.dropFirst(prefix.count))
        return cityID.isEmpty ? nil : cityID
    }

    // MARK: - 活动载荷

    /// 活动标题（"杭州天气"）。
    /// - Parameter cityName: 城市展示名。
    /// - Returns: 标题文案。
    static func activityTitle(cityName: String) -> String {
        "\(cityName)天气"
    }

    /// NSUserActivity 的 userInfo 载荷（只放属性列表类型：String）。
    /// - Parameter cityID: 城市 id。
    /// - Returns: 可直接赋给 `NSUserActivity.userInfo` 的字典。
    static func userInfo(cityID: String) -> [AnyHashable: Any] {
        [cityIDKey: cityID]
    }

    /// 从 userInfo 反解城市 id（Handoff 接续时用）。
    ///
    /// - Parameter userInfo: `NSUserActivity.userInfo`（可为 nil）。
    /// - Returns: 城市 id；缺失 / 类型不是 String → nil（绝不尝试强转后崩）。
    static func cityID(fromUserInfo userInfo: [AnyHashable: Any]?) -> String? {
        guard let value = userInfo?[cityIDKey] else { return nil }
        return value as? String
    }
}

// MARK: - 条目组装

/// 把「城市列表 + 已知快照」组装成待索引条目（纯函数，可单测）。
enum WeatherSpotlightBuilder {

    /// 无快照时使用的静态描述。
    ///
    /// 为什么不是 nil、也不是「未知」：系统搜索结果的副标题为空白时用户
    /// 无法判断这条是什么；而写「未知 / -- / 0℃」是在**用文案冒充数据**
    /// （本仓反复出现的 P-18 同源盲区）。静态文案只陈述「可做的事」，不陈述数值。
    static let placeholderDescription: String = "查看天气"

    /// 组装全部城市的索引条目。
    ///
    /// - Parameters:
    ///   - cities: 城市列表（顺序不影响索引结果）。
    ///   - snapshotByCityID: 城市 id → 最近一次成功取到的快照（**只认成功的
    ///     数据**；无对应快照的城市按「无数据」处理）。
    /// - Returns: 与 `cities` 一一对应的条目数组。
    static func items(cities: [City],
                      snapshotByCityID: [String: WeatherSnapshot]) -> [WeatherSpotlightItem] {
        cities.map { city in
            item(city: city, snapshot: snapshotByCityID[city.id])
        }
    }

    /// 组装单条。
    ///
    /// - Parameters:
    ///   - city: 城市。
    ///   - snapshot: 该城市最近一次成功快照；nil = 本次会话还没取到数据。
    /// - Returns: 索引条目。
    static func item(city: City, snapshot: WeatherSnapshot?) -> WeatherSpotlightItem {
        var keywords: [String] = [city.name]
        if let admin1: String = city.admin1, !admin1.isEmpty {
            keywords.append(admin1)
        }
        keywords.append("天气")

        let description: String?
        if let snapshot {
            // 有真实数据才写数值：温度按**摄氏度**显式带单位符号 —— 索引在
            // 系统搜索框里展示，读不到 App 内的单位偏好，省略符号会让 "20"
            // 与华氏混淆；宁可多一个符号，也不给一个有歧义的数字。
            let temperature: String = "\(Int(snapshot.temperature.rounded()))°C"
            description = "\(temperature) · \(WMOCodeMapper.description(for: snapshot.weatherCode))"
        } else {
            description = placeholderDescription
        }

        return WeatherSpotlightItem(
            uniqueIdentifier: WeatherSpotlight.uniqueIdentifier(cityID: city.id),
            title: city.name,
            contentDescription: description,
            keywords: keywords,
            cityID: city.id
        )
    }
}

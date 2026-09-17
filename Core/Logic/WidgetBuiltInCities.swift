//
//  WidgetBuiltInCities.swift
//  Core / Logic  [App + Widget 共用]
//
//  城市阶梯 **C1**：小组件内置城市目录（Swift 常量数组，**不用 plist**）。
//
//  为什么需要（ARCH §1.3 / 决策 #3）：App Group 容器在本产品分发渠道上永久为空
//  → 小组件配置界面的候选只剩哨兵（一个真实城市都没有）→ 用户**无法主动选择**
//  任何城市 → 自力取数（L1）永远没有目标坐标。C1 保证选择器**永不为空**。
//
//  形态裁定：**Swift 常量数组**而非 plist。理由：plist 要跨两个 target 配资源、
//  且**解析失败是运行期静默**（正是本项目反复出现的 P-18 同源盲区）；Swift 常量是
//  **编译期检查**、零资源配置、`@testable import` 直接可测。
//
//  纪律：
//  - 首项**复用** `City.beijingDefault`（满足「复用 `LocationInfo.beijing`、
//    不引入第二套默认坐标」）；其余显式构造，坐标取自公开 WGS84 城市中心点。
//  - 全部 id 由 `City.makeID`（"%.2f,%.2f"）生成，**互不重复**且**无一等于
//    `WidgetCityResolver.followAppID`**（§12.1 测试兜底）。
//  - C1 **不是**替用户默认城市：它只让用户在小部件配置界面**主动选到**真实城市
//    （决策 #4：绝不静默替换成别的城市）。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 小组件内置城市目录（4 直辖市 + 27 省会/自治区首府 + 3 港澳台 = 34 座）。
enum WidgetBuiltInCities {

    /// 内置城市（顺序即配置界面展示顺序）。
    ///
    /// 数量与内容见 ARCH §7.3 表（逐条列出，禁止臆造坐标）；首项为共享容器
    /// 不可用时的**唯一**默认坐标真源 `City.beijingDefault`。
    static let cities: [City] = [
        City.beijingDefault,
        make("上海", 31.23, 121.47, admin1: "上海", timeZone: "Asia/Shanghai"),
        make("天津", 39.13, 117.20, admin1: "天津", timeZone: "Asia/Shanghai"),
        make("重庆", 29.56, 106.55, admin1: "重庆", timeZone: "Asia/Shanghai"),
        make("石家庄", 38.04, 114.51, admin1: "河北", timeZone: "Asia/Shanghai"),
        make("太原", 37.87, 112.55, admin1: "山西", timeZone: "Asia/Shanghai"),
        make("呼和浩特", 40.84, 111.75, admin1: "内蒙古", timeZone: "Asia/Shanghai"),
        make("沈阳", 41.80, 123.43, admin1: "辽宁", timeZone: "Asia/Shanghai"),
        make("长春", 43.82, 125.32, admin1: "吉林", timeZone: "Asia/Shanghai"),
        make("哈尔滨", 45.80, 126.53, admin1: "黑龙江", timeZone: "Asia/Shanghai"),
        make("南京", 32.06, 118.80, admin1: "江苏", timeZone: "Asia/Shanghai"),
        make("杭州", 30.25, 120.17, admin1: "浙江", timeZone: "Asia/Shanghai"),
        make("合肥", 31.82, 117.23, admin1: "安徽", timeZone: "Asia/Shanghai"),
        make("福州", 26.07, 119.30, admin1: "福建", timeZone: "Asia/Shanghai"),
        make("南昌", 28.68, 115.86, admin1: "江西", timeZone: "Asia/Shanghai"),
        make("济南", 36.65, 117.12, admin1: "山东", timeZone: "Asia/Shanghai"),
        make("郑州", 34.75, 113.63, admin1: "河南", timeZone: "Asia/Shanghai"),
        make("武汉", 30.59, 114.31, admin1: "湖北", timeZone: "Asia/Shanghai"),
        make("长沙", 28.23, 112.94, admin1: "湖南", timeZone: "Asia/Shanghai"),
        make("广州", 23.13, 113.26, admin1: "广东", timeZone: "Asia/Shanghai"),
        make("南宁", 22.82, 108.32, admin1: "广西", timeZone: "Asia/Shanghai"),
        make("海口", 20.04, 110.32, admin1: "海南", timeZone: "Asia/Shanghai"),
        make("成都", 30.57, 104.07, admin1: "四川", timeZone: "Asia/Shanghai"),
        make("贵阳", 26.65, 106.63, admin1: "贵州", timeZone: "Asia/Shanghai"),
        make("昆明", 25.04, 102.71, admin1: "云南", timeZone: "Asia/Shanghai"),
        make("拉萨", 29.65, 91.14, admin1: "西藏", timeZone: "Asia/Shanghai"),
        make("西安", 34.34, 108.94, admin1: "陕西", timeZone: "Asia/Shanghai"),
        make("兰州", 36.06, 103.83, admin1: "甘肃", timeZone: "Asia/Shanghai"),
        make("西宁", 36.62, 101.78, admin1: "青海", timeZone: "Asia/Shanghai"),
        make("银川", 38.49, 106.23, admin1: "宁夏", timeZone: "Asia/Shanghai"),
        make("乌鲁木齐", 43.83, 87.62, admin1: "新疆", timeZone: "Asia/Shanghai"),
        make("香港", 22.32, 114.17, admin1: "香港特别行政区", timeZone: "Asia/Hong_Kong"),
        make("澳门", 22.20, 113.54, admin1: "澳门特别行政区", timeZone: "Asia/Macau"),
        make("台北", 25.03, 121.57, admin1: "台湾省", timeZone: "Asia/Taipei"),
    ]

    /// 构造一条内置城市（country 恒为「中国」；`isCurrentLocation` 恒 false）。
    ///
    /// 私有单点构造，避免 33 处重复「country / isCurrentLocation」而写错。
    /// - Parameters:
    ///   - name: 展示名。
    ///   - latitude: 纬度（WGS84，保留 2 位小数以与 `City.makeID` 对齐）。
    ///   - longitude: 经度（同上）。
    ///   - admin1: 省级行政区名（配置界面去歧义副标题用）。
    ///   - timeZone: IANA 时区标识（D-4 时刻渲染用）。
    /// - Returns: 内置城市。
    private static func make(_ name: String,
                             _ latitude: Double,
                             _ longitude: Double,
                             admin1: String,
                             timeZone: String) -> City {
        City(name: name,
             latitude: latitude,
             longitude: longitude,
             isCurrentLocation: false,
             country: "中国",
             admin1: admin1,
             timeZoneIdentifier: timeZone)
    }
}

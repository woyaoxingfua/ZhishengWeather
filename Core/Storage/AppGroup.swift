//
//  AppGroup.swift
//  Core / Storage  [App + Widget 共用]
//
//  App Group ID 与所有共享 key 的**唯一真源**。
//  其他文件一律引用此处常量，禁止散落字符串字面量。
//

import Foundation

/// 共享容器常量。
enum AppGroup {
    /// App Group 标识（两个 target 的 entitlements 必须与此一致）。
    static let identifier = "group.com.zhisheng.weather"
    /// 天气载荷存储 key。
    static let payloadKey = "zs.weather.payload"
    /// 最近一次查询坐标 key（P1 复用）。
    static let locationKey = "zs.weather.location"
    /// F-B：城市列表 `[City]` JSON 的存储 key（D-1：独立双 key，payload 零改动）。
    static let citiesKey = "zs.weather.cities"
    /// F-B：当前选中城市 id 的存储 key。
    static let selectedCityIDKey = "zs.weather.selectedCityID"
    /// 强刷待办标志 key（Widget 刷新按钮 intent 写入，主 App 在 scenePhase
    /// 回到前台时消费；独立 key，不污染 payload / cities 既有数据）。
    static let pendingForceRefreshKey = "zs.weather.pendingForceRefresh"
}

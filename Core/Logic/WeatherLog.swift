//
//  WeatherLog.swift
//  Core / Logic  [App + Widget 共用]
//
//  Core 侧统一日志出口（`os.Logger`，subsystem 固定）。
//
//  为什么引入（review-2026-09-16-run37 §3）：全仓此前**只有 `print`**，
//  解码失败在真机上没有任何可捞的日志，「只能截图问人」。改用 `os.Logger`
//  后可用 Console.app / `log collect` 按 subsystem 过滤，且字段路径以
//  `privacy: .public` 打出，真机排障时**真的看得见**（不是被脱敏成 <private>）。
//
//  纪律：`import os` 是本轮**唯一**对「Core 仅 import Foundation」的例外，
//  已获团队裁定——不新增第三方依赖、不新增 target。Core 仍禁 UIKit / try! / fatalError。
//

import Foundation
import os

/// Core 统一日志出口。
enum WeatherLog {

    /// 固定 subsystem（便于真机用 `log collect --predicate 'subsystem == ...'` 捞取）。
    private static let subsystem = "com.zhisheng.weather.core"

    /// 解码失败日志（携带 codingPath + debugDescription）。
    static let decode = Logger(subsystem: subsystem, category: "decode")

    /// App Group 共享容器读 / 写。
    static let storage = Logger(subsystem: subsystem, category: "storage")
}

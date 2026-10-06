//
//  NmcAlarmResponse.swift
//  Core / Networking  [App + Widget 共用]
//
//  第六源（中国气象局 NMC 官方预警）响应 DTO。
//
//  ═══════════════════════════════════════════════════════════════════════
//  实测结构（2026-10-06 21:0x 真实 curl，HTTP 200，`content-type:
//  application/json;charset=UTF-8`，逐字键名）
//  ═══════════════════════════════════════════════════════════════════════
//  {
//    "msg": "success", "code": 0,
//    "data": {
//      "page": {
//        "pageNo":1,"pageSize":200,"count":161,"prev":1,"next":1,"totalPage":1,
//        "list":[ {"alertid":"35060441600000_20261006202800",
//                 "issuetime":"2026/10/06 20:28",
//                 "title":"福建省漳州市龙海区气象台发布大风黄色预警信号",
//                 "url":"/publish/alarm/35060441600000_20261006202800.html",
//                 "pic":"https://image.nmc.cn/assets/img/alarm/p0007003.png"} ]
//      },
//      "provinceAlarms": [],
//      "stat": { "province":{"r":0,"b":1,"y":1,"o":0},
//                "city":   {"r":0,"b":7,"y":13,"o":1},
//                "county": {"r":0,"b":40,"y":87,"o":12} }
//    }
//  }
//
//  ── 三条关键实测事实（直接决定了本文件的写法）────────────────────────
//  ① **数据在 `data.page.list`**；`data.provinceAlarms` **恒为空数组**
//     （实测两轮皆`[]`，且官方页面亦未见其内容）→ **刻意不建模**它。
//     刻意不建：无消费者就不建模，本仓纪律（见 `METNorwayResponse` 同款理由）。
//  ② `data.page` 与 `page.list` **必须都是可选**：本仓库吃过一次亏 ——
//     顶层少一个键就让**整包**解码失败，结果主屏与小组件同时无数据。
//     故本DTO **从顶层到叶子全部可选**，缺键一律回落为空数组（见 `NmcAlarmMapper`）。
//  ③ `list` 的**数组元素也声明为可选 `[Entry?]`**：上游在数组里塞 `null`
//     是同类接口的常见故障形态（本仓已在 Open-Meteo 与 MET Norway 各吃过一次）。
//
//  ── `stat` 刻意不建模 ─────────────────────────────────────────────────
//  它是**颜色 × 层级**的聚合计数（实测 `county.o`=12 个橙色），
//  但计数字段名 `r/b/y/o` 是**单字母缩写**，语义全靠猜；
//  且我们自己已能从`list` 逐条算出颜色分布（实测：黄102/ 蓝 46 / 橙 13，
//  与 `stat` 的 y/b/o 一致），故**不引入第二真源**，避免两处口径漂移。
//
//  ── 刻意不建模的字段 ─────────────────────────────────────────────────
//  · `pic` —— 预警图标 URL。本轮 UI 用 SF Symbol 按颜色分级，
//    不拉远端图（多一次请求 + 离线不可用）；将来要做图标再补。
//  · `code` / `msg` —— 业务状态。本源只按 HTTP 2xx 判成功（与既有源一致），
//    `code` 若非0 时`list` 会是空数组（实测 `count`=0 形态），故不额外分支。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// NMC 官方预警响应 DTO（解码失败安全：**从顶层到叶子全部可选**）。
struct NmcAlarmResponse: Decodable, Sendable {

    /// `data` 块。
    struct Data: Decodable, Sendable {
        /// `page` 块（**可选**：实测缺它不应让整包解码失败）。
        var page: Page?
    }

    /// `data.page` 块（分页容器）。
    struct Page: Decodable, Sendable {
        /// 条目数组（**可选**：缺它 → 空数组）。
        /// ⚠️ 元素声明为 `Entry?` —— 上游数组内出现 `null` 不得让整包失败。
        var list: [Entry?]?
    }

    /// 单条预警。
    struct Entry: Decodable, Sendable {
        /// 预警唯一 id。
        ///
        /// ⚠️ **实测结构（前6 位 = 国标 GB/T 2260 行政区划码）**：
        /// `35060441600000_20261006202800` → `350604`= 福建漳州市龙海区。
        /// 已用 8 个已知码交叉校验（`350581`=石狮市 / `430582`=邵东市 /
        /// `640381`=青铜峡市 / `441284`=四会市 …）**8/8 命中**。
        /// → 按城市筛选时用它；但它**不参与标题解析**（标题是权威展示源）。
        var alertid: String?
        /// 发布时间，形如 `2026/10/06 20:28`（**非 ISO8601**，
        /// 且**无时区**—— 实测为发布地墙钟）。
        var issuetime: String?
        /// 预警标题（全名，如 `福建省漳州市龙海区气象台发布大风黄色预警信号`）。
        var title: String?
        /// 详情页**相对**路径，形如
        /// `/publish/alarm/35060441600000_20261006202800.html`
        /// （**不带域名**，需与 host 拼成绝对 URL，见 `NmcAlarmEndpoint`）。
        var url: String?
    }

    /// 顶层 `data` 块。
    var data: Data?
}
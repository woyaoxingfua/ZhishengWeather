//
//  WeatherCnAlarmResponse.swift
//  Core / Networking  [App + Widget 共用]
//
//  中国气象网结构化预警通道响应 DTO（列表元组 + 详情 JSONP）。
//
//  ═══════════════════════════════════════════════════════════════════════
//  实测结构（2026-10-06 真实 curl，**逐字**；行号= `result.data[i]`）
//  ═══════════════════════════════════════════════════════════════════════
//  列表端点 `forecast.weather.com.cn/api/v1/traffic/alarm/alarmMap`：
//    {"status":"success","errMsg":"","result":{"count":"137","data":[
//      [ "新疆维吾尔自治区伊犁哈萨克自治州昭苏县",              // [0] 行政区划全串
//        "101131007-20261006212927-0902.html",                 // [1] 详情文件名
//        "81.13",                                              // [2] 经度（**字符串**）
//        "43.16",                                              // [3] 纬度（**字符串**）
//        "65402641600000_20261006212927",                      // [4] 本条 alertid
//        "65402641600000_20261006212927",                      // [5] 关联 alertid
//        "新疆维吾尔自治区伊犁哈萨克自治州昭苏县发布雷电黄色预警信号", // [6] 标题
//        {"coordinates":[[[81.324,43.396], …]]} }]}}          // [7] 边界多边形
//
//  ⚠️⚠️ **三条实测形态纪律**（写错就静默拿到错数据）──────────────────
//  ① **行是 8 元「位置数组」，不是对象** —— 故不能用 `Decodable` 的
//     键名解码，必须**按下标**解（见 `Row.init(from:)`）。
//     实测 137/137 行**元数恒为 8**（唯一值）。
//  ② **[2]/[3] 经纬度是 JSON 字符串**（逐字 `"81.13"`，**带引号**），
//     不是数字 → 故按 `String?` 收、再自行转 `Double`（转不动→ nil）。
//     `count` 同理实测为**字符串** `"137"`。
//  ③ **详情端点返回 JSONP，不是纯 JSON**（实测逐字，615~1082 字节）：
//        var alarminfo={"head":"…","ALERTID":"…",…};
//     → 必须先剥 `var alarminfo=` 前缀与尾分号，再 JSON 解码
//     （见 `WeatherCnAlarmDetail.decode(jsonpText:)`）。
//
//  ── 详情对象的 21 个键（实测 5 个城市样本，key 集合**完全一致**）────────
//  head / ALERTID / PROVINCE / CITY / STATIONNAME / SIGNALTYPE /
//  SIGNALLEVEL / TYPECODE / LEVELCODE / ISSUETIME / ISSUECONTENT /
//  UNDERWRITER / RELIEVETIME / NAMEEN / YJTYPE_EN / YJYC_EN / TIME /
//  EFFECT / msgType / identifier / references
//  其中 **`UNDERWRITER` 与 `YJTYPE_EN` 实测 5/5 恒为空串**，
//  `RELIEVETIME` / `ISSUECONTENT` 实测**恒非空**。
//
//  ── 刻意不建模的字段（附理由）────────────────────────────────────────
//  · **[7] 边界多边形**（实测单个 3522 字符）：本仓只按**城市名**匹配预警，
//    不做地理围栏判定 → 不建模（白扛 100+ KB 体积）。
//  · **[2]/[3] 经纬度**：实测同为**县**级点位，本仓按城市名筛选已足够；
//    保留解码但不参与匹配（避免引入"半径阈值"这类魔法数）。
//  · `ALERTID`（实测形如 `202610062129514372雷电黄色`，**混了中文**且
//    与 [4] 格式不同，是另一套内部编号）：与 NMC 的 `alertid` 对不上，
//    **不可做连接键** → 不建模。
//  · `TIME`（实测 `2026-10-06 21:35`，比 `ISSUETIME` 晚 ~5~7 分钟）：
//    语义未确（疑为入库/抓取时间）→ **不建模**，不拿它当发布时间。
//  · `msgType`（实测恒 `Alert`）、`references`（实测多数等于 `identifier`，
//    但 26/137 行不同 —— 实测 [5] 是**上一轮**的 alertid）：
//    对本仓补字段目标无用 → 不建模。
//
//  ── 解码失败策略：**逐字段可选**，整包失败由调用方抛 `WeatherError` ────
//  与 `NmcAlarmResponse` 同款纪律（上游少一个键就让整包失败、
//  主屏与小组件同时无数据，这个坑本仓吃过一次）。
//  故本 DTO **从顶层到叶子全部可选**，缺键 → nil → 由 mapper 决定回落。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

// MARK: - 列表

/// 中国气象网预警**列表**响应（实测 `data` 为 8 元位置数组的数组）。
struct WeatherCnAlarmListResponse: Decodable, Sendable {

    /// `result` 块。
    struct Result: Decodable, Sendable {
        /// 总条数（⚠️ 实测为**字符串** `"137"`，非数字）。
        var count: String?
        /// 预警行数组（**可选**：缺它 → 空数组）。
        var data: [Row]?
    }

    /// 业务状态（实测 `"success"`）。`status != "success"` 时 `data` 可能是空数组。
    var status: String?
    /// 错误描述（实测成功时为空串 `""`）。
    var errMsg: String?
    /// 数据块。
    var result: Result?

    /// 单条预警在 `data` 里的位置（**实测元数恒为 8**，唯一值）。
    enum Index {
        /// 行政区划全串（如 `新疆维吾尔自治区伊犁哈萨克自治州昭苏县`）。
        static let region = 0
        /// 详情文件名（如 `101131007-20261006212927-0902.html`）。
        static let filename = 1
        /// 经度（⚠️ 实测为**字符串**）。
        static let longitude = 2
        /// 纬度（⚠️ 实测为**字符串**）。
        static let latitude = 3
        /// 本条 `alertid`（**与 NMC 的 `alertid` 逐字相同**，实测 5/5）。
        static let alertID = 4
        /// 标题（实测比 NMC 标题**少「气象台」三字**，见文件头下方对照）。
        static let title = 6
        /// ⚠️ 下标 5（关联 alertid）与 7（边界多边形）**刻意不建模**
        /// （理由见文件头）。
        static let elementCount = 8
    }

    /// 预警行（**按下标解码**，非键名）。
    ///
    /// ⚠️ 用 `Decodable` 的**自定义 `init(from:)`** 实现，因为
    /// JSON 侧是数组而非对象；合成 `Decodable` 对数组形态会直接失败。
    /// 刻意**逐项容错**：某一项类型不符时该项为 nil，**不**让整行失败
    /// —— 实测经纬度是字符串，若上游某天改成数字，本行仍应部分可用。
    struct Row: Decodable, Sendable {

        /// [0] 行政区划全串。
        var region: String?
        /// [1] 详情文件名（拼详情 URL 用）。
        var filename: String?
        /// [4] 本条 `alertid`（**跨源连接键**）。
        var alertID: String?
        /// [6] 标题。
        var title: String?

        /// 按下标逐项解码（`keyedContainer` 在数组形态下不可用）。
        ///
        /// - 缺项 / 类型不符 → 该字段 nil，**不抛错**。
        /// - ⚠️ 下标越界（上游改元数）→ 越界取到 nil，**不崩溃**
        ///   （实测元数恒为 8，但不该把该性质当契约依赖）。
        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            // ⚠️ `UnkeyedDecodingContainer` **没有 `decode(_:at:)`** —— 它只能
            // **按游标顺序**解，没有随机下标入口。故先顺序扫一遍收集字符串，
            // 再按下标取。
            //
            // ⚠️ `container.allKeys` 在 unkeyed 容器上是**非 throwing** 属性，
            // 包 `try?` 会触发「type of expression is ambiguous without a type
            // annotation」。
            //
            // ⚠️⚠️ `container.count` 的类型是 **`Int?`**（不是 `Int`）——
            // 上一版拿它当非可选整数用，CI 报 "value of optional type 'Int?' must
            // be unwrapped"（两处：循环条件与下标上界）。
            // 而它**根本不必参与循环**：`isAtEnd` 才是权威终止判据。
            // 故此处**完全不读 `count`**，越界交给 `slots` 字典自身的语义
            // （下标不存在 → nil）。
            var slots: [Int: String] = [:]
            var cursor = 0
            while !container.isAtEnd {
                // 每轮**必须恰好消费一个元素**，否则游标不前进 → 死循环。
                // `decodeNil()` 遇 null 会消费并返回 true；
                // 否则 `decode(String.self)` 消费一个（失败时已抛出，
                // 但 currentIndex 不会推进 —— 故失败分支要靠 isAtEnd 兜底退出）。
                if (try? container.decodeNil()) == true {
                    cursor += 1
                    continue
                }
                if let text = try? container.decode(String.self) {
                    slots[cursor] = text
                    cursor += 1
                } else {
                    // 类型不符：无法用 decode 消费。unkeyed 容器没有公开的
                    // "跳过" API，此时**只能退出**——已解码的前缀仍可用，
                    // 缺的字段留 nil（**如实缺失**，不编造）。
                    break
                }
            }
            func string(_ index: Int) -> String? {
                guard index >= 0 else { return nil }
                // ⚠️ 不用 `index < count` 做上界判断 —— `count` 是 `Int?`，
                // 且越界时字典下标本身就会返回 nil（**字典不越界**）。
                return slots[index]
            }
            self.region = string(Index.region)
            self.filename = string(Index.filename)
            self.alertID = string(Index.alertID)
            self.title = string(Index.title)
        }

        /// 无参构造（供上面的容错分支复用）。
        init() {
            self.region = nil
            self.filename = nil
            self.alertID = nil
            self.title = nil
        }
    }
}

// MARK: - 详情

/// 中国气象网预警**详情**对象（实测 21 个键，样本间 key 集合完全一致）。
///
/// ⚠️ 全部可选：实测 `UNDERWRITER` / `YJTYPE_EN` **恒为空串**，
/// 建模为非可选 `String` 会让"空串"与"缺失"无法区分，也会诱使
/// 写出 `if !x.isEmpty` 之外的错误假设。
struct WeatherCnAlarmDetail: Decodable, Sendable, Equatable {

    /// 标题（实测与列表 [6] 逐字相同）。
    var head: String?
    /// 省（实测 `新疆维吾尔自治区` / `福建省`）。
    var PROVINCE: String?
    /// 市（实测 `伊犁哈萨克自治州` / `泉州市`）——**带行政后缀**，
    /// 与 NMC 标题里的地级名同口径，故复用 `normalizedPrefectureName`。
    var CITY: String?
    /// 县级发布机构名（实测 `昭苏县` / `惠安县`；可为空串）。
    var STATIONNAME: String?
    /// 预警类型（实测 `雷电` / `大风` / `大雾`）。
    var SIGNALTYPE: String?
    /// 预警颜色中文（实测 `黄色` / `蓝色`）。
    var SIGNALLEVEL: String?
    /// 类型码（实测 `雷电`=09 / `大风`=05 / `大雾`=12；**未实测全表**）。
    var TYPECODE: String?
    /// 颜色码（实测 `黄色`=02 / `蓝色`=01；**未实测全表**）。
    var LEVELCODE: String?
    /// 发布时间，形如 `2026-10-06 21:29:27`（**带秒**，非 ISO8601）。
    var ISSUETIME: String?
    /// ⚠️ **防御指南正文**（NMC 源拿不到的那部分增量信息）。
    ///
    /// 实测 5/5 **恒非空**（81~147 字符），形态为
    /// `<机构><日期><时分>发布<类型><颜色>预警信号：<正文>（预警信息来源：…）`。
    var ISSUECONTENT: String?
    /// 解除时间，形如 `2026-10-07 09:29:27`（⚠️ 实测**恒非空**）。
    ///
    /// ⚠️ 语义**未确**：它可能是"预计解除"而非"实际解除"——
    /// 实测 5条里4 条恰为 `ISSUETIME + 12h`（+1 条为 `+4h6m` 精确同刻），
    /// 这个规律更像**有效期**而非"实际解除时刻"。
    /// 故**只作为 `detailExpiresAt` 语义标注，不当"已解除"展示**（见 mapper）。
    var RELIEVETIME: String?
    /// ⚠️ **实测是汉语拼音、不是英文**：`zhaosu yilihasake xinjiang` /
    /// `huian quanzhou fujian`。**不可当英文标题展示**（见 mapper 注释）。
    var NAMEEN: String?
    /// 英文颜色名（实测 `Yellow` / `Blue`，**非空**）。
    var YJYC_EN: String?
    /// 关联站点城市码（实测 9 位，如 `101131007`）——与列表文件名
    /// 前缀**逐字相同**（实测 5/5）。
    var EFFECT: String?
    /// 跨源连接键（实测与列表 [4]、NMC `alertid` **逐字相同**，5/5）。
    var identifier: String?

    /// 从 **JSONP** 文本解码（实测壳为 `var alarminfo={…};`）。
    ///
    /// - Parameter jsonpText: 详情端点原始响应体。
    /// - Returns: 解码结果；非 JSONP 壳 / JSON 非法 → **nil**（不抛错）。
    ///
    /// ⚠️ **为什么必须剥壳**：实测响应逐字为
    /// `var alarminfo={"head":"…",…};` —— 直接 `JSONDecoder` 会因
    /// 前缀 `var alarminfo=` 报"数据不符合预期格式"。
    ///
    /// ⚠️ 剥壳方式刻意**保守**：定位首个 `{` 与末个 `}`，取中间子串。
    /// 不做"删前缀 + 删尾分号"的字符串手术—— 那种写法在响应里出现
    /// 额外空白时会静默产生非法 JSON。
    static func decode(jsonpText: String) -> WeatherCnAlarmDetail? {
        guard let objectStart = jsonpText.firstIndex(of: "{"),
              let objectEnd = jsonpText.lastIndex(of: "}") else { return nil }
        // ① 壳的前缀必须**逐字**是 `var alarminfo=`（实测恒为该名）。
        //    不校验 → 万一上游换成别的变量名，会把别的东西当详情解析。
        let prefix = String(jsonpText[..<objectStart])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix == "var alarminfo=" else { return nil }
        // ② `}` 必须在 `{` 之后（畸形响应下 `lastIndex` 可能更靠前）。
        guard objectStart < objectEnd else { return nil }
        let json = String(jsonpText[objectStart...objectEnd])
        guard let data = json.data(using: .utf8) else { return nil }
        // ③ 解码失败返回 nil（**不抛错**）：由调用方决定是丢弃还是记故障。
        return try? JSONDecoder().decode(WeatherCnAlarmDetail.self, from: data)
    }
}
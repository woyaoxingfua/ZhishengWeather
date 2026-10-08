//
//  NmcTyphoonResponse.swift
//  Core / Networking  [App + Widget 共用]
//
//  第七源：中央气象台台风网（`typhoon.nmc.cn`）响应 DTO + **JSONP 剥壳**。
//
//  ═══════════════════════════════════════════════════════════════════════
//  实测基准：2026-10-07（本 worker 当次真实 curl，HTTP 200 / 2797B /
//  12478B / 26767B / 11462B / 2307B / 2612B / 1688B / 2267B）
//  ═══════════════════════════════════════════════════════════════════════
//
//  ──🔴 坑一：响应不是纯 JSON，是 JSONP，且**两个端点的括号层数不同** ────
//  设计稿称「JSONP 双层括号 `((...))`」。**本 worker 当次实测：只有列表
//  端点是双层，`view_` 端点是单层** —— 逐字实测首尾：
//
//  ① `list_default`（**双层**）：
//    首 `typhoon_jsons_list_default(({"typhoonList":[[3346033,"KOGUMA"
//    尾 `"2601",20260001,"一种鸟；燕子","stop"]]}))`
//    → 截断到首个 `(` 与末个 `)` 之间得 `({"typhoonList":[…]})`
//    → **再剥一层**才legal JSON。
//
//  ② `view_3346168`（**单层**，设计稿在此处不准确）：
//    首 `typhoon_jsons_view_3346168({"typhoon":[3…`
//    尾 `…"15":[49],"16":[50]}]]]})`
//    → 截断到首个 `(` 与末个 `)` 之间**直接就是** legal JSON。
//
//  ③ `list_1950` / `list_1999` / `list_2024` / `view_3227033`
//    **逐一实测**，层数分别与①②同型（即「列表双层、view 单层」一致）。
//
//  → 故本文件用**循环剥壳**（`while` 而非 `if`）而不是硬剥两层：
//  写死两层会把`view_` 多剥一次（JSON 尾`}` 被吃掉 → 解析失败），
//  写死一层会把列表的 `({"…})` 直接喂给 `JSONDecoder` →
//  `JSONDecodeError: Expecting value: line 1 column 1 (char 0)`。
//
//  ── 🔴 坑二：错误 id 返回 **HTML**（实测）────────────────────────────────
//  `view_9999999` → **HTTP 404**，`content-type: text/html`，591B；
//  `list_2030`（未来年份）→ **HTTP 404**，`text/html`，618B。
//  两者响应体逐字以`<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">` 开头。
//  → 剥壳前必须先试解析；解析失败按「取不到」处理，**绝不**当空台风列表。
//
//  ── 坑三：定长但**类型不稳** → DTO 逐字段可选─────────────────────────
//  详见 `Typhoon.swift` 的逐下标实测表与 `NmcTyphoonMapper`。
//
//  ── 为什么 DTO 用 `[JSONValue?]` 这种「弱类型袋」────────────────────
//  上游是**网页前端接口**（非承诺的开放 API），实测已确认「同一字段在不同
//  端点类型不同」（编号在 `list_` 是 String、在 `view_` 是 Int）。
//  任何强类型 DTO 都会在结构变化时**整包解码失败** → 台风功能整体消失。
//  故这里统一用 `JSONValue` 承接，**由 mapper 按类型逐字段安全取值**：
//  单字段解析失败只丢该字段，**不拖垮整批**。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

// MARK: - 弱类型 JSON 承接

/// 弱类型 JSON 值（本仓 DTO 的**兜底承接类型**）。
///
/// ── 为什么需要它 ────────────────────────────────────────────────────
/// 上游台风接口的路径点实测为「定长 13 但逐点类型不稳」的**裸数组**
/// （无key、无字段名）。若把每个下标声明成强类型 `Decodable`，
/// 上游任何一次类型漂移（如实测 `list_` 的编号是 String、`view_` 是 Int）
/// 都会让**整包解码抛错** → 整个台风功能静默消失。
/// 故用本类型承接：**任何 JSON 都能解出来**，取值交给 mapper 按类型判断。
///
/// 纯 `Foundation` 可解码，无 MapKit / UIKit 依赖。
enum JSONValue: Decodable, Equatable, Sendable {

    /// 空（JSON `null`）—— 实测上游大量使用（列表下标 5/6、路径点下标 11…）。
    case null
    /// 布尔。
    case bool(Bool)
    /// 数字（**Int 与 Double 统一落这里**，实测上游两种都出现）。
    case number(Double)
    /// 字符串。
    case string(String)
    /// 数组（实测 `[["30KTS",380,…]]`、`{"BABJ":[…]}` 的值等）。
    case array([JSONValue])
    /// 对象（实测预报字典 `{"BABJ": […]}`）。
    case object([String: JSONValue])

    /// 解码入口（**永不抛错** —— 无法识别的形态一律落`.null`）。
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            //⚠️ 先试 Double：实测上游把「编号」等整数也当JSON 数字发，
            //   且 JSONDecoder 对 `2628` 与 `2628.0` 都解得出Double。
            //   需要 Int 语义时用 `intValue`（内部再四舍五入判等）。
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            // 理论上到不了这里（单值容器已穷举），保底不抛以维持「永不失败」。
            self = .null
        }
    }

    // MARK: - 按类型安全取值（**单字段失败只丢该字段**）

    /// 数组值（非数组 → nil）。
    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// 对象值（非对象 → nil）。
    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// 字符串值。
    ///
    ///⚠️ 数字也**允许**转字符串（实测编号在 `list_` 是 String、
    ///   在 `view_` 是 Int，同一语义两种类型 → 用户看的是数字文本）。
    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return Self.describeNumber(value)
        default: return nil
        }
    }

    /// 数值值（字符串若恰是数字也收—— 实测 JMA 那类源全是字符串，
    /// 本源虽实测为数字，但保持宽容）。
    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    /// 整数值（`doubleValue` 恰好是整数时返回；否则 nil）。
    ///
    /// ⚠️ 用**等值判定**而非 `Int(x)` 强转：`Int(1.5)` 会静默截断成 `1`，
    /// 把上游的异常值变成一个**看起来正常**的错误数字。故只接受等值。
    var intValue: Int? {
        guard let double = doubleValue else { return nil }
        let rounded = double.rounded()
        guard rounded == double, rounded >= Double(Int.min), rounded <= Double(Int.max) else {
            return nil
        }
        return Int(rounded)
    }

    /// 数字的整数字面串（实测编号下标 3/4 在 `list_` 是 `"2628"`，
    /// 转成 `String` 后**不带 `.0`** —— `String(2628.0)` 会得到 `"2628.0"`）。
    private static func describeNumber(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(value)
    }
}

// MARK: - 顶层响应

/// 台风网顶层响应（承载列表与详情两种形态）。
///
///实测两种形态的**唯一key**：
/// · 列表端点 → `{"typhoonList": [ 定长8 数组, … ]}`
/// · 详情端点 → `{"typhoon": [ 定长10 数组 ]}`（0–7 头部+ 8 路径 + 9 索引表）
struct NmcTyphoonResponse: Decodable, Sendable {

    /// 列表端点的条目（实测 32 条，**每条定长 8**）。
    let typhoonList: [JSONValue]?

    /// 详情端点的顶层数组（实测**长度 10**，非设计稿所说的 8）。
    let typhoon: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case typhoonList
        case typhoon
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 两个 key **各自独立可选**：实测两类响应只带其中一个
        // （`list_default` 只有 `typhoonList`、`view_<id>` 只有 `typhoon`）。
        // ⚠️ 用 `try?` + 非可失败 `decode`（key 缺失时 decode 抛错 → nil），
        // 而不是 `decodeIfPresent` —— 后者会产出 `Optional<Optional<…>>`
        // 这种需要二次摊平的形态（本仓已因 `compactMap` 只解一层Optional 踩过）。
        typhoonList = try? container.decode([JSONValue].self, forKey: .typhoonList)
        typhoon = try? container.decode([JSONValue].self, forKey: .typhoon)
    }
}

// MARK: - JSONP 剥壳

/// JSONP 剥壳器。
///
/// ── 实测结论（本worker 当次，逐字记录首尾）─────────────────────────
/// · `list_default` / `list_1950` / `list_1999` / `list_2024`：
///   `name(({"…"}))` → **双层**；
/// · `view_3346168` / `view_3341981` / `view_3346033` / `view_3227033`：
///   `name({"…"})` → **单层**。
///
/// ⚠️ 故此处用**循环**剥壳：每轮若「以 `(` 开头且以 `)` 结尾」就再剥一层，
/// 直到不再满足为止。这样对1 层 / 2 层 / 3 层都成立，**不写死层数**。
enum NmcTyphoonJSONP {

    /// 剥掉 JSONP 外壳，返回**纯 JSON 片段**。
    ///
    /// - Parameter data: 原始响应字节。
    /// - Returns: 可直接交给 `JSONDecoder` 的 JSON 字节。
    /// - Throws: `WeatherError.decodingDetail`（**HTML 错误页等非 JSONP 响应**）。
    static func unwrap(_ data: Data) throws -> Data {
        // 响应体不是合法 UTF-8（如错误页的乱码字节）→ 直接失败，不硬解。
        guard let text = String(data: data, encoding: .utf8) else {
            throw WeatherError.decodingDetail(path: "",
                                              debugDescription: "响应非 UTF-8 文本（疑似错误页）")
        }
        let unwrapped = strip(text)
        guard !unwrapped.isEmpty else {
            throw WeatherError.decodingDetail(path: "",
                                              debugDescription: "JSONP 剥壳后为空（响应不是 JSONP 形态）")
        }
        guard let out = unwrapped.data(using: .utf8) else {
            throw WeatherError.decodingDetail(path: "",
                                              debugDescription: "剥壳结果无法转回 UTF-8")
        }
        return out
    }

    /// 纯字符串版剥壳（供单测直接断言层数行为）。
    ///
    /// - Parameter text: 原始响应文本。
    /// - Returns: 剥壳后的 JSON 文本。
    static func strip(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 定位首个 `(`：其前是回调函数名（实测逐字为
        // `typhoon_jsons_list_default` / `typhoon_jsons_view_3346168`
        // / `typhoon_jsons_list_1950` —— **回调名随端点而变**，故按首个
        // `(` 截断，**不硬编码匹配任何函数名**）。
        guard let open = body.firstIndex(of: "(") else { return "" }
        // 定位末个 `)`：其后是分号或换行。
        //
        // ⚠️ `close > open` 这道守卫同时兜住了**半开区间**的越界：
        // `..<close` 要求 `index(after: open) <= close`，而 `close > open`
        // 在字符索引上恰好等价于该条件。故退化输入（如实测 `cb()`）会得到
        // **合法空区间**（空串，交给 `unwrap` 抛「剥壳后为空」）而**不会崩溃**。
        guard let close = body.lastIndex(of: ")"), close > open else { return "" }
        //
        // 🔴 **这里必须用半开区间 `..<`，不能用闭区间 `...`（P-37）**：
        // `close` 是**末个 `)` 自身**的位置，闭区间会把它一起切进来，
        // 于是壳内末尾**多留一个右括号**。而下面的剥壳循环以
        // 「以 `(` 开头且以 `)` 结尾」为条件 —— 残留的 `)` 恰好满足
        // `hasSuffix(")")`，却让 `hasPrefix("(")` 为假，循环**立刻 break**，
        // 于是这个多余的 `)` 永远留在结果里，交给 `JSONDecoder` 就是
        // `dataCorrupted`（"The given data was not valid JSON."）。
        //
        // 该切片已用本仓 5 个实测 JSONP 样本逐一复核（`listDefaultJSONP` /
        // `viewTrackJSONP` / `historicalTrackJSONP` / `list1950JSONP` /
        // `list2024JSONP`）：闭区间版本 5 个全产出「合法JSON + 一个残余 `)`」，
        // 半开区间版本 5 个全产出可直接解码的合法 JSON。
        body = String(body[body.index(after: open)..<close])
        // 循环剥壳：**实测层数因端点而异**（list 双层 / view 单层），
        // 故用 while 而不是 if —— 见本文件头「坑一」。
        //
        // ⚠️ **每轮先 trim 再判断**：`hasPrefix("(")` 要求首字符**精确**是 `(`，
        // 故若壳内带空格（如 `cb( ({"a":1}) )`），不trim 就**剥不掉**，
        // 结果整份响应被当成「非 JSONP 形态」抛错 → **整个台风源静默消失**。
        // 实测当前 4+4 个端点壳内均无多余空白（故此前未触发），
        // 但上游加一个空格就会全面失效，故此处**按最坏情况**处理。
        while true {
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.hasPrefix("("), body.hasSuffix(")") else { break }
            body.removeFirst()
            body.removeLast()
        }
        return body
    }
}
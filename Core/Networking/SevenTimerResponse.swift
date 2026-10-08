//
//  SevenTimerResponse.swift
//  Core / Networking  [App + Widget 共用]
//
//  第八源 7timer!（www.7timer.info/bin/api.pl，免 Key）的 DTO。
//
//  ── 实测（2026-10-07，curl -L --compressed，浏览器 UA）───────────────────────
//  · 端点：`https://www.7timer.info/bin/api.pl?lon=&lat=&product=&output=json`
//  · **必须带 `product`**：缺失实测返回 **HTTP 200 + `Content-Type: text/plain`
//    的正文 `ERR: no product specified`** —— 不是 4xx，而是 200！
//    → 错误分支**必须先判正文**，否则会把纯文本当 JSON 解码失败（错报解码故障）。
//  · `product` 合法值（实测逐个试出来的，与官方 doc.php §2.2.2 列出的五个一致）：
//    `astro` / `civil` / `civillight` / `meteo` / `two`。
//    ⚠️ 传其它值（如 `complete`）实测同样返回 **HTTP 200** + 正文
//       `ERR: invalid product`（20 字节）。
//  · 响应头实测：`Server: Apache/2.4.68 (Debian)`、`Content-Type: text/plain`
//    （**JSON 也标 text/plain**，所以不能靠 content-type 判是不是 JSON）。
//  · 无需 UA：实测 `User-Agent` 传空串仍 **HTTP 200**、字段齐全
//    （与 MET Norway 相反 —— 后者不带 UA 可能被拒）。
//
//  ── 本源采用 `product=meteo`（**不是**报告推荐的 civillight）──────────────
//  报告 §5「推荐 2」写的是 `product=civillight`。实测两者字段差异很大：
//  · `civillight`：**逐日** 7 条，只有 `date` / `weather` / `temp2m.{max,min}` /
//    `wind10m_max`（实测 915 字节）。**没有**逐时、没有气压、没有湿度。
//  · `meteo`：**逐 3 小时** 64 条，实测 145993 字节，字段见下。
//  本源要补的是 `WeatherFieldKey` 里的**标量数值场**（温/压），
//  `civillight` 只有逐日 max/min —— 与标量场语义不合（详见 Mapper 的诚实说明），
//  故取 `meteo`。
//
//  ⚠️ **`timepoint` 不是时间戳**（实测逐条确认）：它是「相对 `init` 的小时数」，
//    取值 3,6,9,...,192（步长 3，共 64 条 = 192h = 8 天）。
//    **绝对时刻 = `init` + `timepoint` 小时**（`init` 见下方 `init` 字段）。
//
//  ⚠️ **`init` 是 10 位 `YYYYMMDDHH`**（实测值 `2026100706`，len==10）。
//    它**没有分钟位** —— 早期按 `%Y%m%d%H%M` 解析会把 `06` 读成「0 点 6 分」
//    而把时刻整体偏移 6 分钟，故这里手工切分位。
//
//  ⚠️ **`-9999` 是「无效值」哨兵**（官方 doc.php §2.3.1「无效值 -9999」一节逐字）。
//    实测它在真实响应里**会出现**：`(0, 0)` 无人区 64 条的 `msl_pressure`
//    **全是 -9999**；`lat=-89.9`（南极）则 `temp2m` / `msl_pressure` /
//    `wind10m.direction` **全部 64 条都是 -9999**。
//    → 解码成 Int 之后**必须过滤**，否则 App 会显示「-9999 hPa」这种荒唐值。
//    实测该哨兵**也出现在 `wind10m.direction` 上**（该字段是字符串型，
//    故按字符串比较）。
//
//  ── 容错 ────────────────────────────────────────────────────────────────
//  · 所有属性**可空**：缺块/缺字段 → nil（下游显示 `--`，绝不用假值填）。
//  · `dataseries` 元素**可空** `[Entry?]`：本仓库曾因元素写非可选导致整包解码失败。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / try! / fatalError。
//

import Foundation

/// 7timer! `product=meteo` 响应 DTO。
struct SevenTimerResponse: Decodable {

    /// 产品名（实测恒为 `"meteo"`；缺 `product` 时是纯文本 `ERR:` 而非本结构）。
    let product: String?
    /// 模型初始化时刻，**10 位 `YYYYMMDDHH`**（实测 `"2026100706"`）。
    let init: String?
    /// 逐 3 小时序列（实测 64 条）。
    let dataseries: [Entry?]?

    /// 单条时序（实测字段名逐字如下，全部可空）。
    struct Entry: Decodable {
        /// 相对 `init` 的**小时数**（实测 3,6,9,…,192；**不是**时间戳）。
        let timepoint: Int?
        /// 2 米气温，**单位 ℃**（官方 doc.php §2.3.1「2米气温 -76至60 摄氏度」）。
        let temp2m: Int?
        /// 修正海平面气压，单位 **hPa**（实测与Open-Meteo `pressure_msl` 同量级）。
        /// ⚠️ 无效时为 **-9999**（实测无人区全条如此）。
        let msl_pressure: Int?
        /// 2 米相对湿度 —— ⚠️ **档位码，不是百分比**（见文件头诚实说明）。
        let rh2m: Int?
        /// 总云量 —— ⚠️ **1..9 档位码，不是百分比**（见文件头诚实说明）。
        let cloudcover: Int?
        /// 10 米风 —— ⚠️ `speed` 是 **1..8 档位码**，**不是 m/s**（见文件头）。
        let wind10m: Wind?
        /// 降水强度（⚠️ **0..9 档位码**，不是 mm）与降水类型。
        let prec_amount: Int?
        let prec_type: String?
    }

    /// 10 米风（实测 `direction` 为**字符串**，如 `"195"`；同一字段在 `astro`
    /// 产品里是方位字母如 `"S"` —— **跨产品不一致**，故这里一律按字符串收）。
    struct Wind: Decodable {
        let direction: String?
        /// ⚠️ **1..8 档位码**，不是 m/s（实测值域仅 {2,3,5}，与 Open-Meteo 的
        /// m/s 数值对不上；官方 doc 明确它是风力等级码）。
        let speed: Int?
    }
}

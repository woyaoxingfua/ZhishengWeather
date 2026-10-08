//
//  SevenTimerEndpoint.swift
//  Core / Networking  [App + Widget 共用]
//
//  第八源 7timer! 请求拼装（免 Key、零鉴权）。
//
//  ── 实测（2026-10-07）────────────────────────────────────────────────────
//  · 端点：`https://www.7timer.info/bin/api.pl`
//  · **必须带 `product`**：缺失实测 **HTTP 200** + 正文 `ERR: no product specified`。
//    传非法值（如 `complete`）同样 **HTTP 200** + 正文 `ERR: invalid product`。
//    ⚠️ 所以「HTTP 200」**不等于**「拿到数据」——错误是以 200 + 纯文本正文
//       表达的。判错误必须**看正文**（见 Service 的 `isErrorBody`）。
//  · 坐标非法（如 `lat=95`）实测也是 **HTTP 200** + 正文 `ERR: invalid coordinate`。
//  · ⚠️ **坐标恰为 0 亦被当作「未指定」**：实测 `lat=0` 或 `lon=0`（如 (0,0)）
//    返回 **HTTP 200** + 正文 `ERR: no geographic location specified`
//    （共 4 种错误正文形态，全部以 `ERR:` 开头 → 前缀判别即可全覆盖）。
//  · `unit` 参数对 JSON 输出**无效**：实测 `unit=metric` 与 `unit=imperial`
//    两次请求的 `temp2m` / `msl_pressure` / `wind10m` **逐字相同**
//    （26/1020/195/3 vs 26/1020/195/3）→ JSON 恒为公制，**不要**依赖它做换算。
//    （官方 doc §2.2.3 列了`unit`，但那是给图表输出用的。）
//  · 无需特定 UA：实测空 UA 仍 200 且字段齐全 → 不设 UA（少一个失败面）。
//  · 不需 `output=internal`：默认即数据输出；`output=json` 显式声明以免歧义。
//
//  ⚠️ **参数顺序无关但键名不可省**：`lon` / `lat` / `product` / `output`。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / try! / fatalError。
//

import Foundation

/// 7timer! `api.pl` 请求拼装器（独立域名，免 Key）。
enum SevenTimerEndpoint {

    /// 独立基础地址（**与Open-Meteo 完全不同域名** —— 这是它作为兜底的前提）。
    static let baseURLString = "https://www.7timer.info/bin/api.pl"

    /// 本源采用的 `product`（实测合法值之一）。
    ///
    /// ⚠️ 官方 doc.php §2.2.2 列出的五个合法值是 `astro` / `civil` / `civillight` /
    ///    `meteo` / `two`；**`complete` 不在其中**（实测 `ERR: invalid product`）。
    /// 选 `meteo` 而非报告推荐的 `civillight` 的理由见 `SevenTimerResponse` 文件头。
    static let product = "meteo"

    /// 拼装请求 URL（只有这一条 URL / 一次请求）。
    ///
    /// - Returns: 失败返回 nil（由调用方收敛为 `WeatherError.badURL`）。
    static func url(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: baseURLString)
        components?.queryItems = [
            URLQueryItem(name: "lon", value: String(longitude)),
            URLQueryItem(name: "lat", value: String(latitude)),
            URLQueryItem(name: "product", value: product),
            URLQueryItem(name: "output", value: "json")
        ]
        return components?.url
    }

    /// 错误正文的**判别前缀**（实测四种，均为 HTTP 200）：
    /// `ERR: no product specified` / `ERR: invalid product` /
    /// `ERR: invalid coordinate` / `ERR: no geographic location specified`。
    /// —— 四种**全部**以 `ERR:` 开头，故前缀判别即可全覆盖。
    static let errorBodyPrefix = "ERR:"

    /// 响应正文是否为本源的 200-错误（纯文本，**不是** JSON）。
    ///
    /// 为什么需要它：本源所有失败都带 **HTTP 200**，`2xx` 检查**放它们过去** →
    /// 直接 `JSONDecoder` 解一个 `ERR: ...` 的纯文本 → 抛出**解码失败**，
    /// 上层显示「数据结构与预期不符（可能是接口变更）」—— **归因完全错误**
    /// （真实原因是「请求参数无效」）。故须先判正文再解码。
    ///
    /// 实现刻意**只比对前缀**而不做完整 JSON 解析：正文极短（实测 20–27 字节），
    /// 前缀判别足够且不引入「谁来解析错误体」的第二套逻辑。
    ///
    /// - Parameter data: 原始响应字节。
    /// - Returns: 命中 200-错误前缀 → true。
    static func isErrorBody(_ data: Data) -> Bool {
        // 只看前若干字节：错误体实测 ≤ 27 字节，无需整包解码。
        let prefixLength = min(data.count, 64)
        guard prefixLength > 0,
              let text = String(data: data.prefix(prefixLength), encoding: .utf8) else {
            return false
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(errorBodyPrefix)
    }
}
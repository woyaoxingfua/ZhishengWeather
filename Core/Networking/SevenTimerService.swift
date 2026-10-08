//
//  SevenTimerService.swift
//  Core / Networking  [App + Widget 共用]
//
//  第八源取数实现（actor，实现 `FieldSupplying`）。
//
//  ── 为什么它是「兜底」而不是「并行第三源」─────────────────────────────────
//  本源**不与主源并行请求**。它在 `SourceComposition.makeAuxiliarySources()` 里
//  被放在**辅助链末位**，而 `FieldFallbackResolver.merge` 的契约是
//  「主源非 nil绝不被覆盖；辅助源按链序取**第一个**有值的」：
//  · 主源（Open-Meteo）正常 → 主源值胜出，本源的值被丢弃（**不发请求也不影响**）；
//  · 主源缺字段 → 前面几个辅助源先顶；
//  · 前序全缺 → 本源才被merge 选中。
//  ⚠️ 见 `SourceAttributionCoordinator` 的说明：本仓现有骨架**没有**「按需触发
//  「备用源只在主源失败时才拉取」的条件拉取机制（协调器是**逐源串行全拉**）。
//  本源沿用该机制（不擅自另造一套），但**顺序保证它在有其它可用值时贡献为空**。
//
//  ── 失败隔离（沿用既有四纪律）──────────────────────────────────────────
//  自带调用、catch 只置本槽位、不 rethrow、不连累主链路。
//
//  ⚠️ **200-错误陷阱（本源的特有坑，实测四种形态全部带 HTTP 200）**：
//  `ERR: no product specified` / `ERR: invalid product` / `ERR: invalid coordinate`
//  / `ERR: no geographic location specified`
//  都以 **HTTP 200** 返回。若只做 `2xx` 检查就会把纯文本交给 `JSONDecoder`
//  → 抛解码失败 → 上层显示「数据结构与预期不符（可能是接口变更）」，
//  **归因完全错误**（真实原因是请求参数无效）。故本实现**先判正文**
//  （`SevenTimerEndpoint.isErrorBody`），再解码。
//
//  ⚠️ **不带 User-Agent**：实测空 UA 仍 HTTP 200 且字段齐全，故不设
//  （少一个可能触发限流的变量；与 MET Norway 的「必须带 UA」相反）。
//
//  **时区未知不补值**（ARCH §3.5）：本源只产出数值标量，绝不读 `TimeZone.current`、
//  绝不猜测城市。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / 内部 Date() / try! / fatalError。
//

import Foundation

/// 基于 www.7timer.info 的兜底源取数实现（按能力补两个精确对齐的数值标量）。
actor SevenTimerService: FieldSupplying {

    private let session: URLSession

    /// 初始化（可注入 URLSession，测试传自定义 configuration）。
    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - DataFieldSource
    //
    // 四个声明面属性均为不可变 Sendable 值类型，语义上无需隔离；
    // 加 `nonisolated` 以满足 FieldSupplying（nonisolated 协议要求）。

    nonisolated let id: SourceID = .sevenTimer
    nonisolated let displayName: String = "7timer!（兜底）"
    nonisolated let capabilities: Set<SourceCapability> = [.coarseFallbackFields]
    /// ⚠️ 必须**恰好**等于 `SevenTimerMapper` 会写入的字段集合
    ///（温度/ 气压 / 风向；**不含**湿度 / 云量 / 风速 —— 那三个是档位码，见Mapper 头）：
    /// 多声明 → 该源被 EV-1 误摘（静默自伤）；漏声明 → 该字段永不参与 EV-1（哑火）。
    nonisolated let requiredFields: Set<WeatherFieldKey> = [.temperature, .pressure, .windDirection]

    // MARK: - FieldSupplying

    func fetchFields(latitude: Double,
                     longitude: Double,
                     capabilities: Set<SourceCapability>,
                     now: Date) async throws -> FieldPatch {
        // 不请求本源能力 → 直接返回空补丁（不联网）。
        guard capabilities.contains(.coarseFallbackFields) else {
            return FieldPatch(sourceID: id, capturedAt: now)
        }

        guard let url = SevenTimerEndpoint.url(latitude: latitude, longitude: longitude) else {
            throw WeatherError.badURL
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw WeatherError.timeout(urlError.localizedDescription)
        } catch {
            throw WeatherError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw WeatherError.network("非 HTTP 响应")
        }
        // EV-3：非 2xx 透传状态码（由协调器裁定 auth / rateLimit）。
        guard (200..<300).contains(http.statusCode) else {
            throw WeatherError.badStatus(http.statusCode)
        }

        // ⚠️ 200-错误正文（实测带 200）必须**先于**解码判别，
        // 否则会被误报成「解码失败 / 上游接口变更」。
        //
        // ⚠️ 这里先求值出 `String`（非可选）再插值：原先写成
        //    `"前缀" + String(data:…).map{…} ?? "兜底"` —— `??` 优先级**低于** `+`，
        //    于是被解析为 `("前缀" + String?) ?? "兜底"`，即 `String + String?`，
        //    不是合法运算，**编译不过**（且这张屏永远到不了运行时）。
        guard !SevenTimerEndpoint.isErrorBody(data) else {
            let body = String(data: data.prefix(64), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "无法解析"
            throw WeatherError.dataMissing(
                "7timer 返回错误正文（HTTP \(http.statusCode)）：\(body)")
        }

        // 统一解码入口（失败携带 codingPath，不静默）。
        let dto = try ResponseDecoding.decode(SevenTimerResponse.self, from: data)

        // mapper 处理哨兵 -9999、时间归一（取离 now 最近的一格）与超差拒绝。
        return SevenTimerMapper.map(dto, now: now)
    }
}
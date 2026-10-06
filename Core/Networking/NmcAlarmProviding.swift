//
//  NmcAlarmProviding.swift
//  Core / Networking  [App + Widget 共用]
//
//  第六源取数：协议 + actor 实现，镜像 `MarineProviding` 的形状
//  （预警与海浪同为「独立链路 + 独立领域模型」，故取同一形状而非
//  `FieldSupplying`：预警**不在** `WeatherFieldKey` 域内，
//  且它是**列表** —— 塞进 `FieldPatch` 只会逼出一个假字段。
//  见 `SourceCapability` 注释里已就 `.marineWaveConditions` 立过的同款纪律）。
//
//  ── 失败隔离 ─────────────────────────────────────────────────────────
//  全部失败路径抛 `WeatherError`（复用既有错误类型），调用方 catch 后
//  只置本槽位、不rethrow、不连累主天气链路（R5 双向失败隔离）。
//  · 非 2xx → `.badStatus(code)`（供 EV-3 裁定冷却 / 会话摘除）；
//  · 网络失败 → `.network` / `.timeout`（沿用既有二分）。
//
//  ── ⚠️ **返回空数组 ≠ 成功**（本文件最重要的契约）────────────────────
//  `fetchAllWarnings()` 返回 `[]` 只表示「**HTTP 2xx + 解码成功 + 上游当前
//  没有预警**」；任何故障都**抛错**而非返回空数组。
//  为什么这条必须这样切分：调用方要用「成功但为空」与「失败」区分出
//  `.none`（真的没有预警 → 整卡隐藏）与 `.stale`（取不到 → **显式告知**）。
//  若本文件把失败也表达成 `[]`，调用方就**无从区分**，
//  而在灾害天气里把"取不到"显示成"没有预警"是**内容错误**。
//
//  ── 时区 ─────────────────────────────────────────────────────────────
//  `timeZone` 由调用方注入（`City.timeZoneIdentifier` → `WeatherTimeFormatter`
//  的裁定）。本文件**不**读 `TimeZone.current`、**不**硬编码 +8：
//  `issuetime` 是发布地墙钟，按错时区解释会让境外设备上的新预警
//  被算成 8 小时前的旧数据 → 误判 `.stale`。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / try! / fatalError。
//

import Foundation

/// 官方预警取数协议（测试注入 Stub 用）。
protocol NmcAlarmProviding: Sendable {
    /// 取回**全国**当前生效的预警列表（调用方自行按城市筛选）。
    ///
    /// - Note: 空数组 = 取数成功且当前无预警；**故障一律抛 `WeatherError`**。
    func fetchAllWarnings(timeZone: TimeZone?) async throws -> [OfficialWarningItem]
}

/// 基于中国气象局（NMC）公开预警接口的取数实现。
actor NmcAlarmService: NmcAlarmProviding {

    private let session: URLSession

    /// 初始化。
    /// - Parameter session: 可注入的 URLSession（测试传自定义 configuration）。
    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 取回全国预警列表。
    ///
    /// - Parameter timeZone: 发布地时区（注入；nil → `issuedAt` 全为 nil）。
    /// - Returns: 条目数组（空 = 取数成功且当前无预警）。
    /// - Throws: `WeatherError`（真故障路径；见文件头契约）。
    func fetchAllWarnings(timeZone: TimeZone?) async throws -> [OfficialWarningItem] {
        guard let url = NmcAlarmEndpoint.url() else {
            throw WeatherError.badURL
        }

        let data: Data
        let response: URLResponse
        do {
            // ⚠️ 实测 NMC 免 Referer、无需凭据 → 用最简的 `data(from:)`。
            (data, response) = try await session.data(from: url)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw WeatherError.timeout(urlError.localizedDescription)
        } catch {
            throw WeatherError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw WeatherError.network("非HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            // EV-3：非 2xx 透传状态码（由协调器裁定 auth / rateLimit）。
            throw WeatherError.badStatus(http.statusCode)
        }

        // 统一解码入口：失败携带 codingPath（可诊断性），**不静默**。
        let dto = try ResponseDecoding.decode(NmcAlarmResponse.self, from: data)

        // mapper 逐层兜住缺块 / 空数组 / null 元素 —— 全部回空数组。
        return NmcAlarmMapper.map(dto, timeZone: timeZone)
    }
}
//
//  WeatherCnAlarmProviding.swift
//  Core / Networking  [App + Widget 共用]
//
//  第七源取数：协议 + actor 实现，形状镜像 `NmcAlarmProviding`
//  （同为「预警链路」，故取同一形状；预警不在 `WeatherFieldKey` 域内，
//  且是**列表** → 不套`FieldSupplying`，理由见 `NmcAlarmProviding` 文件头）。
//
//  ═══════════════════════════════════════════════════════════════════════
// 实测约束（决定了本文件的实现形状，**不是**过度设计）
// ═══════════════════════════════════════════════════════════════════════
//  ① **必须串行 + 必须带间隔**：实测详情端点**限频较严** ——
//     连发 6~8 个不同 file → 全部连接失败（curl code **000**，
//     注意这**不是 HTTP 状态码**，是传输层被断，别误读成"服务端错误"）；
//     冷却 ~90 s 后单发 → 200；冷却后以 **10 s 间隔**连发 3 次 → 200/200/200。
//     → 故本actor 用 **串行循环 + 固定间隔**，**绝不**并发
//     （并发在此端点 = 大面积取不到数据）。
//     ⚠️ 冷却时长与精确阈值**无法确定**（未做二分探测），
//     故 `detailInterval` 取**实测安全值** 10 s，不声称是最优值。
//  ② **必须带 Referer**（实测：无 / 他域 → 403；weather.com.cn 域 → 200）。
//     ⚠️ 这是**伪装 Referer**，如实记录在案（见端点文件头的许可声明）。
//  ③ **返回空数组 ≠ 成功**：与 NMC 源同款契约 —— 空数组只表示
//     "取数成功且当前**没有**该 alertid 的详情"；故障一律抛 `WeatherError`。
//     调用方据此区分「没有预警」(`.none`) 与「取不到」(`.stale`)。
//
//  ── 为什么不把列表与详情合成一次请求 ────────────────────────────────────
//  实测列表端点**只给文件名**（`data[i][1]`），正文在详情端点；
//  而详情端点**限频严**（见①）。若"列表 → 逐条取详情"对**全国**预警
//  全量拉取，实测 137 条 × 10 s ≈ **23 分钟**，且必然触发限频。
//  → 故本文件**只取调用方点名的那几条**（通常是**本城市命中的 0~ 数条**），
//    由调用方先按城市筛NMC 列表、再只对命中条目取详情。
//    这是**架构上的必然**，不是省事。
//
//  Core 纪律：仅 import Foundation；禁 UIKit / Date() / try! / fatalError。
//

import Foundation

/// 第七源取数协议（测试注入 Stub 用）。
protocol WeatherCnAlarmProviding: Sendable {

    /// 取回**指定 alertid 列表**的结构化详情（键值对）。
    ///
    /// - Parameters:
    ///   - alertIDs: 由 `OfficialWarningItem.id`（即 NMC `alertid`）组成的
    ///     连接键列表。**空数组 → 立即返回空字典，不发任何请求**。
    /// - Returns: `alertid` → 详情。某条取失败**不**影响其余条目
    ///   （该键直接不出现在结果里 —— 缺失就是缺失，绝不用假值填）。
    /// - Note: 整体网络失败 → 抛 `WeatherError`（区别于"部分条目缺失"）。
    func fetchDetails(forAlertIDs alertIDs: [String]) async throws -> [String: WeatherCnAlarmDetail]
}

/// 基于 `weather.com.cn` 公开预警接口的取数实现（**串行 + 带间隔**）。
actor WeatherCnAlarmService: WeatherCnAlarmProviding {

    private let session: URLSession

    /// ⚠️ 实测限频安全间隔（实测值；**非最优值**，见类型注释）。
    private static let detailInterval: UInt64 = 10_000_000  // 10 s（纳秒）

    /// 初始化。
    /// - Parameter session: 可注入的 URLSession（测试传自定义 configuration）。
    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 依次取回若干条预警详情（**严格串行**，每条之间有间隔）。
    ///
    /// - Parameter alertIDs: 连接键列表（通常是本城市命中的几条）。
    /// - Returns: `alertid` → 详情（失败的键**缺席**，不用假值填）。
    /// - Throws: `WeatherError`（仅在**列表端点**这一类整体故障时抛出）。
    func fetchDetails(forAlertIDs alertIDs: [String]) async throws -> [String: WeatherCnAlarmDetail] {

        //⚠️ 去重 + 剔除空串：**同一个 alertid 取两次**既浪费又会撞限频。
        var unique: [String] = []
        for id in alertIDs where !id.isEmpty && !unique.contains(id) {
            unique.append(id)
        }
        guard !unique.isEmpty else { return [:] }

        // ① 先取列表，拿到 alertid → 详情文件名 的映射。
        //    实测列表端点**免 Referer**、无可观测限频，且与详情端点
        //    是**不同主机**（forecast. vs product.）→ 限频各自独立。
        let filenameByAlertID = try await fetchFilenameIndex()

        var result: [String: WeatherCnAlarmDetail] = [:]
        // ② 串行逐条取详情。⚠️ `for ... in unique` + `await` 天然串行，
        //    这里**绝不能**改成 `withTaskGroup`（并发 = 大面积失败）。
        var fetchedCount = 0
        for alertID in unique {
            guard let filename = filenameByAlertID[alertID] else {
                // 该 alertid 在列表里没有 → 无详情可取（如 d1 独有的预警）。
                // 跳过（**不**算故障），如实缺席。
                continue
            }
            // 间隔放在"两次请求之间"：第 1 条之前**不**等（无需空等10 s）。
            if fetchedCount > 0 {
                try? await Task.sleep(nanoseconds: Self.detailInterval)
            }
            if let detail = await fetchDetail(filename: filename) {
                result[alertID] = detail
            }
            fetchedCount += 1
        }
        return result
    }

    // MARK: - Private

    /// 取列表，建`alertid` → 详情文件名 的索引。
    ///
    /// - Throws: `WeatherError`（URL 拼装失败 / 非 2xx / 传输失败 / 解码失败）。
    private func fetchFilenameIndex() async throws -> [String: String] {

        guard let url = WeatherCnAlarmEndpoint.listURL() else {
            throw WeatherError.badURL
        }
        let data = try await fetchData(from: url, referer: nil)

        // ⚠️ 列表端点实测 `content-type` 是 `text/html` 但**体是 JSON**
        //→ 故不依据 content-type 判定，直接尝试 JSON 解码。
        let dto = try ResponseDecoding.decode(WeatherCnAlarmListResponse.self, from: data)

        var index: [String: String] = [:]
        for row in dto.result?.data ?? [] {
            // 两键都齐才入索引：缺 alertid 无从连接，缺 filename 无从请求。
            // ⚠️ 不做"用 title 反查"的兜底 —— 那会引入不确定的匹配。
            guard let alertID = row.alertID, !alertID.isEmpty,
                  let filename = row.filename, !filename.isEmpty else { continue }
            // ⚠️ 重复 alertID 时**保留首次出现**：与列表顺序一致，行为可预期。
            if index[alertID] == nil {
                index[alertID] = filename
            }
        }
        return index
    }

    /// 取单条详情（失败返回 nil，**不抛错** —— 单条缺失不该让整批失败）。
    private func fetchDetail(filename: String) async -> WeatherCnAlarmDetail? {
        guard let url = WeatherCnAlarmEndpoint.detailURL(filename: filename) else { return nil }
        // ⚠️ Referer 是**硬要求**（实测无 / 他域均403）→ 这里传常量。
        guard let data = try? await fetchData(from: url,
                                              referer: WeatherCnAlarmEndpoint.requiredRefererValue)
        else { return nil }
        // ⚠️ 响应是 **JSONP**（实测 `var alarminfo={…};`）→ 必须剥壳。
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return WeatherCnAlarmDetail.decode(jsonpText: text)
    }

    /// 统一请求：注入 Referer → 取字节（非 2xx / 传输失败 → 抛）。
    ///
    /// - Parameter referer: 传 nil 表示**不带** Referer（列表端点实测免 Referer）。
    private func fetchData(from url: URL, referer: String?) async throws -> Data {

        var request = URLRequest(url: url)
        // 详情端点实测带浏览器 UA 亦可（未测无 UA）→ 这里**不伪装 UA**：
        // 伪装 UA 属于"让服务端以为我是浏览器"，与 Referer 同性质，
        // 已由端点文件头的许可声明覆盖，此处不额外增加。
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw WeatherError.timeout(urlError.localizedDescription)
        } catch {
            throw WeatherError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw WeatherError.network("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            // ⚠️ 实测 403 在本通道有两种**含义相反**的成因：
            //    详情端点 403 = **Referer 不对**（不是"缺 Key"、不是 IP 封禁）。
            //    故这里只透传状态码交由上层裁定，**不**在注释里断言成因。
            throw WeatherError.badStatus(http.statusCode)
        }
        return data
    }
}
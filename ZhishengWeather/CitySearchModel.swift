//
//  CitySearchModel.swift
//  ZhishengWeather（主 App target）
//
//  F-B 搜索页状态机：防抖 + 请求代际号 + 四态（idle/results/empty/failure）。
//
//  竞态裁定（ARCH-FB §2.6，AC-B18）：**请求代际号 + 300ms 防抖，不用 Task 取消**。
//  流程：queryChanged → 取消旧防抖 Task → 新 Task { sleep 300ms; performSearch }；
//  performSearch 内 `generation += 1`、记 token，响应回来后**仅当 token == generation
//  才写 phase** —— 晚到的过期响应被纯状态比较丢弃。
//
//  不用 Task 取消的理由（写入实现供后续维护遵循）：
//  1. 协作式取消对已飞行中的 URLSession 响应不保证按时中断，晚到响应仍可能闯入渲染；
//  2. 取消以 CancellationError 落进 catch，与真实网络失败混在同一路径；
//  3. 代际号是纯状态比较，Fake provider 下可确定性构造与断言（AC-B18 单测基础）。
//  （防抖 Task 自身的取消是安全的：只取消我们自己的 sleep。）
//
//  结构隔离（T05 验收要点）：**不持有城市目录引用** —— 搜索失败不可能影响列表。
//

import Foundation
import Observation

/// 城市搜索页状态机。
@MainActor
@Observable
final class CitySearchModel {

    /// 搜索页四态。
    enum Phase: Equatable {
        /// 未输入。
        case idle
        /// 搜索中。
        case loading
        /// 有结果。
        case results([City])
        /// 无命中（≠ 网络失败，AC-B19："未找到匹配城市"）。
        case empty
        /// 网络/服务失败（AC-B17："网络不可用，搜索失败" + 重试）。
        case failure
    }

    /// 当前阶段。
    private(set) var phase: Phase = .idle

    private let provider: GeocodingProviding
    /// 防抖间隔（生产 0.3s；测试注入近 0，保证可单测）。
    private let debounceSeconds: Double
    /// 防抖任务（仅承载 sleep → performSearch 的调度）。
    private var debounceTask: Task<Void, Never>?
    /// 请求代际号（AC-B18）：每次 performSearch 自增；响应凭 token 比对。
    private var generation = 0
    /// 最近一次非空 query（retry 用）。
    private var lastQuery: String = ""

    /// 初始化。
    /// - Parameters:
    ///   - provider: 搜索提供者（生产传 `GeocodingService()`，测试传 Fake）。
    ///   - debounceSeconds: 防抖间隔秒数；默认 0.3（AC-B21）。
    init(provider: GeocodingProviding, debounceSeconds: Double = 0.3) {
        self.provider = provider
        self.debounceSeconds = debounceSeconds
    }

    // MARK: - 输入入口

    /// 输入变化：重置防抖任务。空白输入回 idle。
    /// - Parameter text: 输入框当前文本。
    func queryChanged(_ text: String) {
        debounceTask?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastQuery = ""
            phase = .idle
            return
        }
        lastQuery = trimmed

        // 防抖：值捕获（debounce/trimmed 均为不可变值），Task 内不强持有 self。
        let debounce = debounceSeconds
        debounceTask = Task { [weak self, debounce, trimmed] in
            if debounce > 0 {
                try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.performSearch(trimmed)
        }
    }

    /// 重试（AC-B17）：用最近一次非空 query，立即执行（不再防抖）。
    func retry() {
        guard !lastQuery.isEmpty else { return }
        debounceTask?.cancel()
        Task { await self.performSearch(lastQuery) }
    }

    // MARK: - 搜索执行（代际号裁定）

    /// 执行一次搜索。并发进入时以代际号保证"只有最新一次"能写 phase。
    /// - Parameter name: 已修剪的城市名。
    private func performSearch(_ name: String) async {
        generation += 1
        let token = generation
        phase = .loading

        do {
            let cities = try await provider.search(name: name)
            // AC-B18：过期响应丢弃 —— 晚到的前序请求不得覆盖最新结果。
            guard token == generation else { return }
            phase = cities.isEmpty ? .empty : .results(cities)
        } catch {
            // 过期请求的失败同样丢弃（避免旧失败的 failure 覆盖新请求的 loading/results）。
            guard token == generation else { return }
            phase = .failure
        }
    }
}

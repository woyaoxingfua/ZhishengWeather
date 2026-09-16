//
//  ResponseDecoding.swift
//  Core / Networking  [App + Widget 共用]
//
//  统一的响应解码入口（五条链路共用）。
//
//  为什么必须有它（docs/handover/review-2026-09-16-run37.md §1/§3 事故复盘）：
//  旧代码在 `catch` 里只抛 `error.localizedDescription` —— 中文设备上就是
//  「由于数据格式有问题，无法读取该数据」这句话，**丢掉了 `codingPath`
//  （到底是哪个字段解不出来）与 `debugDescription`**。run37 那次真机事故
//  （sunrise/sunset 收到 epoch 整数、DTO 却声明 ISO 字符串）就是因为这条线索
//  被丢掉，只能靠截图问人，排查成本极高。
//
//  本入口做两件事（缺一不可）：
//    1. 把 `DecodingError.codingPath` + `debugDescription` **保留进错误**
//       （`WeatherError.decodingDetail`），使其一路可达 UI 与断言层；
//    2. 以 `privacy: .public` 写 `os.Logger`，真机可捞（不被脱敏成 <private>）。
//
//  Core 纪律：仅 import Foundation（`os` 已随 WeatherLog 例外引入）；
//  禁 UIKit / try! / fatalError。
//

import Foundation

/// 统一的 JSON 解码入口。
enum ResponseDecoding {

    /// 解码并**归一失败**：成功返回 DTO；失败抛 `WeatherError.decodingDetail`。
    ///
    /// 失败时两份信息都会被保留：错误里带 `path` / `debugDescription`，
    /// 日志里以 public 权限打全（真机排障可达）。
    /// - Parameters:
    ///   - type: 目标 DTO 类型。
    ///   - data: 原始响应字节。
    /// - Returns: 解码得到的 DTO。
    /// - Throws: `WeatherError.decodingDetail`（始终携带字段路径，可能为空串）。
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let decodingError as DecodingError {
            let described = describe(decodingError)
            WeatherLog.decode.error(
                "解码 \(String(describing: type), privacy: .public) 失败 path=\(described.path, privacy: .public) detail=\(described.debugDescription, privacy: .public)")
            throw WeatherError.decodingDetail(path: described.path,
                                              debugDescription: described.debugDescription)
        } catch {
            // 非 DecodingError（极少见）——仍收敛为同一错误类型，不泄露原始类型。
            WeatherLog.decode.error(
                "解码 \(String(describing: type), privacy: .public) 失败 detail=\(error.localizedDescription, privacy: .public)")
            throw WeatherError.decodingDetail(path: "",
                                              debugDescription: error.localizedDescription)
        }
    }

    /// `DecodingError` → (codingPath 点号串, debugDescription)。
    ///
    /// 纯函数（无 IO / 无日志），供错误分类与单测复用。
    /// - Parameter error: 解码错误。
    /// - Returns: `path` 为 codingPath 各分量以 "." 连接的串（根级 → 空串）；
    ///   `debugDescription` 为上游调试卷提供的描述。
    static func describe(_ error: DecodingError) -> (path: String, debugDescription: String) {
        let context: DecodingError.Context
        switch error {
        case .typeMismatch(_, let ctx):
            context = ctx
        case .valueNotFound(_, let ctx):
            context = ctx
        case .keyNotFound(_, let ctx):
            context = ctx
        case .dataCorrupted(let ctx):
            context = ctx
        default:
            return ("", error.localizedDescription)
        }
        let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
        return (path, context.debugDescription)
    }
}

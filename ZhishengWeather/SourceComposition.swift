//
//  SourceComposition.swift
//  ZhishengWeather（主 App target）
//
//  多源组装点（composition root，ARCH §3.3）。
//
//  将来接第三个源 = 新增一个 FieldSupplying 文件 + 在此 append 一行，
//  其余调用点（VM / 设置页 / 降级解析器）零改动。
//
//  注：本文件在 App target（不参与 Widget 编译），与「Widget 取数源不变」
//  的边界一致（ARCH §6）。
//

import Foundation

/// 多源组装点。
enum SourceComposition {

    /// 本轮组装：一个能力型辅助源（sunrise-sunset）。
    ///
    /// - Returns: 辅助源列表（装进注册表 / 协调器）。
    static func makeAuxiliarySources() -> [any FieldSupplying] {
        [SunriseSunsetService()]
    }

    /// 构造按能力查找的注册表（主源不在 FieldSupplying 体系，此处仅列辅助源）。
    static func makeRegistry() -> FieldSourceRegistry {
        let auxiliary = makeAuxiliarySources()
        let dataFieldSources: [any DataFieldSource] = auxiliary.map { $0 as any DataFieldSource }
        return FieldSourceRegistry(sources: dataFieldSources)
    }
}

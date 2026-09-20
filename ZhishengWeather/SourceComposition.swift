//
//  SourceComposition.swift
//  ZhishengWeather（主 App target）
//
//  多源组装点（composition root，ARCH §3.3）。
//
//  ── T10 变更（ARCH-T10 §3.5 / §9.2）────────────────────────────────────────
//  接入一个新源的真实改动面已收敛为：
//    1．源的 endpoint / DTO / mapper / service 四件套（每个源固有）；
//    2．`Core/Logic/SourceDescriptor.swift` 的 `SourceDirectory.all` 加**一项声明**
//       （目录 / 自动摘除开关 / 设置页停用入口都由它派生）；
//    3．**本文件** append 一行（把该源实例化）。
//  ⚠️ 第 2 步**不可省**：漏了它，该源不会出现在设置页、自动摘除也查不到它的行为标记。
//  另注：核心容器（`FieldPatch` / `FieldFallbackResolver` / EV-1 判缺）**不再需要**
//  为每个新字段改动 —— 字段是值容器里的数据，不是代码分支。
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

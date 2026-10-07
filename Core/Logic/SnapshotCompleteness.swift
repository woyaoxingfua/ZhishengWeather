//
//  SnapshotCompleteness.swift
//  Core / Logic  [App + Widget 共用]
//
//  快照「实质是否为空」的纯判定（用于「请求的城市无数据」故障域）。
//
//  为什么单独成文件而非写成 `WeatherSnapshot` 的成员：本项目纪律要求任何
//  有分支语义的判定都在 Core 里可被纯单测覆盖（CI-pitfalls P-18 同源盲区），
//  独立小类型便于直接喂各种边界组合做断言。
//

import Foundation

/// 快照完整性判定（纯函数）。
enum SnapshotCompleteness {

    /// 快照是否**实质无数据**：既无逐小时序列，也无逐日预报。
    ///
    /// 语义：Open-Meteo 对有效坐标总会返回 `hourly`；若两者皆空，说明该坐标
    /// 拿不到任何预报时间线 —— 归为「数据缺失」而非「解码成功」。
    /// 注：实况（`current`）在 DTO 里是非可选字段，缺了会先在解码阶段失败，
    /// 故此处不需重复检查。
    /// - Parameter snapshot: 映射后的领域快照。
    /// - Returns: 无逐小时且无逐日 → true。
    static func isEffectivelyEmpty(_ snapshot: WeatherSnapshot) -> Bool {
        if !snapshot.hourly.isEmpty { return false }
        if let daily = snapshot.daily, !daily.isEmpty { return false }
        return true
    }

    // MARK: - 独立链路（同一条判据的另两个域）

    /// ⚠️ 为什么下面两个是**重载**而不是各模型的 `isEffectivelyEmpty` 属性：
    /// 「解码成功但实质无数据」这条判据在本仓库只应有一处权威（就是这个类型）。
    /// 若让每个模型自带一个 `isEffectivelyEmpty`，就会变成 N 份各自实现的同名判据
    /// —— 那正是本文件存在的理由所要消灭的东西（各写一份 → 各自漂移 → 静默）。
    /// 故 marine / flood 的判定也收敛到这里，与天气快照那一份**并列可见**。

    /// 海浪要素是否**实质无数据**：六个要素全为 nil。
    ///
    /// ⚠️ 这一层**必需**，因为 marine 端点对**内陆坐标返回 HTTP 200 + 全 null**
    /// （实测北京 39.9,116.4 三项全 null）——那是**成功响应**，解码不会失败、
    /// 不会走 `WeatherError` 路径。若缺这一层判定，UI 会把"没有数据"当成
    /// "浪高 0 m / 海面平静"画出来 —— 那是在**凭空造一个假的平静海面**。
    ///
    /// 判据：六项**全部**为 nil。只要有任一项有值就保留（部分缺测是如实的，
    /// 缺口要展示出来，而不是整张卡藏掉）。
    ///
    /// ⚠️ `0`（无浪）是**合法读数**，不是缺失 —— 故判据是「是否为 nil」而非
    /// 「是否为零」，真静水时本判据返回 false，卡片照常显示"浪高 0 m"。
    ///
    /// - Parameter conditions: 映射后的海浪领域模型。
    /// - Returns: 六项皆 nil → true。
    static func isEffectivelyEmpty(_ conditions: MarineConditions) -> Bool {
        conditions.waveHeight == nil
            && conditions.waveDirection == nil
            && conditions.wavePeriod == nil
            && conditions.swellWaveHeight == nil
            && conditions.swellWaveDirection == nil
            && conditions.swellWavePeriod == nil
    }

    /// 河道流量是否**实质无数据**：序列为空，**或**序列里没有一个非 nil 的流量值。
    ///
    /// ⚠️ flood 端点上「整块静默省略」是**实测存在**的形态：变量名在全局词表
    /// 存在、但该端点不支持时，返回 HTTP 200 且**无 `daily` 键**。此时解码成功、
    /// 序列为空，不判定就会被当成"全为 0"。
    ///
    /// ⚠️ 反向的坑同样要防：实测乌鲁木齐 (43.8,87.6) 断流时返回的是
    /// **`[0.00, 0.00, 0.00]`** —— 有键、有值、值为零。那是**真实的断流读数**，
    /// 不是"没查到"。故本判据是"**有没有非 nil 的值**"，**不是**"值是否全为零"：
    /// 全 0 的序列判为**有数据**（如实显示断流），把断流说成缺测是另一种谎报。
    ///
    /// - Parameter discharge: 映射后的河道流量领域模型。
    /// - Returns: 无任何非 nil 流量值 → true。
    static func isEffectivelyEmpty(_ discharge: RiverDischarge) -> Bool {
        !discharge.daily.contains { $0.cubicMetresPerSecond != nil }
    }

    /// 潮汐是否**实质无数据**：序列里没有一个点带天文潮分量。
    ///
    /// ⚠️ 判据是「**有没有非 nil 的天文潮分量**」而非「序列是否为空」：
    ///   实测内陆坐标（北京 39.90,116.41/ 成都 30.57,104.07 / 乌鲁木齐 43.83,87.62）
    ///   以及上海 / 天津 / 杭州 / 广州，返回的是
    ///   **HTTP 200 + `minutely_15` 键在+ 长度 672 正常 + 元素全 null**。
    ///   只判"空数组"会把那种响应当成有效数据，画出一条
    ///   **"潮高恒为 0 m" 的假平直线** —— 那是在凭空造一片静止海面。
    ///
    /// ⚠️ 同 flood 判据的坑：这里也**不能**用"值是否为零"作判据 ——
    ///   潮高 `0.00 m` 是**合法读数**（天文潮恰好过平均海平面），
    ///   把"恰好为 0"说成"缺测"是另一种谎报。
    ///
    /// - Parameter forecast: 映射后的潮汐领域模型。
    /// - Returns: 无任何非 nil 天文潮分量 → true。
    static func isEffectivelyEmpty(_ forecast: TideForecast) -> Bool {
        !forecast.points.contains { $0.astronomical != nil }
    }
}

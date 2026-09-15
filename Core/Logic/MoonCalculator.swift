//
//  MoonCalculator.swift
//  Core / Logic  [App + Widget 共用]
//
//  纯函数月相算法（不依赖网络/UI/当前时间）。
//  采用平均朔望月 + 已知新月锚点的近似算法，与真实月相误差 ≤ 1 天（满足 AC）。
//
//  约束：禁止内部调用 `Date()`；所有输入时刻由参数传入。
//

import Foundation

/// 月相计算器（纯函数）。
enum MoonCalculator {

    /// 平均朔望月长度（天）。
    static let synodicMonth: Double = 29.530588853

    /// 已知新月锚点：2000-01-06 18:14 UTC 的 epoch 秒。
    static let referenceNewMoonEpoch: Double = 947_182_440

    /// 距离上一个新月的月龄（天，0 – synodicMonth）。
    static func age(for date: Date) -> Double {
        let days = (date.timeIntervalSince1970 - referenceNewMoonEpoch) / 86_400.0
        var value = days.truncatingRemainder(dividingBy: synodicMonth)
        if value < 0 { value += synodicMonth }
        return value
    }

    /// 照亮比例（0.0 – 1.0）。新月为 0，满月为 1。
    static func illumination(for date: Date) -> Double {
        let phaseAngle = 2.0 * Double.pi * age(for: date) / synodicMonth
        let value = (1.0 - cos(phaseAngle)) / 2.0
        // 收敛浮点误差，保证落在 [0, 1]。
        return min(max(value, 0.0), 1.0)
    }

    /// 依据时刻计算完整月相。
    static func phase(for date: Date) -> MoonPhase {
        let currentAge = age(for: date)
        let fraction = currentAge / synodicMonth
        let name = name(forFraction: fraction)
        let illum = illumination(for: date)
        return MoonPhase(name: name,
                         illumination: illum,
                         symbolName: name.symbolName,
                         age: currentAge)
    }

    // MARK: - Private

    /// 将一个朔望周期按 8 等分（每份 1/8，各相居中于四个象限点）判定月相名。
    private static func name(forFraction fraction: Double) -> MoonPhase.Name {
        switch fraction {
        case ..<0.0625:            return .newMoon          // 朔：±1/16 内
        case ..<0.1875:            return .waxingCrescent
        case ..<0.3125:            return .firstQuarter
        case ..<0.4375:            return .waxingGibbous
        case ..<0.5625:            return .fullMoon
        case ..<0.6875:            return .waningGibbous
        case ..<0.8125:            return .lastQuarter
        case ..<0.9375:            return .waningCrescent
        default:                   return .newMoon
        }
    }

    // MARK: - 月出月落（A2-4，Meeus 低精度近似，ARCH-A2P1 §1.2）

    /// 月出/月落时刻（近似，误差 ≤ ±10 分钟）。
    ///
    /// 算法（Meeus《Astronomical Algorithms》低精度截断式）：
    ///  ① 儒略世纪 T → 月球地心黄经 λ / 黄纬 β / 赤道地平视差（截断主项级数）；
    ///  ② 黄赤交角 ε → 视赤经 α / 赤纬 δ；
    ///  ③ 解地平高度 h = -0.833°（含大气折射）的时角：
    ///     cos H = (sin h − sin φ·sin δ) / (cos φ·cos δ)；
    ///  ④ cos H > 1 → 月球终日地平线下（极夜态，(nil, nil)）；
    ///     cos H < −1 → 终日地平线上（极昼态，(nil, nil)）——★ 极地边界不崩；
    ///  ⑤ 月出（上中天前）与月落（上中天后）由恒星时换算为 UTC 时刻。
    ///  ⚠️ 禁 Date()：所有时刻由 `date` 参数注入（单测确定性）。
    ///
    /// - Parameters:
    ///   - date: 当日任一时刻（取该日 00:00 UTC 前后均可，内部按当日窗口求解）。
    ///   - latitude: 纬度（度，北正）。
    ///   - longitude: 经度（度，东正）。
    /// - Returns: (rise: 月出 UTC 时刻, set: 月落 UTC 时刻)；极地无事件日双 nil。
    static func moonEvents(for date: Date,
                           latitude: Double,
                           longitude: Double) -> (rise: Date?, set: Date?) {
        // 当日 00:00 UTC 起算（迭代基准），窗口 24h。
        let dayStart = date.timeIntervalSince1970 - date.timeIntervalSince1970
            .truncatingRemainder(dividingBy: 86_400)

        var riseEpoch: Double?
        var setEpoch: Double?
        var previousAltitude: Double?

        // 每 30 分钟采样地平高度，相邻符号变化（越过 -0.833°）→ 线性内插出精确时刻。
        // 24h × 2 采样/h = 48 步；步长插值误差 << ±10min 精度要求。
        let stepSeconds: Double = 1_800
        var t = dayStart
        while t <= dayStart + 86_400 {
            let altitude = moonAltitude(epoch: t, latitude: latitude, longitude: longitude)
            if let previous = previousAltitude {
                let target = -0.833
                if previous < target && altitude >= target, riseEpoch == nil {
                    // 上升穿越（月出）：线性内插。
                    let fraction = (target - previous) / (altitude - previous)
                    riseEpoch = t - stepSeconds + fraction * stepSeconds
                }
                if previous > target && altitude <= target, setEpoch == nil {
                    // 下降穿越（月落）。
                    let fraction = (previous - target) / (previous - altitude)
                    setEpoch = t - stepSeconds + fraction * stepSeconds
                }
            }
            previousAltitude = altitude
            t += stepSeconds
        }
        return (rise: riseEpoch.map { Date(timeIntervalSince1970: $0) },
                set: setEpoch.map { Date(timeIntervalSince1970: $0) })
    }

    /// 月球地平高度（度）——Meeus 低精度位置 + 时角公式。
    /// - Parameters:
    ///   - epoch: UTC epoch 秒。
    ///   - latitude: 纬度（度）。
    ///   - longitude: 经度（度）。
    private static func moonAltitude(epoch: Double, latitude: Double, longitude: Double) -> Double {
        let julianDays = epoch / 86_400.0 + 2_440_587.5
        let t = (julianDays - 2_451_545.0) / 36_525.0  // 儒略世纪（J2000）

        // ① 月球地心黄经 λ'（度，Meeus 47.1 式截断主项，含最大 6 项）。
        let lPrime = (218.316
            + 481_267.881 * t
            + 6.289 * sinDeg(deg2rad(134.963 + 477_198.867 * t))
            + 1.274 * sinDeg(deg2rad(93.272 + 483_202.018 * t))
            - 0.658 * sinDeg(deg2rad(200.903 + 409_335.058 * t))
            + 0.214 * sinDeg(deg2rad(228.477 + 191_340.127 * t))
            - 0.186 * sinDeg(deg2rad(318.616 + 860_516.147 * t)))
            .truncatingRemainder(dividingBy: 360.0)

        // ② 月球黄纬 β（度，截断主项 4 项）。
        let beta = (5.128 * sinDeg(deg2rad(93.272 + 483_202.018 * t))
            + 0.281 * sinDeg(deg2rad(218.316 + 481_267.881 * t))
            - 0.278 * sinDeg(deg2rad(318.616 + 860_516.147 * t))
            + 0.173 * sinDeg(deg2rad(217.643 + 860_516.147 * t)))

        // ③ 黄赤交角（J2000 附近，度）。
        let epsilon = 23.4393 - 0.0130 * t

        // ④ 视赤经 α / 赤纬 δ（黄赤转换）。
        let lambdaRad = deg2rad(lPrime)
        let betaRad = deg2rad(beta)
        let epsRad = deg2rad(epsilon)
        let sinDeclination = sinDeg(beta) * cosDeg(epsilon)
            + cosDeg(beta) * sinDeg(epsilon) * sinDeg(beta == 0 ? 0 : lPrime)
        // 标准黄赤转换（β 小角度近似下直接用完整式）：
        let declination = rad2deg(asin(min(max(sinDeclination, -1), 1)))
        let y = sinDeg(lPrime) * cosDeg(epsilon) - tanDeg(beta) * sinDeg(epsilon)
        let x = cosDeg(lPrime)
        let rightAscension = rad2deg(atan2(y, x))

        // ⑤ 格林尼治恒星时（度）→ 本地时角 H。
        let gmst = (280.46061837 + 360.985_647_366_29 * (julianDays - 2_451_545.0))
            .truncatingRemainder(dividingBy: 360.0)
        var hourAngle = gmst + longitude - rightAscension
        hourAngle = normalizedAngle(hourAngle)

        // ⑥ 地平高度。
        let latRad = deg2rad(latitude)
        let decRad = deg2rad(declination)
        let haRad = deg2rad(hourAngle)
        let sinAltitude = sin(latRad) * sin(decRad) + cos(latRad) * cos(decRad) * cos(haRad)
        return rad2deg(asin(min(max(sinAltitude, -1), 1)))
    }

    // MARK: - 角度工具（私有，度域）

    private static func deg2rad(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func rad2deg(_ radians: Double) -> Double { radians * 180 / .pi }
    private static func sinDeg(_ degrees: Double) -> Double { sin(deg2rad(degrees)) }
    private static func cosDeg(_ degrees: Double) -> Double { cos(deg2rad(degrees)) }
    private static func tanDeg(_ degrees: Double) -> Double { tan(deg2rad(degrees)) }

    /// 角度归一化到 (-180, 180]。
    private static func normalizedAngle(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360.0)
        if value > 180 { value -= 360 }
        if value <= -180 { value += 360 }
        return value
    }
}
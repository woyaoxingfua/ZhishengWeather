//
//  LocationProvider.swift
//  ZhishengWeather（主 App target）
//
//  CoreLocation 封装：请求「使用期间」授权 → 取坐标 → 失败/拒绝/超时回落北京。
//  双超时：等用户在授权弹窗作答 60s（authorizationTimeout）、已授权后等定位结果 5s
//  （locationTimeout）；绝不循环弹窗、绝不崩溃。
//

import Foundation
import CoreLocation

@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {

    /// 最近一次解析到的位置（默认北京）。
    private(set) var current: LocationInfo = .beijing

    /// 最近一次定位请求的**结果分类**（本轮新增）。
    ///
    /// 定位层只如实记录事实；「要不要提示用户」由 Core 的
    /// `FaultDomain.classify(locationOutcome:)` 纯裁定（可单测）。
    private(set) var lastOutcome: LocationOutcome = .authorized

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<LocationInfo, Never>?
    private var timeoutTask: Task<Void, Never>?

    /// 已授权后等待一次定位结果的超时（秒）。正常 <1s 返回，5s 足够。
    private let locationTimeout: TimeInterval = 5

    /// 等待用户在授权弹窗上作答的超时（秒）。
    /// 用户读弹窗常常超过 5 秒，故给足余量；授权结果无论如何都会经
    /// `locationManagerDidChangeAuthorization` 回调，该超时只是「用户始终未作答」的兜底网。
    private let authorizationTimeout: TimeInterval = 60

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// 请求一次位置；授权被拒 / 失败 / 超时均回落 `.beijing`，保证不挂起。
    ///
    /// 三条互斥路径（避免首次启动恒回落北京）：
    /// - 已拒绝 / 受限：直接返回北京；
    /// - 未决定：**只弹授权窗、不请求定位**（此刻请求必然 kCLErrorDenied，
    ///   会提前消费 continuation）；真正的定位由
    ///   `locationManagerDidChangeAuthorization` 的已授权分支发起；
    /// - 已授权：直接请求定位。
    func requestLocation() async -> LocationInfo {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            current = .beijing
            lastOutcome = .denied
            return .beijing

        case .notDetermined:
            // 仅触发授权弹窗。此刻调用 requestLocation() 必然失败（kCLErrorDenied），
            // 会提前消费 continuation，导致首次启动恒显示北京。
            // 真正的定位请求由 locationManagerDidChangeAuthorization 的已授权分支发起。
            return await withCheckedContinuation { (continuation: CheckedContinuation<LocationInfo, Never>) in
                self.continuation = continuation
                self.startTimeout(after: self.authorizationTimeout)
                self.manager.requestWhenInUseAuthorization()
            }

        default:
            return await withCheckedContinuation { (continuation: CheckedContinuation<LocationInfo, Never>) in
                self.continuation = continuation
                self.startTimeout(after: self.locationTimeout)
                self.manager.requestLocation()
            }
        }
    }

    // MARK: - Private

    /// 启动单次超时兜底；先取消上一个（防残留任务误触发），被取消时立即退出。
    private func startTimeout(after seconds: TimeInterval) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // 超时 = 用户未作答 / 等不到定位结果 → undetermined（静默回落）。
            self?.finish(with: .beijing, outcome: .undetermined)
        }
    }

    /// 收敛结果：取消超时、记忆当前值与结果分类、恢复等待中的 continuation（幂等）。
    /// - Parameters:
    ///   - info: 解析出的位置。
    ///   - outcome: 本次定位的结果分类（供上层按故障域决定是否提示）。
    private func finish(with info: LocationInfo, outcome: LocationOutcome) {
        timeoutTask?.cancel()
        timeoutTask = nil
        current = info
        lastOutcome = outcome

        if let continuation {
            self.continuation = nil
            continuation.resume(returning: info)
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let info = LocationInfo(name: "当前位置",
                                latitude: last.coordinate.latitude,
                                longitude: last.coordinate.longitude,
                                isFallback: false)
        Task { @MainActor in
            self.finish(with: info, outcome: .authorized)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.finish(with: .beijing, outcome: .failed)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                // 授权刚就绪：把「等用户作答」的长超时换成「等定位结果」的短超时。
                // 仅在确有悬挂的 continuation 时重启 —— delegate 在 init 阶段
                // 就会被回调一次（携带当前授权态），那时不能凭空起超时。
                if self.continuation != nil {
                    self.startTimeout(after: self.locationTimeout)
                }
                manager.requestLocation()
            case .denied, .restricted:
                self.finish(with: .beijing, outcome: .denied)
            default:
                break
            }
        }
    }
}

import CoreMotion
import DarwinHost
import DynamicMotion
import DynamicRuntime
import Foundation
#if os(iOS)
import UIKit
#endif

/// The `MotionManager` contract over `CMMotionManager`.
///
/// Each sensor runs on a `CMMotionManager` of its own, created the first
/// time the sensor starts, so sensors keep independent intervals and
/// reference frames:
///
/// | Sensor | Source |
/// |---|---|
/// | accelerometer | accelerometer updates (raw, gravity included) |
/// | gyroscope | device motion's `rotationRate` (bias-corrected) |
/// | magnetometer | device motion's calibrated `magneticField` in `xArbitraryCorrectedZVertical`; raw magnetometer updates, reported `uncalibrated`, without that frame |
/// | deviceMotion | device motion in `xArbitraryZVertical` |
///
/// Apple recommends one `CMMotionManager` per app, since several can lower
/// the delivered rate; that only matters when a guest runs several sensors
/// at once.
///
/// Handlers run on `OperationQueue.main`. Values are converted as
/// `MotionConversions` describes. On iOS, every running sensor stops with
/// `suspended` when the app enters the background. On macOS no sensor is
/// available and `start` fails with `unavailable`.
public final class DarwinMotionManager: MotionManager {

    /// About 100 Hz, CoreMotion's practical maximum.
    static let minimumInterval: TimeInterval = 0.01

    let delegate: any MotionManagerDelegate

    /// The token of each running sensor's handler. A handler whose token
    /// is no longer here was stopped, and its queued samples are dropped.
    private(set) var running: [MotionSensor: Int] = [:]

    private var nextToken = 0

    #if os(iOS)
    /// For `isAvailable(_:)`. Created on first use.
    nonisolated(unsafe) private static var availability: CMMotionManager?

    private var managers: [MotionSensor: CMMotionManager] = [:]

    private var backgroundObserver: NSObjectProtocol?
    #endif

    init(delegate: any MotionManagerDelegate) {
        self.delegate = delegate
    }

    deinit {
        #if os(iOS)
        for sensor in running.keys {
            managers[sensor].map { Self.stopUpdates(sensor, on: $0) }
        }
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        #endif
    }

    public static func isAvailable(_ sensor: Int32) -> Bool {
        #if os(iOS)
        guard let sensor = MotionSensor(rawValue: sensor) else { return false }
        let manager = availability ?? CMMotionManager()
        availability = manager
        switch sensor {
        case .accelerometer: return manager.isAccelerometerAvailable
        case .gyroscope: return manager.isGyroAvailable
        case .magnetometer: return manager.isMagnetometerAvailable
        case .deviceMotion: return manager.isDeviceMotionAvailable
        }
        #else
        return false
        #endif
    }

    public static func make(_ delegate: any MotionManagerDelegate) -> DarwinMotionManager {
        let manager = DarwinMotionManager(delegate: delegate)
        #if os(iOS)
        manager.backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak manager] _ in
            manager?.suspend()
        }
        #endif
        return manager
    }

    /// Restarts `sensor` if it's running, with the new interval. The
    /// interval is clamped to `minimumInterval(_:)`.
    public func start(_ sensor: Int32, interval: Double) {
        guard let kind = MotionSensor(rawValue: sensor) else {
            AppHost.logger.error("MotionManager.start: unknown sensor \(sensor, privacy: .public)")
            failLater(sensor, .unavailable)
            return
        }
        guard Self.isAvailable(sensor) else {
            failLater(sensor, .unavailable)
            return
        }
        #if os(iOS)
        let interval = Self.clamp(interval)
        let manager = managers[kind] ?? CMMotionManager()
        managers[kind] = manager
        if running[kind] != nil {
            Self.stopUpdates(kind, on: manager)
        }
        nextToken += 1
        let token = nextToken
        running[kind] = token
        startUpdates(kind, on: manager, interval: interval, token: token)
        #endif
    }

    public func stop(_ sensor: Int32) {
        guard let kind = MotionSensor(rawValue: sensor), running.removeValue(forKey: kind) != nil else { return }
        #if os(iOS)
        managers[kind].map { Self.stopUpdates(kind, on: $0) }
        #endif
    }

    public func isActive(_ sensor: Int32) -> Bool {
        MotionSensor(rawValue: sensor).map { running[$0] != nil } ?? false
    }

    public func minimumInterval(_ sensor: Int32) -> Double {
        Self.minimumInterval
    }

    /// An interval in seconds, at least `minimumInterval`. Non-finite or
    /// non-positive intervals become the minimum.
    static func clamp(_ interval: Double) -> TimeInterval {
        guard interval.isFinite else { return minimumInterval }
        return max(interval, minimumInterval)
    }

    // MARK: Failures

    /// Stops `sensor` and reports `error`.
    func fail(_ sensor: Int32, _ error: MotionError) {
        if let kind = MotionSensor(rawValue: sensor), running.removeValue(forKey: kind) != nil {
            #if os(iOS)
            managers[kind].map { Self.stopUpdates(kind, on: $0) }
            #endif
        }
        deliver {
            delegate.didFail(self, sensor: sensor, error: error.rawValue)
        }
    }

    private func failLater(_ sensor: Int32, _ error: MotionError) {
        DispatchQueue.main.async { [weak self] in
            self?.fail(sensor, error)
        }
    }

    /// The app entered the background: every running sensor stops.
    func suspend() {
        for sensor in MotionSensor.allCases where running[sensor] != nil {
            fail(sensor.rawValue, .suspended)
        }
    }

    // MARK: CoreMotion

    #if os(iOS)
    private func isCurrent(_ sensor: MotionSensor, _ token: Int) -> Bool {
        running[sensor] == token
    }

    private func startUpdates(_ sensor: MotionSensor, on manager: CMMotionManager, interval: TimeInterval, token: Int) {
        switch sensor {
        case .accelerometer:
            manager.accelerometerUpdateInterval = interval
            manager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
                guard let self, self.isCurrent(sensor, token) else { return }
                if let error {
                    return self.fail(sensor.rawValue, MotionConversions.reported(error, by: "Accelerometer"))
                }
                guard let data else { return }
                self.sendAcceleration(data.acceleration, timestamp: data.timestamp)
            }
        case .gyroscope:
            manager.deviceMotionUpdateInterval = interval
            manager.startDeviceMotionUpdates(using: Self.frame(.xArbitraryZVertical), to: .main) { [weak self] motion, error in
                guard let self, self.isCurrent(sensor, token) else { return }
                if let error {
                    return self.fail(sensor.rawValue, MotionConversions.reported(error, by: "Gyroscope"))
                }
                guard let motion else { return }
                let rate = motion.rotationRate
                let timestamp = MotionConversions.hostNanoseconds(uptime: motion.timestamp)
                deliver {
                    self.delegate.didUpdateRotationRate(self, x: rate.x, y: rate.y, z: rate.z, timestamp: timestamp)
                }
            }
        case .magnetometer:
            if CMMotionManager.availableAttitudeReferenceFrames().contains(.xArbitraryCorrectedZVertical) {
                manager.deviceMotionUpdateInterval = interval
                manager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: .main) { [weak self] motion, error in
                    guard let self, self.isCurrent(sensor, token) else { return }
                    if let error {
                        return self.fail(sensor.rawValue, MotionConversions.reported(error, by: "Magnetometer"))
                    }
                    guard let motion else { return }
                    let field = motion.magneticField
                    self.sendMagneticField(
                        field.field,
                        accuracy: MotionConversions.magneticFieldAccuracy(field.accuracy.rawValue),
                        timestamp: motion.timestamp
                    )
                }
            } else {
                manager.magnetometerUpdateInterval = interval
                manager.startMagnetometerUpdates(to: .main) { [weak self] data, error in
                    guard let self, self.isCurrent(sensor, token) else { return }
                    if let error {
                        return self.fail(sensor.rawValue, MotionConversions.reported(error, by: "Magnetometer"))
                    }
                    guard let data else { return }
                    self.sendMagneticField(data.magneticField, accuracy: .uncalibrated, timestamp: data.timestamp)
                }
            }
        case .deviceMotion:
            manager.deviceMotionUpdateInterval = interval
            manager.startDeviceMotionUpdates(using: Self.frame(.xArbitraryZVertical), to: .main) { [weak self] motion, error in
                guard let self, self.isCurrent(sensor, token) else { return }
                if let error {
                    return self.fail(sensor.rawValue, MotionConversions.reported(error, by: "Device motion"))
                }
                guard let motion else { return }
                self.sendDeviceMotion(motion)
            }
        }
    }

    private static func stopUpdates(_ sensor: MotionSensor, on manager: CMMotionManager) {
        switch sensor {
        case .accelerometer: manager.stopAccelerometerUpdates()
        case .gyroscope, .deviceMotion: manager.stopDeviceMotionUpdates()
        case .magnetometer:
            manager.stopDeviceMotionUpdates()
            manager.stopMagnetometerUpdates()
        }
    }

    /// `frame` if the device supports it, otherwise the default.
    private static func frame(_ frame: CMAttitudeReferenceFrame) -> CMAttitudeReferenceFrame {
        CMMotionManager.availableAttitudeReferenceFrames().contains(frame) ? frame : []
    }

    private func sendAcceleration(_ g: CMAcceleration, timestamp: TimeInterval) {
        let timestamp = MotionConversions.hostNanoseconds(uptime: timestamp)
        deliver {
            delegate.didUpdateAcceleration(
                self,
                x: MotionConversions.acceleration(g.x),
                y: MotionConversions.acceleration(g.y),
                z: MotionConversions.acceleration(g.z),
                timestamp: timestamp
            )
        }
    }

    private func sendMagneticField(_ field: CMMagneticField, accuracy: MagneticFieldAccuracy, timestamp: TimeInterval) {
        let timestamp = MotionConversions.hostNanoseconds(uptime: timestamp)
        deliver {
            delegate.didUpdateMagneticField(self, x: field.x, y: field.y, z: field.z, accuracy: accuracy.rawValue, timestamp: timestamp)
        }
    }

    private func sendDeviceMotion(_ motion: CMDeviceMotion) {
        let q = motion.attitude.quaternion
        let attitude = MotionConversions.attitude(x: q.x, y: q.y, z: q.z, w: q.w)
        let gravity = motion.gravity
        let user = motion.userAcceleration
        let rate = motion.rotationRate
        let timestamp = MotionConversions.hostNanoseconds(uptime: motion.timestamp)
        deliver {
            delegate.didUpdateDeviceMotion(
                self,
                attitudeX: attitude.x, attitudeY: attitude.y, attitudeZ: attitude.z, attitudeW: attitude.w,
                gravityX: MotionConversions.acceleration(gravity.x),
                gravityY: MotionConversions.acceleration(gravity.y),
                gravityZ: MotionConversions.acceleration(gravity.z),
                userAccelerationX: MotionConversions.acceleration(user.x),
                userAccelerationY: MotionConversions.acceleration(user.y),
                userAccelerationZ: MotionConversions.acceleration(user.z),
                rotationRateX: rate.x, rotationRateY: rate.y, rotationRateZ: rate.z,
                timestamp: timestamp
            )
        }
    }
    #endif
}

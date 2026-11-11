import CoreMotion
import DarwinHost
import DynamicMotion
import DynamicRuntime
import Foundation

/// Conversions from CoreMotion's units, signs, clocks and codes to the
/// Motion contracts' convention (`Motion.md`, "One convention for
/// samples"). Pure functions over plain values, so they can be tested
/// without sensors, and on macOS, where most CoreMotion classes don't exist.
enum MotionConversions {

    // MARK: Timestamps

    /// The built-in `Clock`'s source.
    static let clock = DispatchClock()

    /// A CoreMotion timestamp as host monotonic nanoseconds, the clock of
    /// the built-in `Clock.now`.
    ///
    /// `CMLogItem.timestamp` is seconds on `ProcessInfo.systemUptime`'s
    /// clock (`mach_absolute_time`), which stops while the device sleeps. The
    /// host clock is `mach_continuous_time`, which doesn't. Rather than add
    /// a fixed offset, this measures the sample's age on the uptime clock
    /// and subtracts it from the host clock's now: both are read together,
    /// so the time the device slept since boot cancels out.
    static func hostNanoseconds(uptime: TimeInterval) -> Int64 {
        hostNanoseconds(uptime: uptime, uptimeNow: ProcessInfo.processInfo.systemUptime, hostNow: clock.now())
    }

    /// `hostNow` minus the sample's age, `uptimeNow - uptime`. The age is
    /// computed in seconds first, which keeps sub-microsecond precision
    /// however long the device has been up.
    static func hostNanoseconds(uptime: TimeInterval, uptimeNow: TimeInterval, hostNow: Int64) -> Int64 {
        let age = ((uptimeNow - uptime) * 1_000_000_000).rounded()
        // About 285 years either way: anything larger is a corrupt sample.
        guard age.isFinite, age.magnitude < 9e18 else { return hostNow }
        return hostNow &- Int64(age)
    }

    /// Milliseconds since 1970-01-01 UTC.
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Milliseconds since 1970-01-01 UTC as a `Date`.
    static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    // MARK: Samples

    /// CoreMotion's g, with its sign, as the contract's m/s² with Android's
    /// sign: at rest face up CoreMotion reports z ≈ -1, the contract
    /// z ≈ +9.81. Applies to raw acceleration, gravity and user
    /// acceleration alike.
    static func acceleration(_ g: Double) -> Double {
        g * -standardGravity
    }

    /// `CMAttitude.quaternion` in the contract's convention.
    ///
    /// CoreMotion's quaternion is the device's orientation in the reference
    /// frame: it rotates device coordinates into the reference frame, with
    /// z vertical (up) for `xArbitraryZVertical`, which is the contract's
    /// convention (Android's game rotation vector). Only the sign of the
    /// acceleration vectors differs between the platforms, not the
    /// attitude, so the components pass through, normalized against
    /// rounding.
    static func attitude(x: Double, y: Double, z: Double, w: Double) -> (x: Double, y: Double, z: Double, w: Double) {
        let length = (x * x + y * y + z * z + w * w).squareRoot()
        guard length > 0, length.isFinite else { return (0, 0, 0, 1) }
        return (x / length, y / length, z / length, w / length)
    }

    /// A `CMMagneticFieldCalibrationAccuracy` raw value as a
    /// `MagneticFieldAccuracy`. The raw values match.
    static func magneticFieldAccuracy(_ raw: Int32) -> MagneticFieldAccuracy {
        MagneticFieldAccuracy(rawValue: raw) ?? .uncalibrated
    }

    // MARK: Activity

    /// `CMMotionActivity`'s flags as a `MotionActivity` raw value.
    static func activity(
        stationary: Bool, walking: Bool, running: Bool,
        automotive: Bool, cycling: Bool, unknown: Bool
    ) -> Int32 {
        var activity: MotionActivity = []
        if stationary { activity.insert(.stationary) }
        if walking { activity.insert(.walking) }
        if running { activity.insert(.running) }
        if automotive { activity.insert(.automotive) }
        if cycling { activity.insert(.cycling) }
        if unknown { activity.insert(.unknown) }
        return activity.rawValue
    }

    /// A `CMMotionActivityConfidence` raw value (low 0, medium 1, high 2) as
    /// an `ActivityConfidence`.
    static func confidence(_ raw: Int) -> ActivityConfidence {
        switch raw {
        case 0: return .low
        case 1: return .medium
        case 2: return .high
        default:
            AppHost.logger.error("Unknown CMMotionActivityConfidence \(raw, privacy: .public); reporting it as low")
            return .low
        }
    }

    // MARK: Pedometer

    /// `CMPedometerData`'s values in the contract's form: a count the
    /// device didn't provide is `nan` (distance) or `-1` (floors).
    struct PedometerCounts: Equatable {
        var steps: Int64
        var distance: Double
        var floorsAscended: Int32
        var floorsDescended: Int32
        var start: Int64
        var end: Int64

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.steps == rhs.steps
                && (lhs.distance == rhs.distance || (lhs.distance.isNaN && rhs.distance.isNaN))
                && lhs.floorsAscended == rhs.floorsAscended
                && lhs.floorsDescended == rhs.floorsDescended
                && lhs.start == rhs.start
                && lhs.end == rhs.end
        }
    }

    static func pedometer(
        steps: NSNumber, distance: NSNumber?, floorsAscended: NSNumber?, floorsDescended: NSNumber?,
        start: Date, end: Date
    ) -> PedometerCounts {
        PedometerCounts(
            steps: steps.int64Value,
            distance: distance?.doubleValue ?? .nan,
            floorsAscended: floorsAscended.map { Int32(clamping: $0.int64Value) } ?? -1,
            floorsDescended: floorsDescended.map { Int32(clamping: $0.int64Value) } ?? -1,
            start: milliseconds(start),
            end: milliseconds(end)
        )
    }

    // MARK: Authorization

    /// A `CMAuthorizationStatus` raw value (not determined 0, restricted 1,
    /// denied 2, authorized 3) as a `MotionAuthorization`.
    static func authorization(_ raw: Int) -> MotionAuthorization {
        switch raw {
        case 0: return .notDetermined
        case 1: return .restricted
        case 2: return .denied
        case 3: return .authorized
        default:
            AppHost.logger.error("Unknown CMAuthorizationStatus \(raw, privacy: .public); reporting it as not determined")
            return .notDetermined
        }
    }

    static func permission(_ authorization: MotionAuthorization) -> PermissionStatus {
        switch authorization {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .granted
        }
    }

    // MARK: Errors

    /// A CoreMotion error as a `MotionError`. Anything else, including
    /// errors from other domains, is `unknown`.
    static func error(_ error: Error) -> MotionError {
        let error = error as NSError
        guard error.domain == CMErrorDomain else { return .unknown }
        switch UInt32(clamping: error.code) {
        case CMErrorMotionActivityNotAuthorized.rawValue, CMErrorNotAuthorized.rawValue,
             CMErrorMotionActivityNotEntitled.rawValue, CMErrorNotEntitled.rawValue:
            return .unauthorized
        case CMErrorMotionActivityNotAvailable.rawValue, CMErrorNotAvailable.rawValue:
            return .unavailable
        default:
            return .unknown
        }
    }

    /// `error(_:)`, logging the errors that become `unknown`, which the
    /// contract has no other slot for.
    static func reported(_ error: Error, by source: String) -> MotionError {
        let mapped = self.error(error)
        if mapped == .unknown {
            AppHost.logger.error("\(source, privacy: .public) failed: \(error as NSError, privacy: .public)")
        }
        return mapped
    }
}

/// Runs a host→guest call in an autorelease pool (`HostRuntime.md` §5).
func deliver(_ body: () -> Void) {
    autoreleasepool(invoking: body)
}

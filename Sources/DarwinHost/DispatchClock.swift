import Darwin
import Dispatch
import RuntimeCore

/// The built-in `Clock` on Apple platforms (`HostRuntime.md` §6).
///
/// `now` is `mach_continuous_time()`, which keeps counting while the device
/// sleeps. Timers run on the main queue, and fire late if the app was
/// suspended, which matches "after at least". Reading the boot-relative
/// clock is a required-reason API: the packager declares
/// `NSPrivacyAccessedAPICategorySystemBootTime` (`35F9.1`).
public final class DispatchClock: HostClock {

    private let numerator: UInt64

    private let denominator: UInt64

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        numerator = UInt64(info.numer)
        denominator = UInt64(max(info.denom, 1))
    }

    public func now() -> Int64 {
        let ticks = mach_continuous_time()
        // Multiply by the timebase without overflowing: the ratio is 1/1 on
        // Intel and 125/3 on Apple silicon.
        let nanoseconds = ticks / denominator * numerator + ticks % denominator * numerator / denominator
        return Int64(clamping: nanoseconds)
    }

    public func schedule(after nanoseconds: Int64, _ body: @escaping () -> Void) {
        let delay = max(nanoseconds, 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(clamping: delay)), execute: body)
    }
}

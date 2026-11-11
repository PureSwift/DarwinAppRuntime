import CoreMotion
import DarwinHost
import DynamicMotion
import DynamicRuntime
import Foundation

/// The `Altimeter` contract over `CMAltimeter`'s relative altitude updates.
///
/// Pressure is in kilopascals and relative altitude in meters, as
/// CoreMotion reports them; timestamps become host monotonic nanoseconds.
/// Updates fail with `unauthorized` until Motion & Fitness access is
/// `authorized`, so that only `requestAuthorization()` prompts. Handlers
/// run on `OperationQueue.main`.
///
/// macOS has no altimeter: `isAvailable()` is `false`, the status is
/// `restricted` and updates fail with `unavailable`.
public final class DarwinAltimeter: Altimeter {

    let delegate: any AltimeterDelegate

    /// The token of the running updates; samples queued before
    /// `stopUpdates()` carry an older one and are dropped.
    private(set) var updates: Int?

    private var nextToken = 0

    #if os(iOS)
    let altimeter = CMAltimeter()
    #endif

    init(delegate: any AltimeterDelegate) {
        self.delegate = delegate
    }

    deinit {
        #if os(iOS)
        if updates != nil {
            altimeter.stopRelativeAltitudeUpdates()
        }
        #endif
    }

    public static func isAvailable() -> Bool {
        #if os(iOS)
        CMAltimeter.isRelativeAltitudeAvailable()
        #else
        false
        #endif
    }

    public static func authorizationStatus() -> Int32 {
        currentAuthorization().rawValue
    }

    static func currentAuthorization() -> MotionAuthorization {
        #if os(iOS)
        MotionConversions.authorization(CMAltimeter.authorizationStatus().rawValue)
        #else
        .restricted
        #endif
    }

    public static func make(_ delegate: any AltimeterDelegate) -> DarwinAltimeter {
        DarwinAltimeter(delegate: delegate)
    }

    /// Reports the outcome through `didChangeAuthorization`, also when
    /// nothing was asked.
    public func requestAuthorization() {
        MotionAuthorizationRequest.request { [weak self] _ in
            guard let self else { return }
            deliver {
                self.delegate.didChangeAuthorization(self, status: Self.authorizationStatus())
            }
        }
    }

    public func startUpdates() {
        if let error = Self.precondition() {
            stopUpdates()
            return DispatchQueue.main.async { [weak self] in
                self?.fail(error)
            }
        }
        #if os(iOS)
        if updates != nil {
            altimeter.stopRelativeAltitudeUpdates()
        }
        nextToken += 1
        let token = nextToken
        updates = token
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self, self.updates == token else { return }
            if let error {
                return self.fail(MotionConversions.reported(error, by: "CMAltimeter"))
            }
            guard let data else { return }
            let pressure = data.pressure.doubleValue
            let altitude = data.relativeAltitude.doubleValue
            let timestamp = MotionConversions.hostNanoseconds(uptime: data.timestamp)
            deliver {
                self.delegate.didUpdate(self, pressure: pressure, relativeAltitude: altitude, timestamp: timestamp)
            }
        }
        #endif
    }

    public func stopUpdates() {
        guard updates != nil else { return }
        updates = nil
        #if os(iOS)
        altimeter.stopRelativeAltitudeUpdates()
        #endif
    }

    /// `unavailable` without a barometer, `unauthorized` until the status
    /// is `authorized`.
    static func precondition() -> MotionError? {
        guard isAvailable() else { return .unavailable }
        guard currentAuthorization() == .authorized else { return .unauthorized }
        return nil
    }

    /// Stops updates and reports `error`.
    func fail(_ error: MotionError) {
        stopUpdates()
        deliver {
            delegate.didFail(self, error: error.rawValue)
        }
    }
}

import CoreLocation
import DarwinHost
import DynamicLocation
import DynamicRuntime
import Foundation

/// The `LocationManager` contract over `CLLocationManager`.
///
/// Creating a `CLLocationManager` doesn't prompt, so `make` creates one, on
/// the main thread, where it calls back. The implementation is the manager's
/// delegate; CoreLocation holds it weakly, and the implementation holds the
/// guest's delegate strongly.
///
/// - Authorization changes are reported once per distinct
///   `(status, accuracy)` pair, starting with the current values after
///   `make`. A request that can't prompt (already decided, or not allowed)
///   reports the current values again, so a guest waiting on it gets an
///   answer.
/// - Any error other than `locationUnknown` stops location and heading
///   updates (`headingFailure` stops heading only), as the contract says.
/// - Heading is iOS only. On macOS `isHeadingAvailable()` is `false` and
///   `startUpdatingHeading()` fails with `headingFailure`.
public final class DarwinLocationManager: NSObject, LocationManager, CLLocationManagerDelegate {

    /// Reads authorization for the static calls. Created on first use, on
    /// the main thread.
    nonisolated(unsafe) static var statusManager: CLLocationManager?

    let delegate: any LocationManagerDelegate

    let manager: CLLocationManager

    /// The last `(status, accuracy)` sent to the delegate.
    private(set) var reported: (status: Int32, accuracy: Int32)?

    /// How many authorization reports were sent.
    private(set) var reportCount = 0

    /// The wrapper for the newest fix, reused by `lastLocation()` while
    /// CoreLocation still reports the same `CLLocation`.
    private var newest: DarwinLocationFix?

    init(delegate: any LocationManagerDelegate, manager: CLLocationManager) {
        self.delegate = delegate
        self.manager = manager
        super.init()
        manager.delegate = self
    }

    deinit {
        manager.stopUpdatingLocation()
        #if os(iOS)
        manager.stopUpdatingHeading()
        #endif
        manager.delegate = nil
    }

    // MARK: Static

    static var sharedStatusManager: CLLocationManager {
        if let statusManager {
            return statusManager
        }
        let manager = CLLocationManager()
        statusManager = manager
        return manager
    }

    public static func authorizationStatus() -> Int32 {
        LocationMapping.authorization(sharedStatusManager.authorizationStatus).rawValue
    }

    public static func accuracyAuthorization() -> Int32 {
        LocationMapping.accuracyAuthorization(sharedStatusManager.accuracyAuthorization).rawValue
    }

    /// CoreLocation warns that this can block the main thread; the contract
    /// is synchronous, so it's called anyway.
    public static func isLocationServicesEnabled() -> Bool {
        CLLocationManager.locationServicesEnabled()
    }

    public static func isHeadingAvailable() -> Bool {
        #if os(iOS)
        CLLocationManager.headingAvailable()
        #else
        false
        #endif
    }

    /// Doesn't prompt. The current authorization arrives through
    /// `didChangeAuthorization` on a later main-queue turn.
    public static func make(_ delegate: any LocationManagerDelegate) -> DarwinLocationManager {
        let manager = DarwinLocationManager(delegate: delegate, manager: CLLocationManager())
        // CoreLocation also reports the authorization of a new manager; the
        // first of the two reports and the other is a duplicate.
        manager.reportAuthorizationLater(force: false)
        return manager
    }

    // MARK: Authorization

    public func requestWhenInUseAuthorization() {
        guard manager.authorizationStatus == .notDetermined else {
            reportAuthorizationLater(force: true)
            return
        }
        manager.requestWhenInUseAuthorization()
    }

    /// Checks the status first, and asks only when asking can show a
    /// prompt; every call gets an authorization report.
    ///
    /// - Restricted, denied or already always: reports the status at once.
    /// - Not determined: asks; CoreLocation reports the user's answer.
    /// - When in use: iOS shows the upgrade prompt once per install, and
    ///   reports nothing when it doesn't show it or the user keeps
    ///   when-in-use. So the first request is answered when the prompt is
    ///   over (`AlwaysUpgradePrompt`), and later ones at once.
    ///
    /// Needs the always usage string in `Info.plist` (the manifest's
    /// background declaration); without it, fails with `denied`.
    public func requestAlwaysAuthorization() {
        #if os(iOS)
        guard Bundle.main.object(forInfoDictionaryKey: "NSLocationAlwaysAndWhenInUseUsageDescription") != nil else {
            AppHost.logger.error("requestAlwaysAuthorization: Info.plist has no NSLocationAlwaysAndWhenInUseUsageDescription")
            failLater(.denied)
            reportAuthorizationLater(force: true)
            return
        }
        #endif
        switch LocationMapping.authorization(manager.authorizationStatus) {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            guard !AlwaysUpgradePrompt.alreadyRequested else {
                reportAuthorizationLater(force: true)
                return
            }
            AlwaysUpgradePrompt.alreadyRequested = true
            let reports = reportCount
            AlwaysUpgradePrompt.watch { [weak self] in
                // CoreLocation reported a change: that was the answer.
                guard let self, self.reportCount == reports else { return }
                self.reportAuthorization(force: true)
            }
            manager.requestAlwaysAuthorization()
        case .restricted, .denied, .authorizedAlways:
            reportAuthorizationLater(force: true)
        }
    }

    /// `requestTemporaryFullAccuracyAuthorization(withPurposeKey:)`. The
    /// accuracy afterwards is reported whatever the outcome, so a guest
    /// waiting on it gets an answer when the user declines.
    public func requestFullAccuracy(_ purpose: String) {
        guard manager.accuracyAuthorization != .fullAccuracy else {
            reportAuthorizationLater(force: true)
            return
        }
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: purpose) { [weak self] error in
            Self.onMain {
                if let error {
                    // kCLErrorPromptDeclined is the user's answer, not a failure;
                    // other errors (a missing purpose key) have no contract slot.
                    let error = error as NSError
                    if !(error.domain == kCLErrorDomain && error.code == CLError.Code.promptDeclined.rawValue) {
                        AppHost.logger.error("requestFullAccuracy(\(purpose, privacy: .public)) failed: \(error, privacy: .public)")
                    }
                }
                self?.reportAuthorization(force: true)
            }
        }
    }

    // MARK: Settings

    public func setDesiredAccuracy(_ accuracy: Int32) {
        guard let desired = LocationMapping.desiredAccuracy(accuracy) else {
            AppHost.logger.error("setDesiredAccuracy: unknown LocationAccuracy \(accuracy, privacy: .public); keeping the current accuracy")
            return
        }
        manager.desiredAccuracy = desired
    }

    public func setDistanceFilter(_ meters: Double) {
        manager.distanceFilter = LocationMapping.distanceFilter(meters)
    }

    /// iOS needs `authorizedAlways` and `location` in `UIBackgroundModes`;
    /// without them this fails with `backgroundNotAllowed` and leaves
    /// background updates off. (Turning them on without the background mode
    /// would raise an exception.) A macOS app isn't suspended, so there it
    /// always succeeds.
    public func setBackgroundUpdatesEnabled(_ enabled: Bool) {
        #if os(iOS)
        guard enabled else {
            manager.allowsBackgroundLocationUpdates = false
            return
        }
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        guard modes.contains("location") else {
            AppHost.logger.error("setBackgroundUpdatesEnabled: UIBackgroundModes doesn't include location")
            failLater(.backgroundNotAllowed)
            return
        }
        guard manager.authorizationStatus == .authorizedAlways else {
            failLater(.backgroundNotAllowed)
            return
        }
        manager.allowsBackgroundLocationUpdates = true
        #endif
    }

    // MARK: Location

    public func startUpdatingLocation() {
        manager.startUpdatingLocation()
    }

    public func stopUpdatingLocation() {
        manager.stopUpdatingLocation()
    }

    public func requestLocation() {
        manager.requestLocation()
    }

    public func lastLocation() -> (any Location)? {
        guard let location = manager.location else { return nil }
        if let newest, newest.location === location {
            return newest
        }
        return DarwinLocationFix(location)
    }

    // MARK: Heading

    public func startUpdatingHeading() {
        #if os(iOS)
        guard CLLocationManager.headingAvailable() else {
            failLater(.headingFailure)
            return
        }
        manager.startUpdatingHeading()
        #else
        failLater(.headingFailure)
        #endif
    }

    public func stopUpdatingHeading() {
        #if os(iOS)
        manager.stopUpdatingHeading()
        #endif
    }

    // MARK: CLLocationManagerDelegate

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        reportAuthorization(force: false)
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map(DarwinLocationFix.init)
        guard let last = fixes.last else { return }
        newest = last
        autoreleasepool {
            delegate.didUpdateLocations(self, locations: fixes)
        }
    }

    #if os(iOS)
    public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        autoreleasepool {
            delegate.didUpdateHeading(self, heading: DarwinHeading(newHeading))
        }
    }
    #endif

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let mapped = LocationMapping.error(error, servicesEnabled: Self.servicesEnabledAfterDenial(error))
        if mapped == .unknown {
            AppHost.logger.error("CLLocationManager failed: \(error as NSError, privacy: .public)")
        }
        fail(mapped)
    }

    // MARK: Reporting

    /// Sends `didFail`, stopping the updates the contract says the error
    /// stops: none for `locationUnknown`, heading for `headingFailure`, and
    /// both otherwise.
    func fail(_ error: LocationError) {
        switch error {
        case .locationUnknown:
            break
        case .headingFailure:
            stopUpdatingHeading()
        default:
            manager.stopUpdatingLocation()
            stopUpdatingHeading()
        }
        autoreleasepool {
            delegate.didFail(self, error: error.rawValue)
        }
    }

    /// Sends the current authorization if it differs from the last one
    /// sent, or always with `force`.
    func reportAuthorization(force: Bool) {
        let current = (
            status: LocationMapping.authorization(manager.authorizationStatus).rawValue,
            accuracy: LocationMapping.accuracyAuthorization(manager.accuracyAuthorization).rawValue
        )
        if !force, let reported, reported == current {
            return
        }
        reported = current
        reportCount += 1
        autoreleasepool {
            delegate.didChangeAuthorization(self, status: current.status, accuracy: current.accuracy)
        }
    }

    /// Reports on a later main-queue turn, never inside the guest's call.
    private func reportAuthorizationLater(force: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.reportAuthorization(force: force)
        }
    }

    private func failLater(_ error: LocationError) {
        DispatchQueue.main.async { [weak self] in
            self?.fail(error)
        }
    }

    /// Whether location services are on, checked only for `kCLErrorDenied`,
    /// where it decides between `denied` and `servicesDisabled`.
    private static func servicesEnabledAfterDenial(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == kCLErrorDomain, error.code == CLError.Code.denied.rawValue else {
            return true
        }
        return CLLocationManager.locationServicesEnabled()
    }

    static func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }
}

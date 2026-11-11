import CoreLocation
import DarwinHost
import DynamicLocation
import DynamicRuntime
import Foundation

/// Conversions between CoreLocation's values and the Location contracts'
/// codes. Pure functions, so they can be tested without a location manager.
enum LocationMapping {

    // MARK: Authorization

    /// A `CLAuthorizationStatus` as a `LocationAuthorization`. macOS reports
    /// `authorizedAlways` (its `authorized`) for any granted access.
    static func authorization(_ status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedAlways: return .authorizedAlways
        #if os(iOS)
        case .authorizedWhenInUse: return .authorizedWhenInUse
        #endif
        @unknown default:
            AppHost.logger.error("Unknown CLAuthorizationStatus \(status.rawValue, privacy: .public); reporting it as not determined")
            return .notDetermined
        }
    }

    static func accuracyAuthorization(_ accuracy: CLAccuracyAuthorization) -> LocationAccuracyAuthorization {
        switch accuracy {
        case .fullAccuracy: return .full
        case .reducedAccuracy: return .reduced
        @unknown default:
            AppHost.logger.error("Unknown CLAccuracyAuthorization \(accuracy.rawValue, privacy: .public); reporting it as reduced")
            return .reduced
        }
    }

    /// What `Permissions` reports for location: granted, or limited with
    /// approximate location only.
    static func permission(_ status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization) -> PermissionStatus {
        switch authorization(status) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedAlways, .authorizedWhenInUse:
            return accuracyAuthorization(accuracy) == .full ? .granted : .limited
        }
    }

    // MARK: Accuracy

    /// A `LocationAccuracy` raw value as `desiredAccuracy`, or `nil` for a
    /// code this host doesn't know.
    static func desiredAccuracy(_ accuracy: Int32) -> CLLocationAccuracy? {
        switch LocationAccuracy(rawValue: accuracy) {
        case .best: return kCLLocationAccuracyBest
        case .nearestTenMeters: return kCLLocationAccuracyNearestTenMeters
        case .hundredMeters: return kCLLocationAccuracyHundredMeters
        case .kilometer: return kCLLocationAccuracyKilometer
        case .reduced: return kCLLocationAccuracyReduced
        case nil: return nil
        }
    }

    /// `setDistanceFilter(_:)`'s meters as `distanceFilter`: `0` or less is
    /// every change.
    static func distanceFilter(_ meters: Double) -> CLLocationDistance {
        meters > 0 ? meters : kCLDistanceFilterNone
    }

    // MARK: Errors

    /// A CoreLocation error as a `LocationError`.
    ///
    /// `kCLErrorDenied` is also what CoreLocation reports when location
    /// services are off system-wide; `servicesEnabled` tells the two apart.
    /// Anything else, including errors from other domains, is `unknown`.
    static func error(_ error: Error, servicesEnabled: Bool) -> LocationError {
        let error = error as NSError
        guard error.domain == kCLErrorDomain else { return .unknown }
        switch CLError.Code(rawValue: error.code) {
        case .locationUnknown: return .locationUnknown
        case .denied: return servicesEnabled ? .denied : .servicesDisabled
        case .network: return .network
        case .headingFailure: return .headingFailure
        default: return .unknown
        }
    }

    // MARK: Values

    /// Milliseconds since 1970-01-01 UTC.
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Meters above mean sea level, or `nan` when CoreLocation marks the
    /// altitude invalid (a negative vertical accuracy).
    static func altitude(_ location: CLLocation) -> Double {
        location.verticalAccuracy < 0 ? .nan : location.altitude
    }

    /// `1` when `isSimulatedBySoftware`, `0` when not, `-1` when CoreLocation
    /// has no source information for the fix.
    static func isSimulated(_ location: CLLocation) -> Int32 {
        guard let source = location.sourceInformation else { return -1 }
        return source.isSimulatedBySoftware ? 1 : 0
    }
}

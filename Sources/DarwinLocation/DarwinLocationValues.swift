import CoreLocation
import DynamicLocation
import Foundation

/// The `Location` contract over a `CLLocation`.
///
/// CoreLocation already marks unavailable values the way the contract does
/// (negative accuracies, speed and course), so most getters pass them
/// through. Altitude is `nan` when its vertical accuracy is invalid.
public final class DarwinLocationFix: Location {

    public let location: CLLocation

    public init(_ location: CLLocation) {
        self.location = location
    }

    public func latitude() -> Double {
        location.coordinate.latitude
    }

    public func longitude() -> Double {
        location.coordinate.longitude
    }

    public func altitude() -> Double {
        LocationMapping.altitude(location)
    }

    public func horizontalAccuracy() -> Double {
        location.horizontalAccuracy
    }

    public func verticalAccuracy() -> Double {
        location.verticalAccuracy
    }

    public func speed() -> Double {
        location.speed
    }

    public func speedAccuracy() -> Double {
        location.speedAccuracy
    }

    public func course() -> Double {
        location.course
    }

    public func courseAccuracy() -> Double {
        location.courseAccuracy
    }

    public func timestamp() -> Int64 {
        LocationMapping.milliseconds(location.timestamp)
    }

    public func isSimulated() -> Int32 {
        LocationMapping.isSimulated(location)
    }
}

/// The `Heading` contract over a `CLHeading`. CoreLocation reports a
/// negative `trueHeading` until it knows the location, and a negative
/// `headingAccuracy` when the compass needs calibration, as the contract
/// expects.
public final class DarwinHeading: Heading {

    public let heading: CLHeading

    public init(_ heading: CLHeading) {
        self.heading = heading
    }

    public func magneticHeading() -> Double {
        heading.magneticHeading
    }

    public func trueHeading() -> Double {
        heading.trueHeading
    }

    public func headingAccuracy() -> Double {
        heading.headingAccuracy
    }

    public func timestamp() -> Int64 {
        LocationMapping.milliseconds(heading.timestamp)
    }
}

import DynamicDevice
import Foundation
#if os(iOS)
@preconcurrency import UIKit
#endif

/// Conversions from the system's values to the contract's codes. Pure, so
/// tests can check them on any platform they compile for.
enum DeviceMappings {

    static func thermalState(_ state: ProcessInfo.ThermalState) -> ThermalState {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }

    /// "17.4" for 17.4.0, "17.4.1" for 17.4.1, like `UIDevice.systemVersion`.
    static func versionString(_ version: OperatingSystemVersion) -> String {
        var parts = [version.majorVersion, version.minorVersion]
        if version.patchVersion != 0 {
            parts.append(version.patchVersion)
        }
        return parts.map(String.init).joined(separator: ".")
    }

    /// The internal battery among IOKit power source descriptions
    /// (`IOPSGetPowerSourceDescription`), keyed by the `kIOPS…` strings.
    ///
    /// Without a battery: level `-1`, state unknown. On AC power the battery
    /// is full once IOKit says it's charged or it reaches 100%, and charging
    /// otherwise, also while macOS holds the charge (optimized charging), as
    /// a plugged-in iPhone reports.
    static func battery(_ descriptions: [[String: Any]]) -> BatteryReading {
        let battery = descriptions.first { description in
            description["Type"] as? String == "InternalBattery"
                && description["Is Present"] as? Bool ?? true
        }
        guard let battery else {
            return .none
        }
        var level: Float = -1
        if let current = battery["Current Capacity"] as? Int,
           let maximum = battery["Max Capacity"] as? Int, maximum > 0 {
            level = min(1, max(0, Float(current) / Float(maximum)))
        }
        let state: BatteryState
        switch battery["Power Source State"] as? String {
        case "AC Power":
            if battery["Is Charging"] as? Bool == true {
                state = .charging
            } else if battery["Is Charged"] as? Bool == true || level >= 1 {
                state = .full
            } else {
                state = .charging
            }
        case "Battery Power":
            state = .unplugged
        default:
            state = .unknown
        }
        return BatteryReading(level: level, state: state)
    }

    #if os(iOS)
    static func batteryState(_ state: UIDevice.BatteryState) -> BatteryState {
        switch state {
        case .unknown: .unknown
        case .unplugged: .unplugged
        case .charging: .charging
        case .full: .full
        @unknown default: .unknown
        }
    }

    static func orientation(_ orientation: UIDeviceOrientation) -> DeviceOrientation {
        switch orientation {
        case .unknown: .unknown
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .faceUp: .faceUp
        case .faceDown: .faceDown
        @unknown default: .unknown
        }
    }

    /// `.vision` (6) is matched by raw value: it needs the iOS 17 SDK.
    static func idiom(_ idiom: UIUserInterfaceIdiom) -> DeviceIdiom {
        switch idiom {
        case .phone: return .phone
        case .pad: return .pad
        case .tv: return .tv
        case .carPlay: return .car
        case .mac: return .desktop
        default: return idiom.rawValue == 6 ? .vision : .unspecified
        }
    }
    #endif
}

/// The battery's level (0–1, or `-1`) and state.
struct BatteryReading: Equatable {

    var level: Float

    var state: BatteryState

    /// No battery, or monitoring is off.
    static let none = BatteryReading(level: -1, state: .unknown)
}

/// `sysctlbyname` for a string value, such as `hw.machine`.
func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
        return nil
    }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
        return nil
    }
    return String(cString: buffer)
}

import DarwinHost
import Foundation
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import IOKit.ps
#endif

/// The system-wide switches behind `Device`'s opt-in updates, counted
/// across `DarwinDevice` objects: each guest object turns its own on and
/// off, and the system's stay on while any object wants them.
///
/// - Battery: `UIDevice.isBatteryMonitoringEnabled` on iOS, an IOKit power
///   source run loop source on macOS (`PowerSources`).
/// - Orientation: `UIDevice.beginGeneratingDeviceOrientationNotifications`,
///   which UIKit counts itself. Nothing on macOS.
/// - Proximity: `UIDevice.isProximityMonitoringEnabled`. Nothing on macOS.
///
/// Main thread only.
enum SystemMonitoring {

    nonisolated(unsafe) private(set) static var batteryCount = 0

    nonisolated(unsafe) private(set) static var orientationCount = 0

    nonisolated(unsafe) private(set) static var proximityCount = 0

    static func setBattery(_ enabled: Bool) {
        batteryCount += enabled ? 1 : -1
        precondition(batteryCount >= 0)
        guard batteryCount == (enabled ? 1 : 0) else { return }
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = enabled
        #elseif os(macOS)
        if enabled {
            PowerSources.start()
        } else {
            PowerSources.stop()
        }
        #endif
    }

    static func setOrientation(_ enabled: Bool) {
        orientationCount += enabled ? 1 : -1
        precondition(orientationCount >= 0)
        #if os(iOS)
        if enabled {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        } else {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        #endif
    }

    static func setProximity(_ enabled: Bool) {
        proximityCount += enabled ? 1 : -1
        precondition(proximityCount >= 0)
        guard proximityCount == (enabled ? 1 : 0) else { return }
        #if os(iOS)
        UIDevice.current.isProximityMonitoringEnabled = enabled
        #endif
    }
}

#if os(macOS)
/// The Mac's internal battery, over IOKit's power source API.
///
/// While started, a run loop source on the main run loop posts
/// `didChange` for every power source change: level, state, time
/// remaining. `DarwinDevice` reports only the changes the contract has.
enum PowerSources {

    /// Posted on the main thread when a power source changed.
    static let didChange = Notification.Name("org.pureswift.DarwinDevice.powerSourcesDidChange")

    nonisolated(unsafe) private static var source: CFRunLoopSource?

    static var isStarted: Bool {
        source != nil
    }

    static func start() {
        guard source == nil else { return }
        let callback: IOPowerSourceCallbackType = { _ in
            NotificationCenter.default.post(name: PowerSources.didChange, object: nil)
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() else {
            AppHost.logger.error("Device: IOPSNotificationCreateRunLoopSource failed; battery changes won't be reported")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = source
    }

    static func stop() {
        guard let source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = nil
    }

    /// The internal battery now; `.none` on a Mac without one.
    static func read() -> BatteryReading {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return .none
        }
        let descriptions = list.compactMap { source in
            IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
        }
        return DeviceMappings.battery(descriptions)
    }
}
#endif

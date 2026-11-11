import DarwinHost
import DynamicDevice
import Foundation
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import SystemConfiguration
#endif

/// The `Device` contract over UIDevice and ProcessInfo on iOS, and
/// ProcessInfo, sysctl and IOKit power sources on macOS.
///
/// `current()` makes a new object each time, so each guest user has its own
/// delegate and its own opt-in updates. Battery, orientation and proximity
/// monitoring are on in the system only while some object asks for them
/// (`SystemMonitoring`); an object's battery and orientation getters read as
/// unknown until it turns its own on, as the contract says.
///
/// Changes reach the delegate from the system's notifications, on the main
/// queue, and only when the value differs from the last one reported:
/// - low power mode and thermal state while a delegate is set;
/// - battery, orientation and proximity while also turned on.
///
/// On macOS there is no orientation or proximity sensor: orientation stays
/// unknown and proximity monitoring stays off.
public final class DarwinDevice: Device {

    /// Kept strongly (`HostRuntime.md` §5): the guest's object lives until
    /// the delegate is replaced or this object goes away.
    private(set) var delegate: (any DeviceDelegate)?

    private(set) var batteryMonitoring = false

    private(set) var orientationUpdates = false

    private(set) var proximityMonitoring = false

    /// The last values reported, or read when the updates started.
    private var lastBattery = BatteryReading.none

    private var lastLowPowerMode = false

    private var lastThermalState = ThermalState.nominal

    private var lastOrientation = DeviceOrientation.unknown

    private var lastProximity = false

    private var observers: [NSObjectProtocol] = []

    init() { }

    deinit {
        removeObservers()
        if batteryMonitoring {
            SystemMonitoring.setBattery(false)
        }
        if orientationUpdates {
            SystemMonitoring.setOrientation(false)
        }
        if proximityMonitoring {
            SystemMonitoring.setProximity(false)
        }
    }

    public static func current() -> DarwinDevice {
        DarwinDevice()
    }

    public func setDelegate(_ delegate: (any DeviceDelegate)?) {
        removeObservers()
        self.delegate = delegate
        guard delegate != nil else { return }
        lastLowPowerMode = isLowPowerModeEnabled()
        lastThermalState = ThermalState(rawValue: thermalState()) ?? .nominal
        lastBattery = batteryReading
        lastOrientation = DeviceOrientation(rawValue: orientation()) ?? .unknown
        lastProximity = proximityState()
        addObservers()
    }

    // MARK: Identity

    public func name() -> String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ProcessInfo.processInfo.hostName
        #endif
    }

    public func model() -> String {
        #if os(iOS)
        return UIDevice.current.model
        #else
        return "Mac"
        #endif
    }

    /// `hw.machine` on iOS ("iPhone16,1"); in the simulator, the simulated
    /// device's, from `SIMULATOR_MODEL_IDENTIFIER`. `hw.model` on macOS and
    /// Mac Catalyst ("Mac14,2").
    public func modelIdentifier() -> String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        #endif
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return sysctlString("hw.machine") ?? ""
        #else
        return sysctlString("hw.model") ?? ""
        #endif
    }

    public func manufacturer() -> String {
        "Apple"
    }

    public func systemName() -> String {
        #if os(iOS)
        return UIDevice.current.systemName
        #else
        return "macOS"
        #endif
    }

    public func systemVersion() -> String {
        #if os(iOS)
        return UIDevice.current.systemVersion
        #else
        return DeviceMappings.versionString(ProcessInfo.processInfo.operatingSystemVersion)
        #endif
    }

    public func apiLevel() -> Int32 {
        -1
    }

    public func idiom() -> Int32 {
        #if os(iOS)
        return DeviceMappings.idiom(UIDevice.current.userInterfaceIdiom).rawValue
        #else
        return DeviceIdiom.desktop.rawValue
        #endif
    }

    /// `identifierForVendor` on iOS; nil on macOS, which has none.
    public func vendorIdentifier() -> String? {
        #if os(iOS)
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        return nil
        #endif
    }

    public func isSimulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    // MARK: Resources

    public func physicalMemory() -> Int64 {
        Int64(clamping: ProcessInfo.processInfo.physicalMemory)
    }

    public func processorCount() -> Int32 {
        Int32(clamping: ProcessInfo.processInfo.processorCount)
    }

    /// `CLOCK_MONOTONIC_RAW`, which keeps counting while the device sleeps,
    /// like the host's `Clock` (`mach_continuous_time`).
    public func uptime() -> Int64 {
        Int64(clamping: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000_000)
    }

    // MARK: Power

    public func setBatteryMonitoringEnabled(_ enabled: Bool) {
        guard enabled != batteryMonitoring else { return }
        batteryMonitoring = enabled
        SystemMonitoring.setBattery(enabled)
        lastBattery = batteryReading
    }

    public func batteryLevel() -> Float {
        batteryReading.level
    }

    public func batteryState() -> Int32 {
        batteryReading.state.rawValue
    }

    public func isLowPowerModeEnabled() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    public func thermalState() -> Int32 {
        DeviceMappings.thermalState(ProcessInfo.processInfo.thermalState).rawValue
    }

    /// The battery now, or `.none` while this object's monitoring is off.
    var batteryReading: BatteryReading {
        guard batteryMonitoring else {
            return .none
        }
        #if os(iOS)
        let device = UIDevice.current
        return BatteryReading(level: device.batteryLevel, state: DeviceMappings.batteryState(device.batteryState))
        #elseif os(macOS)
        return PowerSources.read()
        #else
        return .none
        #endif
    }

    // MARK: Orientation and proximity

    public func setOrientationUpdatesEnabled(_ enabled: Bool) {
        guard enabled != orientationUpdates else { return }
        orientationUpdates = enabled
        SystemMonitoring.setOrientation(enabled)
        lastOrientation = DeviceOrientation(rawValue: orientation()) ?? .unknown
    }

    public func orientation() -> Int32 {
        guard orientationUpdates else {
            return DeviceOrientation.unknown.rawValue
        }
        #if os(iOS)
        return DeviceMappings.orientation(UIDevice.current.orientation).rawValue
        #else
        return DeviceOrientation.unknown.rawValue
        #endif
    }

    public func setProximityMonitoringEnabled(_ enabled: Bool) {
        guard enabled != proximityMonitoring else { return }
        proximityMonitoring = enabled
        SystemMonitoring.setProximity(enabled)
        lastProximity = proximityState()
    }

    /// False on devices without a sensor, where UIKit leaves monitoring off,
    /// and always on macOS.
    public func isProximityMonitoringEnabled() -> Bool {
        guard proximityMonitoring else {
            return false
        }
        #if os(iOS)
        return UIDevice.current.isProximityMonitoringEnabled
        #else
        return false
        #endif
    }

    public func proximityState() -> Bool {
        guard isProximityMonitoringEnabled() else {
            return false
        }
        #if os(iOS)
        return UIDevice.current.proximityState
        #else
        return false
        #endif
    }

    // MARK: Changes

    private func addObservers() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ handler: @escaping (DarwinDevice) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                handler(self)
            })
        }
        observe(.NSProcessInfoPowerStateDidChange) { device in
            device.report(lowPowerMode: device.isLowPowerModeEnabled())
        }
        observe(ProcessInfo.thermalStateDidChangeNotification) { device in
            device.report(thermalState: ThermalState(rawValue: device.thermalState()) ?? .nominal)
        }
        #if os(iOS)
        observe(UIDevice.batteryLevelDidChangeNotification) { device in
            device.report(battery: device.batteryReading)
        }
        observe(UIDevice.batteryStateDidChangeNotification) { device in
            device.report(battery: device.batteryReading)
        }
        observe(UIDevice.orientationDidChangeNotification) { device in
            device.report(orientation: DeviceOrientation(rawValue: device.orientation()) ?? .unknown)
        }
        observe(UIDevice.proximityStateDidChangeNotification) { device in
            device.report(proximity: device.proximityState())
        }
        #elseif os(macOS)
        observe(PowerSources.didChange) { device in
            device.report(battery: device.batteryReading)
        }
        #endif
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    /// Tells the delegate what changed in the battery, if this object
    /// monitors it.
    func report(battery reading: BatteryReading) {
        guard batteryMonitoring else { return }
        let last = lastBattery
        lastBattery = reading
        if reading.level != last.level {
            call { $0.didChangeBatteryLevel(self, level: reading.level) }
        }
        if reading.state != last.state {
            call { $0.didChangeBatteryState(self, state: reading.state.rawValue) }
        }
    }

    func report(lowPowerMode enabled: Bool) {
        guard enabled != lastLowPowerMode else { return }
        lastLowPowerMode = enabled
        call { $0.didChangeLowPowerMode(self, enabled: enabled) }
    }

    func report(thermalState state: ThermalState) {
        guard state != lastThermalState else { return }
        lastThermalState = state
        call { $0.didChangeThermalState(self, state: state.rawValue) }
    }

    func report(orientation: DeviceOrientation) {
        guard orientationUpdates, orientation != lastOrientation else { return }
        lastOrientation = orientation
        call { $0.didChangeOrientation(self, orientation: orientation.rawValue) }
    }

    func report(proximity near: Bool) {
        guard proximityMonitoring, near != lastProximity else { return }
        lastProximity = near
        call { $0.didChangeProximityState(self, near: near) }
    }

    /// One host→guest call.
    private func call(_ body: (any DeviceDelegate) -> Void) {
        guard let delegate else { return }
        autoreleasepool {
            body(delegate)
        }
    }
}

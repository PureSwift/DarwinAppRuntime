import DynamicDevice
import DynamicRuntime
import Foundation
import Testing
@testable import DarwinDevice

/// Records what a module registers.
final class RecordingRegistrar: ContractRegistrar {

    var registered: [(descriptor: ContractDescriptor, hasStatics: Bool)] = []

    func register(_ descriptor: ContractDescriptor, statics: StaticMethodTable?) {
        // `statics != nil` needs typed-throws runtime support (macOS 15).
        let hasStatics: Bool
        if case .some = statics {
            hasStatics = true
        } else {
            hasStatics = false
        }
        registered.append((descriptor, hasStatics))
    }
}

/// A guest-side delegate.
final class RecordingDeviceDelegate: DeviceDelegate {

    var events: [String] = []

    func didChangeBatteryLevel(_ device: any Device, level: Float) {
        events.append("level \(level)")
    }

    func didChangeBatteryState(_ device: any Device, state: Int32) {
        events.append("state \(state)")
    }

    func didChangeLowPowerMode(_ device: any Device, enabled: Bool) {
        events.append("low power \(enabled)")
    }

    func didChangeThermalState(_ device: any Device, state: Int32) {
        events.append("thermal \(state)")
    }

    func didChangeOrientation(_ device: any Device, orientation: Int32) {
        events.append("orientation \(orientation)")
    }

    func didChangeProximityState(_ device: any Device, near: Bool) {
        events.append("proximity \(near)")
    }
}

/// Serialized: monitoring is counted in `SystemMonitoring`'s static state.
@Suite(.serialized) struct DarwinDeviceTests {

    // MARK: Module

    @Test func registersEveryContract() {
        let registrar = RecordingRegistrar()
        DarwinDeviceModule.register(in: registrar)
        #expect(registrar.registered.map(\.descriptor) == [DeviceProxy.descriptor, DeviceDelegateProxy.descriptor])
        #expect(registrar.registered.map(\.hasStatics) == [true, false], "the delegate is a callback interface")
        #expect(DarwinDeviceModule.contracts == [DeviceProxy.descriptor, DeviceDelegateProxy.descriptor])
        #expect(DarwinDeviceModule.permissionProviders().isEmpty)
    }

    // MARK: Identity and resources

    #if os(macOS)
    @Test func identityOnMac() throws {
        let device = DarwinDevice.current()
        let model = try #require(sysctlString("hw.model"))
        #expect(!model.isEmpty)
        #expect(device.modelIdentifier() == model)
        #expect(device.model() == "Mac")
        #expect(device.manufacturer() == "Apple")
        #expect(device.systemName() == "macOS")
        #expect(device.systemVersion() == DeviceMappings.versionString(ProcessInfo.processInfo.operatingSystemVersion))
        #expect(device.idiom() == DeviceIdiom.desktop.rawValue)
        #expect(device.vendorIdentifier() == nil)
        #expect(device.apiLevel() == -1)
        #expect(!device.isSimulator())
        #expect(!device.name().isEmpty)
    }
    #endif

    @Test func resources() {
        let device = DarwinDevice.current()
        #expect(device.physicalMemory() == Int64(ProcessInfo.processInfo.physicalMemory))
        #expect(device.processorCount() == Int32(ProcessInfo.processInfo.processorCount))
        let first = device.uptime()
        let second = device.uptime()
        #expect(first > 0)
        #expect(second >= first)
        // `systemUptime` stops while asleep; this clock doesn't.
        #expect(first >= Int64(ProcessInfo.processInfo.systemUptime * 1000) - 1000)
    }

    @Test func versionString() {
        #expect(DeviceMappings.versionString(OperatingSystemVersion(majorVersion: 17, minorVersion: 4, patchVersion: 0)) == "17.4")
        #expect(DeviceMappings.versionString(OperatingSystemVersion(majorVersion: 14, minorVersion: 4, patchVersion: 1)) == "14.4.1")
    }

    @Test func powerAndThermalState() {
        let device = DarwinDevice.current()
        #expect(device.isLowPowerModeEnabled() == ProcessInfo.processInfo.isLowPowerModeEnabled)
        #expect(device.thermalState() == DeviceMappings.thermalState(ProcessInfo.processInfo.thermalState).rawValue)
        #expect(DeviceMappings.thermalState(.nominal) == .nominal)
        #expect(DeviceMappings.thermalState(.fair) == .fair)
        #expect(DeviceMappings.thermalState(.serious) == .serious)
        #expect(DeviceMappings.thermalState(.critical) == .critical)
    }

    // MARK: Battery

    @Test func batteryDescriptions() {
        func battery(_ values: [String: Any]) -> [String: Any] {
            ["Type": "InternalBattery", "Is Present": true, "Max Capacity": 100].merging(values) { $1 }
        }
        #expect(DeviceMappings.battery([]) == .none, "a desktop Mac")
        #expect(DeviceMappings.battery([["Type": "UPS", "Current Capacity": 50, "Max Capacity": 100]]) == .none)
        #expect(DeviceMappings.battery([battery(["Is Present": false, "Current Capacity": 50])]) == .none)

        let onBattery = battery(["Current Capacity": 42, "Power Source State": "Battery Power"])
        #expect(DeviceMappings.battery([onBattery]) == BatteryReading(level: 0.42, state: .unplugged))

        let charging = battery(["Current Capacity": 80, "Power Source State": "AC Power", "Is Charging": true])
        #expect(DeviceMappings.battery([charging]) == BatteryReading(level: 0.8, state: .charging))

        let held = battery(["Current Capacity": 80, "Power Source State": "AC Power", "Is Charging": false])
        #expect(DeviceMappings.battery([held]) == BatteryReading(level: 0.8, state: .charging), "optimized charging holds at 80%")

        let charged = battery(["Current Capacity": 100, "Power Source State": "AC Power", "Is Charging": false])
        #expect(DeviceMappings.battery([charged]) == BatteryReading(level: 1, state: .full))
        let reportedCharged = battery(["Current Capacity": 99, "Power Source State": "AC Power", "Is Charged": true])
        #expect(DeviceMappings.battery([reportedCharged]).state == .full)

        let noCapacity = battery(["Max Capacity": 0, "Power Source State": "Battery Power"])
        #expect(DeviceMappings.battery([noCapacity]) == BatteryReading(level: -1, state: .unplugged))
    }

    @Test func batteryMonitoringIsOptIn() {
        let start = SystemMonitoring.batteryCount
        let first = DarwinDevice.current()
        let second = DarwinDevice.current()
        #expect(first.batteryLevel() == -1)
        #expect(first.batteryState() == BatteryState.unknown.rawValue)

        first.setBatteryMonitoringEnabled(true)
        first.setBatteryMonitoringEnabled(true)
        #expect(SystemMonitoring.batteryCount == start + 1, "enabling twice counts once")
        second.setBatteryMonitoringEnabled(true)
        #expect(SystemMonitoring.batteryCount == start + 2)
        #if os(macOS)
        #expect(PowerSources.isStarted)
        #expect(first.batteryLevel() == PowerSources.read().level)
        #endif
        #expect(second.batteryLevel() == -1 || (0...1).contains(second.batteryLevel()))

        first.setBatteryMonitoringEnabled(false)
        #expect(first.batteryLevel() == -1, "unknown again once off")
        #expect(SystemMonitoring.batteryCount == start + 1)
        #if os(macOS)
        #expect(PowerSources.isStarted, "on while another object wants it")
        #endif

        withExtendedLifetime(second) { }
    }

    @Test func releasingAnObjectTurnsItsMonitoringOff() {
        let battery = SystemMonitoring.batteryCount
        let orientation = SystemMonitoring.orientationCount
        let proximity = SystemMonitoring.proximityCount
        do {
            let device = DarwinDevice.current()
            device.setBatteryMonitoringEnabled(true)
            device.setOrientationUpdatesEnabled(true)
            device.setProximityMonitoringEnabled(true)
            #expect(SystemMonitoring.batteryCount == battery + 1)
            #expect(SystemMonitoring.orientationCount == orientation + 1)
            #expect(SystemMonitoring.proximityCount == proximity + 1)
        }
        #expect(SystemMonitoring.batteryCount == battery)
        #expect(SystemMonitoring.orientationCount == orientation)
        #expect(SystemMonitoring.proximityCount == proximity)
        #if os(macOS)
        if battery == 0 {
            #expect(!PowerSources.isStarted)
        }
        #endif
    }

    // MARK: Orientation and proximity

    #if os(macOS)
    @Test func noOrientationOrProximityOnMac() {
        let device = DarwinDevice.current()
        device.setOrientationUpdatesEnabled(true)
        #expect(device.orientation() == DeviceOrientation.unknown.rawValue)
        device.setProximityMonitoringEnabled(true)
        #expect(!device.isProximityMonitoringEnabled(), "no sensor")
        #expect(!device.proximityState())
        device.setOrientationUpdatesEnabled(false)
        device.setProximityMonitoringEnabled(false)
    }
    #endif

    // MARK: Delegate

    @Test func reportsChanges() {
        let device = DarwinDevice.current()
        let delegate = RecordingDeviceDelegate()
        device.setDelegate(delegate)

        let thermal = ThermalState(rawValue: device.thermalState()) ?? .nominal
        let other: ThermalState = thermal == .serious ? .fair : .serious
        device.report(thermalState: thermal)
        device.report(thermalState: other)
        device.report(thermalState: other)
        #expect(delegate.events == ["thermal \(other.rawValue)"], "only changes")

        delegate.events = []
        let lowPower = device.isLowPowerModeEnabled()
        device.report(lowPowerMode: lowPower)
        device.report(lowPowerMode: !lowPower)
        #expect(delegate.events == ["low power \(!lowPower)"])

        // Battery, orientation and proximity need their updates on.
        delegate.events = []
        device.report(battery: BatteryReading(level: 0.5, state: .unplugged))
        device.report(orientation: .faceUp)
        device.report(proximity: true)
        #expect(delegate.events.isEmpty)

        device.setBatteryMonitoringEnabled(true)
        device.setOrientationUpdatesEnabled(true)
        device.setProximityMonitoringEnabled(true)
        device.report(battery: BatteryReading(level: 0.5, state: .unplugged))
        device.report(battery: BatteryReading(level: 0.5, state: .charging))
        device.report(orientation: .faceUp)
        device.report(proximity: true)
        #expect(delegate.events.contains("level 0.5"))
        #expect(delegate.events.contains("state \(BatteryState.charging.rawValue)"))
        #expect(delegate.events.contains("orientation \(DeviceOrientation.faceUp.rawValue)"))
        #expect(delegate.events.contains("proximity true"))
        #expect(delegate.events.filter { $0.hasPrefix("level") }.count == 1, "the level changed once")

        device.setBatteryMonitoringEnabled(false)
        device.setOrientationUpdatesEnabled(false)
        device.setProximityMonitoringEnabled(false)
    }

    @Test func removingTheDelegateStopsReports() {
        let device = DarwinDevice.current()
        let delegate = RecordingDeviceDelegate()
        device.setDelegate(delegate)
        device.setDelegate(nil)
        device.report(thermalState: .critical)
        device.report(lowPowerMode: !device.isLowPowerModeEnabled())
        #expect(delegate.events.isEmpty)
    }

    @Test func keepsTheDelegate() {
        let device = DarwinDevice.current()
        weak var weakDelegate: RecordingDeviceDelegate?
        do {
            let delegate = RecordingDeviceDelegate()
            weakDelegate = delegate
            device.setDelegate(delegate)
        }
        #expect(weakDelegate != nil)
        device.setDelegate(nil)
        #expect(weakDelegate == nil)
    }
}

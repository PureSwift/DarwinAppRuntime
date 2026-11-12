import CoreBluetooth
import DarwinHost
import DynamicBluetooth
import DynamicRuntime
import Foundation
import Testing
@testable import DarwinBluetooth

// None of these tests creates a `CBCentralManager`: it would prompt, or the
// test runner would be killed for lacking a usage description.

// MARK: - Module

@Suite struct ModuleTests {

    @Test func listsEveryContractAndCallback() {
        let names = DarwinBluetooth.contracts.map(\.name)
        #expect(names == [
            "org.pureswift.bluetooth.Central",
            "org.pureswift.bluetooth.CentralDelegate",
            "org.pureswift.bluetooth.Peripheral",
            "org.pureswift.bluetooth.PeripheralDelegate",
            "org.pureswift.bluetooth.Service",
            "org.pureswift.bluetooth.Characteristic",
            "org.pureswift.bluetooth.Descriptor",
            "org.pureswift.bluetooth.Advertisement",
        ])
    }

    @Test func registersImplementationsAndCallbackInterfaces() {
        let registrar = RecordingRegistrar()
        DarwinBluetooth.register(in: registrar)
        #expect(Set(registrar.registered.map(\.descriptor.name)) == Set(DarwinBluetooth.contracts.map(\.name)))
        #expect(registrar.registered.count == DarwinBluetooth.contracts.count)
        // Contracts come with an implementation; callbacks don't.
        for (descriptor, hasStatics) in registrar.registered {
            #expect(hasStatics == (descriptor.kind == .contract), "\(descriptor.name)")
        }
    }

    @Test func providesBluetoothPermission() {
        let providers = DarwinBluetooth.permissionProviders()
        #expect(Array(providers.keys) == [.bluetooth])
        #expect(providers[.bluetooth] is BluetoothPermission)
    }

    @Test func usedOnlyByBluetoothApps() {
        #expect(DarwinBluetooth.isUsed(by: ["org.pureswift.bluetooth.Central"]))
        #expect(!DarwinBluetooth.isUsed(by: ["org.pureswift.location.LocationManager"]))
    }
}

final class RecordingRegistrar: ContractRegistrar {

    var registered: [(descriptor: ContractDescriptor, hasStatics: Bool)] = []

    func register(_ descriptor: ContractDescriptor, statics: StaticMethodTable?) {
        // Pattern matching: comparing with `nil` needs runtime metadata for
        // typed-throws function types, which macOS 12 lacks.
        var hasStatics = false
        if case .some = statics {
            hasStatics = true
        }
        registered.append((descriptor, hasStatics))
    }
}

// MARK: - UUIDs

@Suite struct UUIDTests {

    @Test(arguments: [
        ("180D", BluetoothUUID.bit16(0x180D)),
        ("0000180D", BluetoothUUID.bit16(0x180D)),
        ("0001180D", BluetoothUUID.bit32(0x0001_180D)),
        ("0000180D-0000-1000-8000-00805F9B34FB", BluetoothUUID.bit16(0x180D)),
        ("0000180d-0000-1000-8000-00805f9b34fb", BluetoothUUID.bit16(0x180D)),
        ("1234ABCD-0000-1000-8000-00805F9B34FB", BluetoothUUID.bit32(0x1234_ABCD)),
    ])
    func shortestForm(_ string: String, _ expected: BluetoothUUID) {
        #expect(CoreBluetoothMapping.shortestUUID(string) == expected)
    }

    @Test func customUUIDStaysFull() throws {
        let string = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
        let uuid = try #require(CoreBluetoothMapping.shortestUUID(string))
        #expect(uuid.rawValue == string)
    }

    @Test(arguments: ["", "18", "XYZW", "0000180D-0000"])
    func invalidStrings(_ string: String) {
        #expect(CoreBluetoothMapping.shortestUUID(string) == nil)
    }

    @Test(arguments: [
        BluetoothUUID.bit16(0x180D),
        BluetoothUUID.bit16(0x2A37),
        BluetoothUUID(rawValue: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")!,
    ])
    func roundTripsThroughCBUUID(_ uuid: BluetoothUUID) throws {
        let cbUUID = CoreBluetoothMapping.cbUUID(uuid)
        #expect(try CoreBluetoothMapping.bluetoothUUID(cbUUID) == uuid)
    }

    @Test func everyFormReachesCoreBluetooth() throws {
        let full = try #require(BluetoothUUID(rawValue: "0000180D-0000-1000-8000-00805F9B34FB"))
        // Whatever form CoreBluetooth keeps, the contract gets the shortest.
        #expect(try CoreBluetoothMapping.bluetoothUUID(CoreBluetoothMapping.cbUUID(.bit32(0x180D))) == .bit16(0x180D))
        #expect(try CoreBluetoothMapping.bluetoothUUID(CoreBluetoothMapping.cbUUID(full)) == .bit16(0x180D))
        #expect(try CoreBluetoothMapping.bluetoothUUID(CoreBluetoothMapping.cbUUID(.bit32(0x0001_180D))) == .bit32(0x0001_180D))
        #expect(CoreBluetoothMapping.cbUUID(full) == CoreBluetoothMapping.cbUUID(.bit16(0x180D)))
    }

    @Test func sameUUIDAcrossForms() throws {
        let full = try #require(BluetoothUUID(rawValue: "0000180D-0000-1000-8000-00805F9B34FB"))
        #expect(CoreBluetoothMapping.sameUUID(.bit16(0x180D), full))
        #expect(CoreBluetoothMapping.sameUUID(.bit16(0x180D), .bit32(0x180D)))
        #expect(!CoreBluetoothMapping.sameUUID(.bit16(0x180D), .bit16(0x180F)))
    }

    @Test func clientCharacteristicConfiguration() {
        #expect(CoreBluetoothMapping.isClientCharacteristicConfiguration(CBUUID(string: "2902")))
        #expect(CoreBluetoothMapping.isClientCharacteristicConfiguration(CBUUID(string: "00002902-0000-1000-8000-00805F9B34FB")))
        #expect(!CoreBluetoothMapping.isClientCharacteristicConfiguration(CBUUID(string: "2901")))
    }
}

// MARK: - States and values

@Suite struct MappingTests {

    @Test func centralStates() {
        #expect(CoreBluetoothMapping.centralState(.unknown) == .unknown)
        #expect(CoreBluetoothMapping.centralState(.resetting) == .resetting)
        #expect(CoreBluetoothMapping.centralState(.unsupported) == .unsupported)
        #expect(CoreBluetoothMapping.centralState(.unauthorized) == .unauthorized)
        #expect(CoreBluetoothMapping.centralState(.poweredOff) == .poweredOff)
        #expect(CoreBluetoothMapping.centralState(.poweredOn) == .poweredOn)
    }

    @Test func authorizations() {
        #expect(CoreBluetoothMapping.authorization(.notDetermined) == .notDetermined)
        #expect(CoreBluetoothMapping.authorization(.restricted) == .restricted)
        #expect(CoreBluetoothMapping.authorization(.denied) == .denied)
        #expect(CoreBluetoothMapping.authorization(.allowedAlways) == .allowed)
        #expect(CoreBluetoothMapping.permission(.notDetermined) == .notDetermined)
        #expect(CoreBluetoothMapping.permission(.restricted) == .restricted)
        #expect(CoreBluetoothMapping.permission(.denied) == .denied)
        #expect(CoreBluetoothMapping.permission(.allowedAlways) == .granted)
    }

    @Test func peripheralStates() {
        #expect(CoreBluetoothMapping.peripheralState(.disconnected) == .disconnected)
        #expect(CoreBluetoothMapping.peripheralState(.connecting) == .connecting)
        #expect(CoreBluetoothMapping.peripheralState(.connected) == .connected)
        #expect(CoreBluetoothMapping.peripheralState(.disconnecting) == .disconnecting)
    }

    @Test func readiness() {
        // Authorization comes first, whatever the radio says.
        #expect(CoreBluetoothMapping.readinessError(state: nil, authorization: .notDetermined) == .unauthorized)
        #expect(CoreBluetoothMapping.readinessError(state: .poweredOn, authorization: .denied) == .unauthorized)
        #expect(CoreBluetoothMapping.readinessError(state: .poweredOn, authorization: .restricted) == .unauthorized)
        #expect(CoreBluetoothMapping.readinessError(state: .poweredOn, authorization: .allowedAlways) == nil)
        #expect(CoreBluetoothMapping.readinessError(state: .poweredOff, authorization: .allowedAlways) == .poweredOff)
        #expect(CoreBluetoothMapping.readinessError(state: .unknown, authorization: .allowedAlways) == .poweredOff)
        #expect(CoreBluetoothMapping.readinessError(state: .resetting, authorization: .allowedAlways) == .poweredOff)
        #expect(CoreBluetoothMapping.readinessError(state: nil, authorization: .allowedAlways) == .poweredOff)
        #expect(CoreBluetoothMapping.readinessError(state: .unsupported, authorization: .allowedAlways) == .unsupported)
        #expect(CoreBluetoothMapping.readinessError(state: .unauthorized, authorization: .allowedAlways) == .unauthorized)
    }

    @Test func writeTypes() {
        #expect(CoreBluetoothMapping.writeType(WriteType.withResponse.rawValue) == .withResponse)
        #expect(CoreBluetoothMapping.writeType(WriteType.withoutResponse.rawValue) == .withoutResponse)
        #expect(CoreBluetoothMapping.writeType(7) == nil)
    }

    @Test func properties() {
        let properties: CBCharacteristicProperties = [.read, .notify, .notifyEncryptionRequired]
        let raw = CoreBluetoothMapping.properties(properties)
        #expect(raw == 0x12)
        #expect(GATTCharacteristicProperties(rawValue: UInt8(raw)).contains(.notify))
    }

    @Test func rssi() {
        #expect(CoreBluetoothMapping.rssi(NSNumber(value: -60)) == -60)
        #expect(CoreBluetoothMapping.rssi(NSNumber(value: 127)) == 127)
    }

    @Test func descriptorValues() {
        #expect(CoreBluetoothMapping.descriptorBytes(nil) == nil)
        #expect(CoreBluetoothMapping.descriptorBytes(Data([0x01, 0x02, 0x03])) == [0x01, 0x02, 0x03])
        #expect(CoreBluetoothMapping.descriptorBytes("Heart") == Array("Heart".utf8))
        // Client Characteristic Configuration with notifications on.
        #expect(CoreBluetoothMapping.descriptorBytes(NSNumber(value: 0x0001)) == [0x01, 0x00])
        #expect(CoreBluetoothMapping.descriptorBytes(NSNumber(value: 0x0102)) == [0x02, 0x01])
        #expect(CoreBluetoothMapping.descriptorBytes([1, 2]) == nil)
    }
}

// MARK: - Errors

@Suite struct ErrorTests {

    func cbError(_ code: CBError.Code) -> NSError {
        NSError(domain: CBErrorDomain, code: code.rawValue)
    }

    func attError(_ code: Int) -> NSError {
        NSError(domain: CBATTErrorDomain, code: code)
    }

    @Test func success() {
        #expect(CoreBluetoothMapping.errorCode(nil) == 0)
    }

    @Test(arguments: [
        (CBError.Code.invalidParameters, BluetoothError.invalidParameters),
        (.invalidHandle, .invalidParameters),
        (.uuidNotAllowed, .invalidParameters),
        (.notConnected, .notConnected),
        (.operationCancelled, .operationCancelled),
        (.connectionTimeout, .connectionTimeout),
        (.peripheralDisconnected, .peripheralDisconnected),
        (.connectionFailed, .connectionFailed),
        (.unknownDevice, .connectionFailed),
        (.connectionLimitReached, .connectionLimitReached),
        (.tooManyLEPairedDevices, .connectionLimitReached),
        (.operationNotSupported, .operationNotSupported),
        (.peerRemovedPairingInformation, .insufficientAuthentication),
        (.encryptionTimedOut, .insufficientAuthentication),
        (.unknown, .unknown),
        (.outOfSpace, .unknown),
        (.alreadyAdvertising, .unknown),
    ])
    func coreBluetoothErrors(_ code: CBError.Code, _ expected: BluetoothError) {
        #expect(CoreBluetoothMapping.errorCode(cbError(code)) == expected.rawValue)
    }

    @Test func newerCoreBluetoothCodesAreUnknown() {
        #expect(CoreBluetoothMapping.errorCode(NSError(domain: CBErrorDomain, code: 999)) == BluetoothError.unknown.rawValue)
    }

    @Test func attributeErrorsCarryTheirCode() {
        // Read Not Permitted (0x02), Attribute Not Found (0x0A).
        #expect(CoreBluetoothMapping.errorCode(attError(0x02)) == 258)
        #expect(CoreBluetoothMapping.errorCode(attError(0x0A)) == 266)
        #expect(BluetoothError(code: CoreBluetoothMapping.errorCode(attError(0x0A))) == .attribute)
    }

    @Test func pairingErrorsKeepTheirATTCode() {
        let authentication = CoreBluetoothMapping.errorCode(attError(CBATTError.insufficientAuthentication.rawValue))
        let encryption = CoreBluetoothMapping.errorCode(attError(CBATTError.insufficientEncryption.rawValue))
        #expect(authentication == 261)
        #expect(encryption == 271)
        // The async API retries after pairing on either.
        #expect(BluetoothError(code: authentication) == .insufficientAuthentication)
        #expect(BluetoothError(code: encryption) == .insufficientAuthentication)
    }

    @Test func otherDomainsAreUnknown() {
        #expect(CoreBluetoothMapping.errorCode(NSError(domain: NSPOSIXErrorDomain, code: 1)) == BluetoothError.unknown.rawValue)
        #expect(CoreBluetoothMapping.errorCode(attError(0)) == BluetoothError.unknown.rawValue)
    }
}

// MARK: - Advertisement

@Suite struct AdvertisementTests {

    @Test func readsEveryField() throws {
        let advertisement = DarwinAdvertisement([
            CBAdvertisementDataLocalNameKey: "Sensor",
            CBAdvertisementDataManufacturerDataKey: Data([0x4C, 0x00, 0x02, 0x15]),
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "180D")],
            CBAdvertisementDataOverflowServiceUUIDsKey: [CBUUID(string: "180F"), CBUUID(string: "180D")],
            CBAdvertisementDataServiceDataKey: [CBUUID(string: "FEAA"): Data([0x10, 0x20])],
            CBAdvertisementDataSolicitedServiceUUIDsKey: [CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")],
            CBAdvertisementDataTxPowerLevelKey: NSNumber(value: -8),
            CBAdvertisementDataIsConnectable: NSNumber(value: true),
        ])
        #expect(advertisement.localName() == "Sensor")
        #expect(advertisement.manufacturerData() == [0x4C, 0x00, 0x02, 0x15])
        #expect(advertisement.companyIdentifier == CompanyIdentifier(rawValue: 0x004C))
        #expect(try advertisement.serviceUUIDs() == [.bit16(0x180D), .bit16(0x180F)])
        #expect(try advertisement.serviceDataUUIDs() == [.bit16(0xFEAA)])
        #expect(advertisement.serviceData(.bit16(0xFEAA)) == [0x10, 0x20])
        #expect(advertisement.serviceData(.bit16(0x180D)) == nil)
        #expect(try advertisement.solicitedServiceUUIDs().map(\.rawValue) == ["6E400001-B5A3-F393-E0A9-E50E24DCCA9E"])
        #expect(advertisement.txPowerLevel() == -8)
        #expect(advertisement.isConnectable() == 1)
    }

    @Test func serviceDataInAnyForm() throws {
        let advertisement = DarwinAdvertisement([
            CBAdvertisementDataServiceDataKey: [CBUUID(string: "FEAA"): Data([0x01])],
        ])
        let full = try #require(BluetoothUUID(rawValue: "0000FEAA-0000-1000-8000-00805F9B34FB"))
        #expect(advertisement.serviceData(full) == [0x01])
        #expect(advertisement.serviceData(.bit32(0xFEAA)) == [0x01])
    }

    @Test func absentFields() throws {
        let advertisement = DarwinAdvertisement([:])
        #expect(advertisement.localName() == nil)
        #expect(advertisement.manufacturerData() == nil)
        #expect(advertisement.companyIdentifier == nil)
        #expect(try advertisement.serviceUUIDs().isEmpty)
        #expect(try advertisement.serviceDataUUIDs().isEmpty)
        #expect(try advertisement.solicitedServiceUUIDs().isEmpty)
        #expect(advertisement.txPowerLevel() == .min)
        #expect(advertisement.isConnectable() == -1)
    }

    @Test func notConnectable() {
        let advertisement = DarwinAdvertisement([CBAdvertisementDataIsConnectable: NSNumber(value: false)])
        #expect(advertisement.isConnectable() == 0)
    }
}

// MARK: - Scans

@Suite struct ScanRequestTests {

    let heartRate = ScanRequest(services: [.bit16(0x180D)], allowDuplicates: false)
    let battery = ScanRequest(services: [.bit16(0x180F)], allowDuplicates: false)
    let everything = ScanRequest(services: [], allowDuplicates: false)

    @Test func noRequestsNoScan() {
        #expect(ScanRequest.combined([]) == nil)
    }

    @Test func oneRequestRunsAsIs() {
        #expect(ScanRequest.combined([heartRate]) == heartRate)
    }

    @Test func unionOfServices() {
        let full = ScanRequest(services: [BluetoothUUID(rawValue: "0000180D-0000-1000-8000-00805F9B34FB")!], allowDuplicates: true)
        let combined = ScanRequest.combined([heartRate, battery, full])
        #expect(combined == ScanRequest(services: [.bit16(0x180D), .bit16(0x180F)], allowDuplicates: true))
    }

    @Test func anyScanForAllScansForAll() {
        #expect(ScanRequest.combined([heartRate, everything]) == everything)
    }

    @Test func filtersByServiceWhenTheScanIsBroader() {
        let active = ScanRequest.combined([heartRate, battery])!
        #expect(heartRate.accepts(advertised: [.bit16(0x180D)], isRepeat: false, active: active))
        #expect(!heartRate.accepts(advertised: [.bit16(0x180F)], isRepeat: false, active: active))
        #expect(!heartRate.accepts(advertised: [], isRepeat: false, active: active))
        #expect(everything.accepts(advertised: [], isRepeat: false, active: everything))
    }

    @Test func trustsCoreBluetoothsOwnFilter() {
        // The advertisement may carry the UUID where this host doesn't look.
        #expect(heartRate.accepts(advertised: [], isRepeat: false, active: heartRate))
    }

    @Test func dropsOnlyRepeatsAnotherCentralAskedFor() {
        let duplicates = ScanRequest(services: [], allowDuplicates: true)
        let active = ScanRequest.combined([everything, duplicates])!
        #expect(!everything.accepts(advertised: [], isRepeat: true, active: active))
        #expect(duplicates.accepts(advertised: [], isRepeat: true, active: active))
        // CoreBluetooth repeats a peripheral without duplicates only when
        // its advertisement changes, such as a scan response.
        #expect(everything.accepts(advertised: [], isRepeat: true, active: everything))
    }
}

// MARK: - Timeouts

@Suite struct ConnectionTimeoutTests {

    /// A scheduler the test fires by hand.
    final class ManualScheduler {
        var timers: [(milliseconds: Int32, body: () -> Void, cancelled: Bool)] = []

        func schedule(_ milliseconds: Int32, _ body: @escaping () -> Void) -> () -> Void {
            let index = timers.count
            timers.append((milliseconds, body, false))
            return { self.timers[index].cancelled = true }
        }

        func fire(_ index: Int) {
            timers[index].body()
        }
    }

    let peripheral = UUID()

    @Test func firesOnce() {
        let scheduler = ManualScheduler()
        let timeouts = ConnectionTimeouts(schedule: scheduler.schedule)
        var fired = 0
        timeouts.start(peripheral, milliseconds: 5_000) { fired += 1 }
        #expect(scheduler.timers.first?.milliseconds == 5_000)
        #expect(timeouts.isRunning(peripheral))
        scheduler.fire(0)
        scheduler.fire(0)
        #expect(fired == 1)
        #expect(!timeouts.isRunning(peripheral))
    }

    @Test func noTimeoutForZero() {
        let scheduler = ManualScheduler()
        let timeouts = ConnectionTimeouts(schedule: scheduler.schedule)
        timeouts.start(peripheral, milliseconds: 0) { Issue.record("fired") }
        timeouts.start(peripheral, milliseconds: -1) { Issue.record("fired") }
        #expect(scheduler.timers.isEmpty)
        #expect(!timeouts.isRunning(peripheral))
    }

    @Test func cancelledTimerDoesNothing() {
        let scheduler = ManualScheduler()
        let timeouts = ConnectionTimeouts(schedule: scheduler.schedule)
        timeouts.start(peripheral, milliseconds: 100) { Issue.record("fired") }
        timeouts.cancel(peripheral)
        #expect(scheduler.timers[0].cancelled)
        // Even if the platform timer fires anyway.
        scheduler.fire(0)
    }

    @Test func restartReplacesTheTimer() {
        let scheduler = ManualScheduler()
        let timeouts = ConnectionTimeouts(schedule: scheduler.schedule)
        var fired: [String] = []
        timeouts.start(peripheral, milliseconds: 100) { fired.append("first") }
        timeouts.start(peripheral, milliseconds: 200) { fired.append("second") }
        #expect(scheduler.timers[0].cancelled)
        scheduler.fire(0)
        scheduler.fire(1)
        #expect(fired == ["second"])
    }

    @Test func timersArePerPeripheral() {
        let scheduler = ManualScheduler()
        let timeouts = ConnectionTimeouts(schedule: scheduler.schedule)
        let first = peripheral
        let other = UUID()
        var fired: [UUID] = []
        timeouts.start(first, milliseconds: 100) { fired.append(first) }
        timeouts.start(other, milliseconds: 100) { fired.append(other) }
        timeouts.cancel(first)
        scheduler.fire(0)
        scheduler.fire(1)
        #expect(fired == [other])
        timeouts.start(first, milliseconds: 100) { }
        timeouts.cancelAll()
        // The timer that fired has nothing left to cancel.
        #expect(scheduler.timers.map(\.cancelled) == [true, false, true])
    }

    @Test @MainActor func mainQueueTimerFires() async {
        let identifier = peripheral
        let timeouts = ConnectionTimeouts()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            timeouts.start(identifier, milliseconds: 10) {
                continuation.resume()
            }
        }
        #expect(!timeouts.isRunning(identifier))
    }
}

// MARK: - Bookkeeping

@Suite struct BookkeepingTests {

    final class Target { }

    @Test func pendingOperationsAnswerInOrderPerKey() {
        let a = Target(), b = Target(), c = Target()
        let keyA = ObjectIdentifier(a), keyB = ObjectIdentifier(b)
        var pending = PendingOperations<Target>()
        pending.add(a, key: keyA)
        pending.add(b, key: keyB)
        pending.add(c, key: keyA)
        #expect(pending.take(keyA) === a)
        #expect(pending.take(keyA) === c)
        #expect(pending.take(keyA) == nil)
        #expect(pending.count == 1)
        #expect(pending.takeAll().map(ObjectIdentifier.init) == [keyB])
        #expect(pending.count == 0)
    }

    @Test func weakMapDoesNotKeepValues() {
        var map = WeakMap<Int, Target>(sweepInterval: 4)
        let kept = Target()
        map.set(kept, for: 0)
        for key in 1..<3 {
            map.set(Target(), for: key)
        }
        #expect(map[0] === kept)
        #expect(map[1] == nil)
        // The fourth insertion sweeps the dead entries.
        let last = Target()
        map.set(last, for: 3)
        #expect(map.count == 2)
        #expect(map[3] === last)
    }
}

// MARK: - Central before authorization

/// A `CentralHub` whose authorization is undecided never creates its
/// manager, so these run without CoreBluetooth prompting.
@Suite @MainActor struct CentralTests {

    let hub = CentralHub(authorization: { .notDetermined })

    @Test func makeReportsUnknownWithoutAManager() async {
        let delegate = RecordingCentralDelegate()
        let central = DarwinCentral.make(delegate, hub: hub)
        #expect(hub.manager == nil)
        #expect(central.state() == CentralState.unknown.rawValue)
        #expect(hub.liveCentrals.count == 1)
        await drainMainQueue()
        #expect(delegate.events == ["state 0"])
    }

    @Test func scanFailsUnauthorized() async {
        let delegate = RecordingCentralDelegate()
        let central = DarwinCentral(delegate: delegate, hub: hub)
        central.scan(services: [.bit16(0x180D)], allowDuplicates: false, mode: ScanMode.lowLatency.rawValue)
        #expect(!central.isScanning())
        #expect(delegate.events.isEmpty, "reported after the call returns")
        await drainMainQueue()
        #expect(delegate.events == ["stopScanning \(BluetoothError.unauthorized.rawValue)"])
        central.stopScan()
        #expect(hub.manager == nil)
    }

    @Test func foreignPeripheralsAreInvalid() async {
        let delegate = RecordingCentralDelegate()
        let central = DarwinCentral(delegate: delegate, hub: hub)
        let peripheral = ForeignPeripheral()
        central.connect(peripheral, timeout: 1_000)
        central.cancelConnection(peripheral)
        await drainMainQueue()
        let invalid = BluetoothError.invalidParameters.rawValue
        #expect(delegate.events == ["failToConnect \(invalid)", "disconnect \(invalid)"])
        #expect(delegate.peripherals.allSatisfy { $0 === peripheral })
    }

    @Test func nothingToRetrieveBeforeAuthorization() {
        let central = DarwinCentral(delegate: RecordingCentralDelegate(), hub: hub)
        #expect(central.retrievePeripherals([UUID().uuidString, "not a uuid"]).isEmpty)
        #expect(central.retrieveConnectedPeripherals([.bit16(0x180D)]).isEmpty)
        #expect(hub.manager == nil)
    }

    @Test func centralsAreTrackedWeakly() {
        var central: DarwinCentral? = DarwinCentral(delegate: RecordingCentralDelegate(), hub: hub)
        hub.add(central!)
        #expect(hub.liveCentrals.count == 1)
        central = nil
        #expect(hub.liveCentrals.isEmpty)
    }
}

/// Waits for blocks already queued on the main queue.
@MainActor
func drainMainQueue() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

final class RecordingCentralDelegate: CentralDelegate {

    var events: [String] = []

    var peripherals: [AnyObject] = []

    func didChangeAuthorization(_ central: any Central, status: Int32) {
        events.append("authorization \(status)")
    }

    func didUpdateState(_ central: any Central, state: Int32) {
        events.append("state \(state)")
    }

    func didDiscover(_ central: any Central, peripheral: any Peripheral, advertisement: any Advertisement, rssi: Int32) {
        events.append("discover \(rssi)")
        peripherals.append(peripheral)
    }

    func didStopScanning(_ central: any Central, error: Int32) {
        events.append("stopScanning \(error)")
    }

    func didConnect(_ central: any Central, peripheral: any Peripheral) {
        events.append("connect")
        peripherals.append(peripheral)
    }

    func didFailToConnect(_ central: any Central, peripheral: any Peripheral, error: Int32) {
        events.append("failToConnect \(error)")
        peripherals.append(peripheral)
    }

    func didDisconnect(_ central: any Central, peripheral: any Peripheral, error: Int32) {
        events.append("disconnect \(error)")
        peripherals.append(peripheral)
    }
}

/// A peripheral this host didn't make.
final class ForeignPeripheral: Peripheral {
    func identifier() -> String { "AA:BB:CC:DD:EE:FF" }
    func name() -> String? { nil }
    func state() -> Int32 { 0 }
    func setDelegate(_ delegate: (any PeripheralDelegate)?) { }
    func discoverServices(_ uuids: [BluetoothUUID]) { }
    func services() -> [any Service] { [] }
    func discoverCharacteristics(_ uuids: [BluetoothUUID], for service: any Service) { }
    func discoverDescriptors(for characteristic: any Characteristic) { }
    func readValue(_ characteristic: any Characteristic) { }
    func writeValue(_ value: [UInt8], for characteristic: any Characteristic, type: Int32) { }
    func setNotifyValue(_ enabled: Bool, for characteristic: any Characteristic) { }
    func readDescriptor(_ descriptor: any Descriptor) { }
    func writeDescriptor(_ value: [UInt8], for descriptor: any Descriptor) { }
    func readRSSI() { }
    func maximumWriteLength(_ type: Int32) -> Int32 { 20 }
    func canSendWriteWithoutResponse() -> Bool { true }
}

// MARK: - Permission

@Suite @MainActor struct PermissionTests {

    @Test(arguments: [
        (CBManagerAuthorization.notDetermined, PermissionStatus.notDetermined),
        (.restricted, .restricted),
        (.denied, .denied),
        (.allowedAlways, .granted),
    ])
    func statusNeverPrompts(_ authorization: CBManagerAuthorization, _ expected: PermissionStatus) {
        let hub = CentralHub(authorization: { authorization })
        #expect(BluetoothPermission(hub: hub).status() == expected)
        #expect(hub.manager == nil)
    }

    @Test(arguments: [
        (CBManagerAuthorization.restricted, PermissionStatus.restricted),
        (.denied, .denied),
        (.allowedAlways, .granted),
    ])
    func decidedRequestCompletesAtOnce(_ authorization: CBManagerAuthorization, _ expected: PermissionStatus) {
        let hub = CentralHub(authorization: { authorization })
        var result: PermissionStatus?
        BluetoothPermission(hub: hub).request { result = $0 }
        #expect(result == expected)
        #expect(hub.manager == nil)
    }
}

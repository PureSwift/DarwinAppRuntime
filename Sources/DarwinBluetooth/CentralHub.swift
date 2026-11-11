import CoreBluetooth
import DarwinHost
import DynamicBluetooth
import Foundation

/// The process's one `CBCentralManager`, shared by every `DarwinCentral`
/// and by the `.bluetooth` permission provider.
///
/// - The manager is created lazily: creating one shows the permission
///   prompt when authorization isn't decided.
/// - It runs on the main queue, and routes CoreBluetooth's events to the
///   centrals they concern.
/// - It keeps one `DarwinPeripheral` per `CBPeripheral` while both live,
///   and holds the peripherals a central is connecting, connected or
///   disconnecting, as CoreBluetooth requires.
final class CentralHub: NSObject, CBCentralManagerDelegate {

    nonisolated(unsafe) static let shared = CentralHub()

    /// The app's authorization; never prompts. Replaceable in tests.
    let authorization: () -> CBManagerAuthorization

    private(set) var manager: CBCentralManager?

    /// The authorization last reported, to tell when it changes.
    private var lastAuthorization: CBManagerAuthorization?

    private var centrals: [Weak<DarwinCentral>] = []

    private var peripherals = WeakMap<UUID, DarwinPeripheral>()

    /// Peripherals some central holds a connection to.
    private var held: [UUID: DarwinPeripheral] = [:]

    /// `requestAuthorization` calls waiting for the user.
    private var authorizationWaiters: [(CBManagerAuthorization) -> Void] = []

    /// The scan running on the manager, if any.
    private(set) var activeScan: ScanRequest?

    init(authorization: @escaping () -> CBManagerAuthorization = { CBManager.authorization }) {
        self.authorization = authorization
    }

    // MARK: Manager

    /// Creates the manager if it doesn't exist. This shows the permission
    /// prompt if authorization isn't decided.
    func activate() {
        guard manager == nil else { return }
        lastAuthorization = authorization()
        // No power alert: only `requestAuthorization` may show system UI.
        manager = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionShowPowerAlertKey: false,
        ])
    }

    /// Creates the manager if that can't prompt.
    func activateIfDecided() {
        if authorization() != .notDetermined {
            activate()
        }
    }

    /// Calls `completion` with the authorization once it's decided:
    /// at once if it is, otherwise after prompting.
    func requestAuthorization(_ completion: @escaping (CBManagerAuthorization) -> Void) {
        let current = authorization()
        guard current == .notDetermined else {
            completion(current)
            return
        }
        authorizationWaiters.append(completion)
        activate()
    }

    /// The radio's state; `nil` before the manager exists.
    var state: CBManagerState? {
        manager?.state
    }

    /// Why operations can't run yet, or `nil` when they can.
    var readinessError: BluetoothError? {
        CoreBluetoothMapping.readinessError(state: state, authorization: authorization())
    }

    // MARK: Centrals

    func add(_ central: DarwinCentral) {
        centrals.removeAll { $0.value == nil }
        centrals.append(Weak(central))
    }

    var liveCentrals: [DarwinCentral] {
        centrals.compactMap(\.value)
    }

    /// A central went away: its scan stops, and connections no other
    /// central holds are cancelled.
    func centralEnded(holding peripherals: [DarwinPeripheral]) {
        centrals.removeAll { $0.value == nil }
        updateScan()
        for peripheral in peripherals {
            cancelIfUnused(peripheral)
        }
    }

    // MARK: Peripherals

    /// The one wrapper for `peripheral`.
    func wrapper(for peripheral: CBPeripheral) -> DarwinPeripheral {
        let identifier = peripheral.identifier
        if let held = held[identifier], held.peripheral === peripheral {
            return held
        }
        if let existing = peripherals[identifier], existing.peripheral === peripheral {
            return existing
        }
        let wrapper = DarwinPeripheral(peripheral)
        peripherals.set(wrapper, for: identifier)
        return wrapper
    }

    func hold(_ peripheral: DarwinPeripheral) {
        held[peripheral.peripheralID] = peripheral
    }

    func isHeld(_ identifier: UUID) -> Bool {
        liveCentrals.contains { $0.holds(identifier) }
    }

    func releaseIfUnused(_ peripheral: DarwinPeripheral) {
        if !isHeld(peripheral.peripheralID) {
            held[peripheral.peripheralID] = nil
        }
    }

    /// Cancels the CoreBluetooth connection if no central holds it.
    func cancelIfUnused(_ peripheral: DarwinPeripheral) {
        guard !isHeld(peripheral.peripheralID) else { return }
        held[peripheral.peripheralID] = nil
        if peripheral.peripheral.state != .disconnected {
            manager?.cancelPeripheralConnection(peripheral.peripheral)
        }
    }

    func retrievePeripherals(_ identifiers: [UUID]) -> [DarwinPeripheral] {
        guard let manager else {
            AppHost.logger.info("Bluetooth retrievePeripherals before authorization: no peripherals")
            return []
        }
        return manager.retrievePeripherals(withIdentifiers: identifiers).map(wrapper(for:))
    }

    func retrieveConnectedPeripherals(_ services: [CBUUID]) -> [DarwinPeripheral] {
        guard let manager else {
            AppHost.logger.info("Bluetooth retrieveConnectedPeripherals before authorization: no peripherals")
            return []
        }
        return manager.retrieveConnectedPeripherals(withServices: services).map(wrapper(for:))
    }

    func connect(_ peripheral: DarwinPeripheral) {
        hold(peripheral)
        manager?.connect(peripheral.peripheral, options: nil)
    }

    func cancelConnection(_ peripheral: DarwinPeripheral) {
        manager?.cancelPeripheralConnection(peripheral.peripheral)
    }

    // MARK: Scanning

    /// Runs the scan that satisfies every scanning central, or stops it.
    func updateScan() {
        guard let manager, manager.state == .poweredOn else {
            activeScan = nil
            return
        }
        let combined = ScanRequest.combined(liveCentrals.compactMap(\.scanRequest))
        guard combined != activeScan else { return }
        activeScan = combined
        if let combined {
            let services = combined.services.isEmpty ? nil : combined.services.map(CoreBluetoothMapping.cbUUID)
            manager.scanForPeripherals(withServices: services, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: combined.allowDuplicates,
            ])
        } else {
            manager.stopScan()
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let authorization = self.authorization()
        let centrals = liveCentrals
        if authorization != lastAuthorization {
            lastAuthorization = authorization
            for central in centrals {
                central.authorizationChanged(authorization)
            }
        }
        if authorization != .notDetermined, !authorizationWaiters.isEmpty {
            let waiters = authorizationWaiters
            authorizationWaiters = []
            for waiter in waiters {
                waiter(authorization)
            }
        }
        let state = central.state
        for central in centrals {
            central.stateChanged(state)
        }
        guard state != .poweredOn else { return }
        // Scans and connections don't survive the radio leaving poweredOn,
        // and CoreBluetooth reports neither ending.
        activeScan = nil
        let error = CoreBluetoothMapping.readinessError(state: state, authorization: authorization) ?? .poweredOff
        let peripherals = Array(held.values)
        for peripheral in peripherals {
            peripheral.connectionEnded()
        }
        for central in centrals {
            central.radioStopped(error)
        }
        held = [:]
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let activeScan else { return }
        let wrapper = wrapper(for: peripheral)
        let advertisement = DarwinAdvertisement(advertisementData)
        let rssi = CoreBluetoothMapping.rssi(RSSI)
        for central in liveCentrals {
            central.discovered(wrapper, advertisement: advertisement, rssi: rssi, active: activeScan)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let wrapper = wrapper(for: peripheral)
        for central in liveCentrals {
            central.didConnect(wrapper)
        }
        // Every attempt was cancelled or timed out before it completed.
        cancelIfUnused(wrapper)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let wrapper = wrapper(for: peripheral)
        var code = DarwinBluetooth.errorCode(error, "connection")
        if code == 0 {
            code = BluetoothError.connectionFailed.rawValue
        }
        wrapper.connectionEnded()
        for central in liveCentrals {
            central.didFailToConnect(wrapper, error: code)
        }
        releaseIfUnused(wrapper)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let wrapper = wrapper(for: peripheral)
        let code = DarwinBluetooth.errorCode(error, "connection")
        wrapper.connectionEnded()
        for central in liveCentrals {
            central.didDisconnect(wrapper, error: code)
        }
        releaseIfUnused(wrapper)
    }
}

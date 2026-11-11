import CoreBluetooth
import DarwinHost
import DynamicBluetooth
import Foundation

/// The `Central` contract over the shared `CBCentralManager`.
///
/// - `make` never prompts: the manager is created only if authorization is
///   already decided. Until it exists, `state()` is `unknown`.
/// - `requestAuthorization()` creates it, which prompts.
/// - Operations before the radio is powered on fail at once, through the
///   delegate, with `unauthorized`, `unsupported` or `poweredOff`.
/// - `mode` in `scan` is ignored: CoreBluetooth has no scan power modes.
/// - Connection timeouts run on a main-queue timer, since
///   `CBCentralManager.connect` never times out.
///
/// Every call that reports through the delegate reports exactly once.
public final class DarwinCentral: Central {

    let delegate: any CentralDelegate

    let hub: CentralHub

    let timeouts: ConnectionTimeouts

    /// This central's scan, while it scans.
    private(set) var scanRequest: ScanRequest?

    /// Peripherals reported during this scan.
    private var seen: Set<UUID> = []

    /// Connection attempts in progress, with the number of `connect` calls
    /// waiting for each.
    private var connecting: [UUID: (peripheral: DarwinPeripheral, attempts: Int)] = [:]

    private var connected: [UUID: DarwinPeripheral] = [:]

    /// `cancelConnection` calls waiting for CoreBluetooth's disconnect.
    private var cancelling: [UUID: (peripheral: DarwinPeripheral, calls: Int)] = [:]

    init(delegate: any CentralDelegate, hub: CentralHub, timeouts: ConnectionTimeouts = ConnectionTimeouts()) {
        self.delegate = delegate
        self.hub = hub
        self.timeouts = timeouts
    }

    deinit {
        timeouts.cancelAll()
        let peripherals = connecting.values.map(\.peripheral) + Array(connected.values) + cancelling.values.map(\.peripheral)
        hub.centralEnded(holding: peripherals)
    }

    // MARK: Authorization and state

    public static func authorizationStatus() -> Int32 {
        CoreBluetoothMapping.authorization(CentralHub.shared.authorization()).rawValue
    }

    public static func make(_ delegate: any CentralDelegate) -> DarwinCentral {
        make(delegate, hub: .shared)
    }

    static func make(_ delegate: any CentralDelegate, hub: CentralHub) -> DarwinCentral {
        let central = DarwinCentral(delegate: delegate, hub: hub)
        hub.add(central)
        if hub.manager == nil {
            hub.activateIfDecided()
        }
        if hub.manager == nil || hub.state != .unknown {
            // The manager reports its first state itself once it has one.
            let state = central.state()
            DarwinBluetooth.post { [central] in
                central.delegate.didUpdateState(central, state: state)
            }
        }
        return central
    }

    /// Prompts if authorization isn't decided; the outcome arrives through
    /// `didChangeAuthorization`. If it is decided, reports it again.
    public func requestAuthorization() {
        let current = hub.authorization()
        hub.activate()
        guard current != .notDetermined else { return }
        let status = CoreBluetoothMapping.authorization(current).rawValue
        DarwinBluetooth.post { [self] in
            delegate.didChangeAuthorization(self, status: status)
        }
    }

    public func state() -> Int32 {
        guard let state = hub.state else {
            return CentralState.unknown.rawValue
        }
        return CoreBluetoothMapping.centralState(state).rawValue
    }

    // MARK: Scanning

    public func scan(services: [BluetoothUUID], allowDuplicates: Bool, mode: Int32) {
        if let error = hub.readinessError {
            DarwinBluetooth.post { [self] in
                delegate.didStopScanning(self, error: error.rawValue)
            }
            return
        }
        scanRequest = ScanRequest(services: services, allowDuplicates: allowDuplicates)
        seen = []
        hub.updateScan()
    }

    public func stopScan() {
        guard scanRequest != nil else { return }
        scanRequest = nil
        seen = []
        hub.updateScan()
    }

    public func isScanning() -> Bool {
        scanRequest != nil
    }

    // MARK: Connections

    public func connect(_ peripheral: any Peripheral, timeout: Int32) {
        guard let target = DarwinBluetooth.resolve(peripheral, as: DarwinPeripheral.self) else {
            AppHost.logger.error("Bluetooth connect: not a peripheral from this host")
            DarwinBluetooth.post { [self] in
                delegate.didFailToConnect(self, peripheral: peripheral, error: BluetoothError.invalidParameters.rawValue)
            }
            return
        }
        if let error = hub.readinessError {
            DarwinBluetooth.post { [self] in
                delegate.didFailToConnect(self, peripheral: target, error: error.rawValue)
            }
            return
        }
        let identifier = target.peripheralID
        let linkedElsewhere = connecting[identifier] == nil && cancelling[identifier] == nil && target.peripheral.state == .connected
        if connected[identifier] != nil || linkedElsewhere {
            // Already connected, for this central or another.
            connected[identifier] = target
            hub.hold(target)
            DarwinBluetooth.post { [self] in
                delegate.didConnect(self, peripheral: target)
            }
            return
        }
        connecting[identifier] = (target, (connecting[identifier]?.attempts ?? 0) + 1)
        hub.connect(target)
        timeouts.start(identifier, milliseconds: timeout) { [weak self] in
            self?.connectionTimedOut(identifier)
        }
    }

    public func cancelConnection(_ peripheral: any Peripheral) {
        guard let target = DarwinBluetooth.resolve(peripheral, as: DarwinPeripheral.self) else {
            AppHost.logger.error("Bluetooth cancelConnection: not a peripheral from this host")
            DarwinBluetooth.post { [self] in
                delegate.didDisconnect(self, peripheral: peripheral, error: BluetoothError.invalidParameters.rawValue)
            }
            return
        }
        let identifier = target.peripheralID
        timeouts.cancel(identifier)
        // A pending attempt ends with this disconnect, not a failure.
        connecting[identifier] = nil
        connected[identifier] = nil
        if hub.isHeld(identifier) || target.peripheral.state == .disconnected {
            // Another central keeps the link, or there is none: nothing for
            // CoreBluetooth to report.
            hub.releaseIfUnused(target)
            DarwinBluetooth.post { [self] in
                delegate.didDisconnect(self, peripheral: target, error: 0)
            }
            return
        }
        cancelling[identifier] = (target, (cancelling[identifier]?.calls ?? 0) + 1)
        hub.cancelConnection(target)
    }

    public func retrievePeripherals(_ identifiers: [String]) -> [any Peripheral] {
        hub.retrievePeripherals(identifiers.compactMap(UUID.init(uuidString:)))
    }

    public func retrieveConnectedPeripherals(_ services: [BluetoothUUID]) -> [any Peripheral] {
        hub.retrieveConnectedPeripherals(services.map(CoreBluetoothMapping.cbUUID))
    }

    // MARK: Events from the hub

    /// Whether this central is connecting, connected or disconnecting
    /// `identifier`.
    func holds(_ identifier: UUID) -> Bool {
        connecting[identifier] != nil || connected[identifier] != nil || cancelling[identifier] != nil
    }

    func authorizationChanged(_ authorization: CBManagerAuthorization) {
        let status = CoreBluetoothMapping.authorization(authorization).rawValue
        DarwinBluetooth.deliver {
            delegate.didChangeAuthorization(self, status: status)
        }
    }

    func stateChanged(_ state: CBManagerState) {
        let state = CoreBluetoothMapping.centralState(state).rawValue
        DarwinBluetooth.deliver {
            delegate.didUpdateState(self, state: state)
        }
    }

    /// The radio left `poweredOn`: the scan and every connection end.
    func radioStopped(_ error: BluetoothError) {
        timeouts.cancelAll()
        let wasScanning = scanRequest != nil
        scanRequest = nil
        seen = []
        let attempts = connecting.values
        let links = connected.values
        let cancels = cancelling.values
        connecting = [:]
        connected = [:]
        cancelling = [:]
        DarwinBluetooth.deliver {
            if wasScanning {
                delegate.didStopScanning(self, error: error.rawValue)
            }
            for attempt in attempts {
                for _ in 0..<attempt.attempts {
                    delegate.didFailToConnect(self, peripheral: attempt.peripheral, error: error.rawValue)
                }
            }
            for peripheral in links {
                delegate.didDisconnect(self, peripheral: peripheral, error: error.rawValue)
            }
            for cancel in cancels {
                for _ in 0..<cancel.calls {
                    delegate.didDisconnect(self, peripheral: cancel.peripheral, error: 0)
                }
            }
        }
    }

    func discovered(_ peripheral: DarwinPeripheral, advertisement: DarwinAdvertisement, rssi: Int32, active: ScanRequest) {
        guard let scanRequest else { return }
        let identifier = peripheral.peripheralID
        guard scanRequest.accepts(
            advertised: advertisement.advertisedServices,
            isRepeat: seen.contains(identifier),
            active: active
        ) else { return }
        seen.insert(identifier)
        DarwinBluetooth.deliver {
            delegate.didDiscover(self, peripheral: peripheral, advertisement: advertisement, rssi: rssi)
        }
    }

    func didConnect(_ peripheral: DarwinPeripheral) {
        let identifier = peripheral.peripheralID
        guard let attempt = connecting.removeValue(forKey: identifier) else { return }
        timeouts.cancel(identifier)
        connected[identifier] = peripheral
        DarwinBluetooth.deliver {
            for _ in 0..<attempt.attempts {
                delegate.didConnect(self, peripheral: peripheral)
            }
        }
    }

    func didFailToConnect(_ peripheral: DarwinPeripheral, error: Int32) {
        let identifier = peripheral.peripheralID
        guard let attempt = connecting.removeValue(forKey: identifier) else { return }
        timeouts.cancel(identifier)
        DarwinBluetooth.deliver {
            for _ in 0..<attempt.attempts {
                delegate.didFailToConnect(self, peripheral: peripheral, error: error)
            }
        }
    }

    func didDisconnect(_ peripheral: DarwinPeripheral, error: Int32) {
        let identifier = peripheral.peripheralID
        if let cancel = cancelling.removeValue(forKey: identifier) {
            // The disconnect this central asked for. An attempt started
            // since then is still on its way.
            DarwinBluetooth.deliver {
                for _ in 0..<cancel.calls {
                    delegate.didDisconnect(self, peripheral: peripheral, error: 0)
                }
            }
            return
        }
        timeouts.cancel(identifier)
        let attempt = connecting.removeValue(forKey: identifier)
        let wasConnected = connected.removeValue(forKey: identifier) != nil
        // Only `cancelConnection` reports `0`; CoreBluetooth reports no
        // error when this app cancelled, here on behalf of another central.
        let reason = error == 0 ? BluetoothError.peripheralDisconnected.rawValue : error
        DarwinBluetooth.deliver {
            if let attempt {
                for _ in 0..<attempt.attempts {
                    delegate.didFailToConnect(self, peripheral: peripheral, error: reason)
                }
            }
            if wasConnected {
                delegate.didDisconnect(self, peripheral: peripheral, error: reason)
            }
        }
    }

    private func connectionTimedOut(_ identifier: UUID) {
        guard let attempt = connecting.removeValue(forKey: identifier) else { return }
        hub.cancelIfUnused(attempt.peripheral)
        DarwinBluetooth.deliver {
            for _ in 0..<attempt.attempts {
                delegate.didFailToConnect(self, peripheral: attempt.peripheral, error: BluetoothError.connectionTimeout.rawValue)
            }
        }
    }
}

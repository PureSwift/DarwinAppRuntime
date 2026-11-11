import CoreBluetooth
import DarwinHost
import DynamicBluetooth
import Foundation

/// The `Peripheral` contract over a `CBPeripheral`. There is one per
/// `CBPeripheral` while both live (`CentralHub.wrapper(for:)`), and it keeps
/// one wrapper per service, characteristic and descriptor the same way.
///
/// CoreBluetooth queues GATT requests itself. This class counts the
/// requests it is waiting on, so that requests made while disconnected, or
/// outstanding when the link drops, still get their one callback, with
/// `notConnected`.
public final class DarwinPeripheral: Peripheral {

    let peripheral: CBPeripheral

    let peripheralID: UUID

    private var delegate: (any PeripheralDelegate)?

    /// CoreBluetooth's delegate. `CBPeripheral.delegate` is weak; this
    /// object owns it.
    private let observer = PeripheralObserver()

    private var serviceWrappers = WeakMap<ObjectIdentifier, DarwinService>()

    private var characteristicWrappers = WeakMap<ObjectIdentifier, DarwinCharacteristic>()

    private var descriptorWrappers = WeakMap<ObjectIdentifier, DarwinDescriptor>()

    // Requests waiting for CoreBluetooth.
    private var serviceDiscoveries = 0
    private var characteristicDiscoveries = PendingOperations<DarwinService>()
    private var descriptorDiscoveries = PendingOperations<DarwinCharacteristic>()
    private var reads = PendingOperations<DarwinCharacteristic>()
    private var writes = PendingOperations<DarwinCharacteristic>()
    private var notificationChanges = PendingOperations<DarwinCharacteristic>()
    private var descriptorReads = PendingOperations<DarwinDescriptor>()
    private var descriptorWrites = PendingOperations<DarwinDescriptor>()
    private var rssiReads = 0

    init(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        self.peripheralID = peripheral.identifier
        observer.owner = self
        peripheral.delegate = observer
    }

    deinit {
        if peripheral.delegate === observer {
            peripheral.delegate = nil
        }
    }

    private var isConnected: Bool {
        peripheral.state == .connected
    }

    // MARK: Peripheral

    public func identifier() -> String {
        peripheralID.uuidString
    }

    public func name() -> String? {
        peripheral.name
    }

    public func state() -> Int32 {
        CoreBluetoothMapping.peripheralState(peripheral.state).rawValue
    }

    public func setDelegate(_ delegate: (any PeripheralDelegate)?) {
        self.delegate = delegate
    }

    public func discoverServices(_ uuids: [BluetoothUUID]) {
        guard isConnected else {
            fail { delegate, error in delegate.didDiscoverServices(self, error: error) }
            return
        }
        serviceDiscoveries += 1
        peripheral.discoverServices(uuids.isEmpty ? nil : uuids.map(CoreBluetoothMapping.cbUUID))
    }

    public func services() -> [any Service] {
        (peripheral.services ?? []).map(wrapper(for:))
    }

    public func discoverCharacteristics(_ uuids: [BluetoothUUID], for service: any Service) {
        guard let target = own(service, as: DarwinService.self) else {
            fail(.invalidParameters) { delegate, error in
                delegate.didDiscoverCharacteristics(self, service: service, error: error)
            }
            return
        }
        guard isConnected else {
            fail { delegate, error in delegate.didDiscoverCharacteristics(self, service: target, error: error) }
            return
        }
        characteristicDiscoveries.add(target, key: ObjectIdentifier(target.service))
        peripheral.discoverCharacteristics(uuids.isEmpty ? nil : uuids.map(CoreBluetoothMapping.cbUUID), for: target.service)
    }

    public func discoverDescriptors(for characteristic: any Characteristic) {
        guard let target = own(characteristic, as: DarwinCharacteristic.self) else {
            fail(.invalidParameters) { delegate, error in
                delegate.didDiscoverDescriptors(self, characteristic: characteristic, error: error)
            }
            return
        }
        guard isConnected else {
            fail { delegate, error in delegate.didDiscoverDescriptors(self, characteristic: target, error: error) }
            return
        }
        descriptorDiscoveries.add(target, key: ObjectIdentifier(target.characteristic))
        peripheral.discoverDescriptors(for: target.characteristic)
    }

    public func readValue(_ characteristic: any Characteristic) {
        guard let target = own(characteristic, as: DarwinCharacteristic.self) else {
            fail(.invalidParameters) { delegate, error in
                delegate.didUpdateValue(self, characteristic: characteristic, value: [], error: error)
            }
            return
        }
        guard isConnected else {
            fail { delegate, error in delegate.didUpdateValue(self, characteristic: target, value: [], error: error) }
            return
        }
        reads.add(target, key: ObjectIdentifier(target.characteristic))
        peripheral.readValue(for: target.characteristic)
    }

    public func writeValue(_ value: [UInt8], for characteristic: any Characteristic, type: Int32) {
        guard let writeType = CoreBluetoothMapping.writeType(type) else {
            AppHost.logger.error("Bluetooth writeValue: unknown write type \(type, privacy: .public)")
            fail(.invalidParameters) { delegate, error in
                delegate.didWriteValue(self, characteristic: characteristic, error: error)
            }
            return
        }
        let target = own(characteristic, as: DarwinCharacteristic.self)
        if writeType == .withoutResponse {
            // Writes without response report nothing, failed or not.
            guard let target, isConnected else {
                AppHost.logger.error("Bluetooth write without response dropped: \(target == nil ? "unknown characteristic" : "not connected", privacy: .public)")
                return
            }
            peripheral.writeValue(Data(value), for: target.characteristic, type: .withoutResponse)
            return
        }
        guard let target else {
            fail(.invalidParameters) { delegate, error in
                delegate.didWriteValue(self, characteristic: characteristic, error: error)
            }
            return
        }
        guard isConnected else {
            fail { delegate, error in delegate.didWriteValue(self, characteristic: target, error: error) }
            return
        }
        writes.add(target, key: ObjectIdentifier(target.characteristic))
        peripheral.writeValue(Data(value), for: target.characteristic, type: .withResponse)
    }

    public func setNotifyValue(_ enabled: Bool, for characteristic: any Characteristic) {
        guard let target = own(characteristic, as: DarwinCharacteristic.self) else {
            fail(.invalidParameters) { delegate, error in
                delegate.didUpdateNotificationState(self, characteristic: characteristic, error: error)
            }
            return
        }
        guard isConnected else {
            fail { delegate, error in delegate.didUpdateNotificationState(self, characteristic: target, error: error) }
            return
        }
        notificationChanges.add(target, key: ObjectIdentifier(target.characteristic))
        peripheral.setNotifyValue(enabled, for: target.characteristic)
    }

    public func readDescriptor(_ descriptor: any Descriptor) {
        guard let target = own(descriptor, as: DarwinDescriptor.self) else {
            fail(.invalidParameters) { delegate, error in
                delegate.didUpdateDescriptorValue(self, descriptor: descriptor, value: [], error: error)
            }
            return
        }
        guard isConnected else {
            fail { delegate, error in delegate.didUpdateDescriptorValue(self, descriptor: target, value: [], error: error) }
            return
        }
        descriptorReads.add(target, key: ObjectIdentifier(target.descriptor))
        peripheral.readValue(for: target.descriptor)
    }

    /// CoreBluetooth raises an exception for writes to the Client
    /// Characteristic Configuration descriptor; they fail with
    /// `operationNotSupported` instead. Use `setNotifyValue`.
    public func writeDescriptor(_ value: [UInt8], for descriptor: any Descriptor) {
        guard let target = own(descriptor, as: DarwinDescriptor.self) else {
            fail(.invalidParameters) { delegate, error in
                delegate.didWriteDescriptorValue(self, descriptor: descriptor, error: error)
            }
            return
        }
        guard !CoreBluetoothMapping.isClientCharacteristicConfiguration(target.descriptor.uuid) else {
            fail(.operationNotSupported) { delegate, error in
                delegate.didWriteDescriptorValue(self, descriptor: target, error: error)
            }
            return
        }
        guard isConnected else {
            fail { delegate, error in delegate.didWriteDescriptorValue(self, descriptor: target, error: error) }
            return
        }
        descriptorWrites.add(target, key: ObjectIdentifier(target.descriptor))
        peripheral.writeValue(Data(value), for: target.descriptor)
    }

    public func readRSSI() {
        guard isConnected else {
            fail { delegate, error in delegate.didReadRSSI(self, rssi: 127, error: error) }
            return
        }
        rssiReads += 1
        peripheral.readRSSI()
    }

    public func maximumWriteLength(_ type: Int32) -> Int32 {
        guard let writeType = CoreBluetoothMapping.writeType(type) else {
            AppHost.logger.error("Bluetooth maximumWriteLength: unknown write type \(type, privacy: .public)")
            return 0
        }
        return Int32(clamping: peripheral.maximumWriteValueLength(for: writeType))
    }

    public func canSendWriteWithoutResponse() -> Bool {
        peripheral.canSendWriteWithoutResponse
    }

    // MARK: Wrappers

    func wrapper(for service: CBService) -> DarwinService {
        let key = ObjectIdentifier(service)
        if let existing = serviceWrappers[key], existing.service === service {
            return existing
        }
        let wrapper = DarwinService(service, peripheral: self)
        serviceWrappers.set(wrapper, for: key)
        return wrapper
    }

    func wrapper(for characteristic: CBCharacteristic, in service: DarwinService) -> DarwinCharacteristic {
        let key = ObjectIdentifier(characteristic)
        if let existing = characteristicWrappers[key], existing.characteristic === characteristic {
            return existing
        }
        let wrapper = DarwinCharacteristic(characteristic, service: service)
        characteristicWrappers.set(wrapper, for: key)
        return wrapper
    }

    func wrapper(for descriptor: CBDescriptor, in characteristic: DarwinCharacteristic) -> DarwinDescriptor {
        let key = ObjectIdentifier(descriptor)
        if let existing = descriptorWrappers[key], existing.descriptor === descriptor {
            return existing
        }
        let wrapper = DarwinDescriptor(descriptor, characteristic: characteristic)
        descriptorWrappers.set(wrapper, for: key)
        return wrapper
    }

    /// The wrapper for a characteristic CoreBluetooth reports, found through
    /// its service.
    func wrapper(for characteristic: CBCharacteristic) -> DarwinCharacteristic? {
        if let existing = characteristicWrappers[ObjectIdentifier(characteristic)], existing.characteristic === characteristic {
            return existing
        }
        guard let service = characteristic.service else { return nil }
        return wrapper(for: characteristic, in: wrapper(for: service))
    }

    /// This peripheral's own attribute behind a contract object, or `nil`.
    private func own<T: AttributeWrapper>(_ object: AnyObject, as type: T.Type) -> T? {
        guard let attribute = DarwinBluetooth.resolve(object, as: type) else {
            AppHost.logger.error("Bluetooth: \(String(describing: type), privacy: .public) isn't from this host")
            return nil
        }
        guard attribute.owningPeripheral === self else {
            AppHost.logger.error("Bluetooth: \(String(describing: type), privacy: .public) belongs to another peripheral")
            return nil
        }
        return attribute
    }

    // MARK: Failures

    /// Reports a request that never reached CoreBluetooth, after the call
    /// returns.
    private func fail(
        _ error: BluetoothError = .notConnected,
        _ report: @escaping (any PeripheralDelegate, Int32) -> Void
    ) {
        DarwinBluetooth.post { [self] in
            guard let delegate else { return }
            report(delegate, error.rawValue)
        }
    }

    /// The link dropped or never came up: every outstanding request fails
    /// with `notConnected`, since CoreBluetooth won't answer them.
    func connectionEnded() {
        let services = serviceDiscoveries
        let characteristics = characteristicDiscoveries.takeAll()
        let descriptors = descriptorDiscoveries.takeAll()
        let failedReads = reads.takeAll()
        let failedWrites = writes.takeAll()
        let notifications = notificationChanges.takeAll()
        let failedDescriptorReads = descriptorReads.takeAll()
        let failedDescriptorWrites = descriptorWrites.takeAll()
        let signalReads = rssiReads
        serviceDiscoveries = 0
        rssiReads = 0
        guard let delegate else { return }
        let error = BluetoothError.notConnected.rawValue
        DarwinBluetooth.deliver {
            for _ in 0..<services {
                delegate.didDiscoverServices(self, error: error)
            }
            for service in characteristics {
                delegate.didDiscoverCharacteristics(self, service: service, error: error)
            }
            for characteristic in descriptors {
                delegate.didDiscoverDescriptors(self, characteristic: characteristic, error: error)
            }
            for characteristic in failedReads {
                delegate.didUpdateValue(self, characteristic: characteristic, value: [], error: error)
            }
            for characteristic in failedWrites {
                delegate.didWriteValue(self, characteristic: characteristic, error: error)
            }
            for characteristic in notifications {
                delegate.didUpdateNotificationState(self, characteristic: characteristic, error: error)
            }
            for descriptor in failedDescriptorReads {
                delegate.didUpdateDescriptorValue(self, descriptor: descriptor, value: [], error: error)
            }
            for descriptor in failedDescriptorWrites {
                delegate.didWriteDescriptorValue(self, descriptor: descriptor, error: error)
            }
            for _ in 0..<signalReads {
                delegate.didReadRSSI(self, rssi: 127, error: error)
            }
        }
    }

    // MARK: CoreBluetooth events

    /// Logs a CoreBluetooth answer to a request this peripheral isn't
    /// waiting on, such as one that arrives after the link dropped.
    private func unexpected(_ event: StaticString, _ error: Error?) {
        AppHost.logger.debug("Bluetooth \(event, privacy: .public) dropped: no request waiting (\(String(describing: error), privacy: .public))")
    }

    fileprivate func didDiscoverServices(_ error: Error?) {
        guard serviceDiscoveries > 0 else { return unexpected("service discovery", error) }
        serviceDiscoveries -= 1
        let code = DarwinBluetooth.errorCode(error, "service discovery")
        DarwinBluetooth.deliver {
            delegate?.didDiscoverServices(self, error: code)
        }
    }

    fileprivate func didDiscoverCharacteristics(for service: CBService, _ error: Error?) {
        guard let target = characteristicDiscoveries.take(ObjectIdentifier(service)) else {
            return unexpected("characteristic discovery", error)
        }
        let code = DarwinBluetooth.errorCode(error, "characteristic discovery")
        DarwinBluetooth.deliver {
            delegate?.didDiscoverCharacteristics(self, service: target, error: code)
        }
    }

    fileprivate func didDiscoverDescriptors(for characteristic: CBCharacteristic, _ error: Error?) {
        guard let target = descriptorDiscoveries.take(ObjectIdentifier(characteristic)) else {
            return unexpected("descriptor discovery", error)
        }
        let code = DarwinBluetooth.errorCode(error, "descriptor discovery")
        DarwinBluetooth.deliver {
            delegate?.didDiscoverDescriptors(self, characteristic: target, error: code)
        }
    }

    fileprivate func didUpdateValue(for characteristic: CBCharacteristic, _ error: Error?) {
        // A read's answer, or a notification when no read is waiting.
        let read = reads.take(ObjectIdentifier(characteristic))
        guard let target = read ?? (error == nil ? wrapper(for: characteristic) : nil) else {
            return unexpected("characteristic value", error)
        }
        let code = DarwinBluetooth.errorCode(error, "characteristic read")
        let value = code == 0 ? characteristic.value.map { [UInt8]($0) } ?? [] : []
        DarwinBluetooth.deliver {
            delegate?.didUpdateValue(self, characteristic: target, value: value, error: code)
        }
    }

    fileprivate func didWriteValue(for characteristic: CBCharacteristic, _ error: Error?) {
        guard let target = writes.take(ObjectIdentifier(characteristic)) else {
            return unexpected("characteristic write", error)
        }
        let code = DarwinBluetooth.errorCode(error, "characteristic write")
        DarwinBluetooth.deliver {
            delegate?.didWriteValue(self, characteristic: target, error: code)
        }
    }

    fileprivate func didUpdateNotificationState(for characteristic: CBCharacteristic, _ error: Error?) {
        guard let target = notificationChanges.take(ObjectIdentifier(characteristic)) else {
            return unexpected("notification state", error)
        }
        let code = DarwinBluetooth.errorCode(error, "notification state")
        DarwinBluetooth.deliver {
            delegate?.didUpdateNotificationState(self, characteristic: target, error: code)
        }
    }

    fileprivate func didUpdateValue(for descriptor: CBDescriptor, _ error: Error?) {
        guard let target = descriptorReads.take(ObjectIdentifier(descriptor)) else {
            return unexpected("descriptor read", error)
        }
        let code = DarwinBluetooth.errorCode(error, "descriptor read")
        let value = code == 0 ? CoreBluetoothMapping.descriptorBytes(descriptor.value) ?? [] : []
        DarwinBluetooth.deliver {
            delegate?.didUpdateDescriptorValue(self, descriptor: target, value: value, error: code)
        }
    }

    fileprivate func didWriteValue(for descriptor: CBDescriptor, _ error: Error?) {
        guard let target = descriptorWrites.take(ObjectIdentifier(descriptor)) else {
            return unexpected("descriptor write", error)
        }
        let code = DarwinBluetooth.errorCode(error, "descriptor write")
        DarwinBluetooth.deliver {
            delegate?.didWriteDescriptorValue(self, descriptor: target, error: code)
        }
    }

    fileprivate func didReadRSSI(_ rssi: NSNumber, _ error: Error?) {
        guard rssiReads > 0 else { return unexpected("RSSI read", error) }
        rssiReads -= 1
        let code = DarwinBluetooth.errorCode(error, "RSSI read")
        let value = code == 0 ? CoreBluetoothMapping.rssi(rssi) : 127
        DarwinBluetooth.deliver {
            delegate?.didReadRSSI(self, rssi: value, error: code)
        }
    }

    fileprivate func isReadyToSendWriteWithoutResponse() {
        DarwinBluetooth.deliver {
            delegate?.isReadyToSendWriteWithoutResponse(self)
        }
    }

    fileprivate func didModifyServices() {
        DarwinBluetooth.deliver {
            delegate?.didModifyServices(self)
        }
    }

    fileprivate func didUpdateName() {
        DarwinBluetooth.deliver {
            delegate?.didUpdateName(self)
        }
    }
}

/// Receives a `CBPeripheral`'s events for its `DarwinPeripheral`. Separate
/// from it so the contract's methods don't meet `NSObject`'s.
private final class PeripheralObserver: NSObject, CBPeripheralDelegate {

    weak var owner: DarwinPeripheral?

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        owner?.didDiscoverServices(error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        owner?.didDiscoverCharacteristics(for: service, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        owner?.didDiscoverDescriptors(for: characteristic, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        owner?.didUpdateValue(for: characteristic, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        owner?.didWriteValue(for: characteristic, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        owner?.didUpdateNotificationState(for: characteristic, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        owner?.didUpdateValue(for: descriptor, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
        owner?.didWriteValue(for: descriptor, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        owner?.didReadRSSI(RSSI, error)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        owner?.isReadyToSendWriteWithoutResponse()
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        owner?.didModifyServices()
    }

    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        owner?.didUpdateName()
    }
}

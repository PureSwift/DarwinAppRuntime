import CoreBluetooth
import DynamicBluetooth
import DynamicRuntime
import Foundation

/// A service, characteristic or descriptor wrapper, and the peripheral it
/// belongs to.
protocol AttributeWrapper: AnyObject {

    var owningPeripheral: DarwinPeripheral { get }
}

/// The `Service` contract over a `CBService`. `DarwinPeripheral` keeps one
/// per `CBService` while both live; it keeps its peripheral alive.
public final class DarwinService: Service, AttributeWrapper {

    let service: CBService

    let owningPeripheral: DarwinPeripheral

    init(_ service: CBService, peripheral: DarwinPeripheral) {
        self.service = service
        self.owningPeripheral = peripheral
    }

    public func uuid() throws(RuntimeError) -> BluetoothUUID {
        try CoreBluetoothMapping.bluetoothUUID(service.uuid)
    }

    public func isPrimary() -> Bool {
        service.isPrimary
    }

    public func characteristics() -> [any Characteristic] {
        (service.characteristics ?? []).map { owningPeripheral.wrapper(for: $0, in: self) }
    }

    public func peripheral() -> any Peripheral {
        owningPeripheral
    }
}

/// The `Characteristic` contract over a `CBCharacteristic`. It keeps its
/// service alive.
public final class DarwinCharacteristic: Characteristic, AttributeWrapper {

    let characteristic: CBCharacteristic

    let owningService: DarwinService

    var owningPeripheral: DarwinPeripheral {
        owningService.owningPeripheral
    }

    init(_ characteristic: CBCharacteristic, service: DarwinService) {
        self.characteristic = characteristic
        self.owningService = service
    }

    public func uuid() throws(RuntimeError) -> BluetoothUUID {
        try CoreBluetoothMapping.bluetoothUUID(characteristic.uuid)
    }

    public func properties() -> Int32 {
        CoreBluetoothMapping.properties(characteristic.properties)
    }

    public func value() -> [UInt8]? {
        characteristic.value.map { [UInt8]($0) }
    }

    public func isNotifying() -> Bool {
        characteristic.isNotifying
    }

    public func descriptors() -> [any Descriptor] {
        (characteristic.descriptors ?? []).map { owningPeripheral.wrapper(for: $0, in: self) }
    }

    public func service() -> any Service {
        owningService
    }
}

/// The `Descriptor` contract over a `CBDescriptor`. It keeps its
/// characteristic alive.
public final class DarwinDescriptor: Descriptor, AttributeWrapper {

    let descriptor: CBDescriptor

    let owningCharacteristic: DarwinCharacteristic

    var owningPeripheral: DarwinPeripheral {
        owningCharacteristic.owningPeripheral
    }

    init(_ descriptor: CBDescriptor, characteristic: DarwinCharacteristic) {
        self.descriptor = descriptor
        self.owningCharacteristic = characteristic
    }

    public func uuid() throws(RuntimeError) -> BluetoothUUID {
        try CoreBluetoothMapping.bluetoothUUID(descriptor.uuid)
    }

    /// Raw bytes, re-encoded where CoreBluetooth decoded the value
    /// (`CoreBluetoothMapping.descriptorBytes`).
    public func value() -> [UInt8]? {
        CoreBluetoothMapping.descriptorBytes(descriptor.value)
    }

    public func characteristic() -> any Characteristic {
        owningCharacteristic
    }
}

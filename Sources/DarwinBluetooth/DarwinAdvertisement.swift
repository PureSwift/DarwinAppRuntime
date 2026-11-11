import CoreBluetooth
import DynamicBluetooth
import DynamicRuntime
import Foundation

/// The `Advertisement` contract over CoreBluetooth's advertisement
/// dictionary, read once when the advertisement arrives.
///
/// Service UUIDs include those in the overflow area (iOS apps advertising
/// in the background). CoreBluetooth merges the scan response into the
/// same dictionary.
public final class DarwinAdvertisement: Advertisement {

    private let name: String?

    private let manufacturer: [UInt8]?

    private let services: [CBUUID]

    private let serviceDataEntries: [(uuid: CBUUID, value: [UInt8])]

    private let solicited: [CBUUID]

    private let txPower: Int32

    private let connectable: Int32

    init(_ data: [String: Any]) {
        name = data[CBAdvertisementDataLocalNameKey] as? String
        manufacturer = (data[CBAdvertisementDataManufacturerDataKey] as? Data).map { [UInt8]($0) }
        var services = data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        for uuid in data[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [] where !services.contains(uuid) {
            services.append(uuid)
        }
        self.services = services
        let serviceData = data[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        serviceDataEntries = serviceData
            .map { (uuid: $0.key, value: [UInt8]($0.value)) }
            .sorted { $0.uuid.uuidString < $1.uuid.uuidString }
        solicited = data[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] ?? []
        txPower = (data[CBAdvertisementDataTxPowerLevelKey] as? NSNumber).map { Int32(clamping: $0.intValue) } ?? .min
        connectable = (data[CBAdvertisementDataIsConnectable] as? NSNumber).map { $0.boolValue ? 1 : 0 } ?? -1
    }

    /// Advertised service UUIDs that convert, for scan filtering.
    var advertisedServices: [BluetoothUUID] {
        services.compactMap { CoreBluetoothMapping.shortestUUID($0.uuidString) }
    }

    public func localName() -> String? {
        name
    }

    public func manufacturerData() -> [UInt8]? {
        manufacturer
    }

    public func serviceUUIDs() throws(RuntimeError) -> [BluetoothUUID] {
        try convert(services)
    }

    public func serviceDataUUIDs() throws(RuntimeError) -> [BluetoothUUID] {
        try convert(serviceDataEntries.map(\.uuid))
    }

    /// The data for `uuid`, in whichever form either side spells it.
    public func serviceData(_ uuid: BluetoothUUID) -> [UInt8]? {
        serviceDataEntries.first { entry in
            CoreBluetoothMapping.shortestUUID(entry.uuid.uuidString).map {
                CoreBluetoothMapping.sameUUID($0, uuid)
            } ?? false
        }?.value
    }

    public func solicitedServiceUUIDs() throws(RuntimeError) -> [BluetoothUUID] {
        try convert(solicited)
    }

    public func txPowerLevel() -> Int32 {
        txPower
    }

    public func isConnectable() -> Int32 {
        connectable
    }

    private func convert(_ uuids: [CBUUID]) throws(RuntimeError) -> [BluetoothUUID] {
        var converted: [BluetoothUUID] = []
        for uuid in uuids {
            converted.append(try CoreBluetoothMapping.bluetoothUUID(uuid))
        }
        return converted
    }
}

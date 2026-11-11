import CoreBluetooth
import DynamicBluetooth
import DynamicRuntime
import Foundation

/// Conversions between CoreBluetooth's types and the contract's codes.
/// Pure functions, so they can be tested without a `CBCentralManager`.
enum CoreBluetoothMapping {

    // MARK: UUIDs

    /// The Bluetooth Base UUID after its first 32 bits.
    static let baseUUIDSuffix = "-0000-1000-8000-00805F9B34FB"

    /// A contract UUID as a `CBUUID`. CoreBluetooth takes all three string
    /// forms, so the string passes straight through.
    static func cbUUID(_ uuid: BluetoothUUID) -> CBUUID {
        CBUUID(string: uuid.rawValue)
    }

    /// A `CBUUID` in the shortest form that represents it. Throws if
    /// CoreBluetooth's string isn't a valid UUID.
    static func bluetoothUUID(_ uuid: CBUUID) throws(RuntimeError) -> BluetoothUUID {
        guard let value = shortestUUID(uuid.uuidString) else {
            throw RuntimeError.thrown("invalid Bluetooth UUID \(uuid.uuidString)")
        }
        return value
    }

    /// Parses a UUID string in any of the three forms, and shortens a UUID
    /// built on the Bluetooth Base UUID: to 16-bit where the upper 16 bits
    /// are zero, otherwise to 32-bit. `nil` if the string isn't a UUID.
    static func shortestUUID(_ string: String) -> BluetoothUUID? {
        guard let uuid = BluetoothUUID(rawValue: string.uppercased()) else {
            return nil
        }
        switch uuid {
        case .bit16:
            return uuid
        case .bit32(let value):
            return value <= 0xFFFF ? .bit16(UInt16(value)) : uuid
        case .bit128:
            let raw = uuid.rawValue
            guard raw.hasSuffix(baseUUIDSuffix), let prefix = UInt32(raw.prefix(8), radix: 16) else {
                return uuid
            }
            return prefix <= 0xFFFF ? .bit16(UInt16(prefix)) : .bit32(prefix)
        }
    }

    /// Whether two UUIDs name the same UUID, whatever their forms.
    static func sameUUID(_ a: BluetoothUUID, _ b: BluetoothUUID) -> Bool {
        a.bit128 == b.bit128
    }

    /// The Client Characteristic Configuration descriptor (0x2902), which
    /// CoreBluetooth refuses to write directly.
    static func isClientCharacteristicConfiguration(_ uuid: CBUUID) -> Bool {
        uuid == CBUUID(string: CBUUIDClientCharacteristicConfigurationString)
    }

    // MARK: States

    static func centralState(_ state: CBManagerState) -> CentralState {
        switch state {
        case .unknown: return .unknown
        case .resetting: return .resetting
        case .unsupported: return .unsupported
        case .unauthorized: return .unauthorized
        case .poweredOff: return .poweredOff
        case .poweredOn: return .poweredOn
        @unknown default: return .unknown
        }
    }

    static func authorization(_ authorization: CBManagerAuthorization) -> BluetoothAuthorization {
        switch authorization {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .allowedAlways: return .allowed
        @unknown default: return .denied
        }
    }

    static func permission(_ authorization: CBManagerAuthorization) -> PermissionStatus {
        switch authorization {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .allowedAlways: return .granted
        @unknown default: return .denied
        }
    }

    static func peripheralState(_ state: CBPeripheralState) -> PeripheralState {
        switch state {
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .connected: return .connected
        case .disconnecting: return .disconnecting
        @unknown default: return .disconnected
        }
    }

    /// Why an operation can't run yet, or `nil` when the radio is ready.
    /// `state` is `nil` before the manager exists.
    static func readinessError(state: CBManagerState?, authorization: CBManagerAuthorization) -> BluetoothError? {
        guard authorization == .allowedAlways else {
            return .unauthorized
        }
        switch state {
        case .poweredOn?: return nil
        case .unauthorized?: return .unauthorized
        case .unsupported?: return .unsupported
        default: return .poweredOff
        }
    }

    /// A `WriteType` raw value as CoreBluetooth's write type.
    static func writeType(_ rawValue: Int32) -> CBCharacteristicWriteType? {
        switch WriteType(rawValue: rawValue) {
        case .withResponse?: return .withResponse
        case .withoutResponse?: return .withoutResponse
        case nil: return nil
        }
    }

    // MARK: Values

    /// `CBCharacteristicProperties` as a `GATTCharacteristicProperties` raw
    /// value. CoreBluetooth's own flags above bit 7 (encryption required for
    /// notify and indicate) aren't GATT properties and are dropped.
    static func properties(_ properties: CBCharacteristicProperties) -> Int32 {
        Int32(properties.rawValue & 0xFF)
    }

    /// RSSI in dBm; CoreBluetooth already reports `127` when unavailable.
    static func rssi(_ rssi: NSNumber) -> Int32 {
        Int32(clamping: rssi.intValue)
    }

    /// A descriptor's value as raw bytes. CoreBluetooth decodes some
    /// descriptors: numbers for the 16-bit ones (Extended Properties, Client
    /// and Server Characteristic Configuration), which become 2 bytes,
    /// little-endian as on the wire; a string for the User Description,
    /// which becomes UTF-8; `Data` for the rest.
    static func descriptorBytes(_ value: Any?) -> [UInt8]? {
        guard let value else { return nil }
        if let data = value as? Data {
            return [UInt8](data)
        }
        if let string = value as? String {
            return Array(string.utf8)
        }
        if let number = value as? NSNumber {
            let value = number.uint16Value
            return [UInt8(value & 0xFF), UInt8(value >> 8)]
        }
        return nil
    }

    // MARK: Errors

    /// A CoreBluetooth error as a `BluetoothError` raw value: `0` for `nil`,
    /// `unknown` for anything without a counterpart.
    ///
    /// ATT errors from the peripheral are `attribute` plus the ATT code,
    /// except Insufficient Authentication (0x05) and Insufficient Encryption
    /// (0x0F), which are `insufficientAuthentication`: the system pairs and
    /// the app retries.
    static func errorCode(_ error: Error?) -> Int32 {
        guard let error else { return 0 }
        let nsError = error as NSError
        switch nsError.domain {
        case CBErrorDomain:
            return (cbError(nsError.code) ?? .unknown).rawValue
        case CBATTErrorDomain:
            return attributeError(nsError.code)
        default:
            return BluetoothError.unknown.rawValue
        }
    }

    static func attributeError(_ code: Int) -> Int32 {
        switch code {
        case CBATTError.insufficientAuthentication.rawValue, CBATTError.insufficientEncryption.rawValue:
            return BluetoothError.insufficientAuthentication.rawValue
        case 1...0xFF:
            return BluetoothError.attribute.rawValue + Int32(code)
        default:
            return BluetoothError.unknown.rawValue
        }
    }

    /// `CBError.Code` as a `BluetoothError`; `nil` if there's no counterpart.
    static func cbError(_ code: Int) -> BluetoothError? {
        guard let code = CBError.Code(rawValue: code) else { return nil }
        switch code {
        case .invalidParameters, .invalidHandle, .uuidNotAllowed:
            return .invalidParameters
        case .notConnected:
            return .notConnected
        case .operationCancelled:
            return .operationCancelled
        case .connectionTimeout:
            return .connectionTimeout
        case .peripheralDisconnected:
            return .peripheralDisconnected
        case .connectionFailed, .unknownDevice:
            return .connectionFailed
        case .connectionLimitReached, .tooManyLEPairedDevices:
            return .connectionLimitReached
        case .operationNotSupported:
            return .operationNotSupported
        case .peerRemovedPairingInformation, .encryptionTimedOut:
            return .insufficientAuthentication
        default:
            // unknown, outOfSpace, alreadyAdvertising (peripheral role) and
            // codes newer than this host.
            return nil
        }
    }
}

import CoreBluetooth
import DarwinHost
import DynamicBluetooth
import DynamicRuntime
import Foundation
import RuntimeNative

/// The Bluetooth LE central contracts over CoreBluetooth
/// (`HostRuntime.md` §5.1).
///
/// Every central shares the process's one `CBCentralManager`, created only
/// once Bluetooth authorization is requested or already decided, since
/// creating it prompts. Main thread only.
public enum DarwinBluetooth: HostModule {

    public static var contracts: [ContractDescriptor] {
        [
            CentralProxy.descriptor,
            CentralDelegateProxy.descriptor,
            PeripheralProxy.descriptor,
            PeripheralDelegateProxy.descriptor,
            ServiceProxy.descriptor,
            CharacteristicProxy.descriptor,
            DescriptorProxy.descriptor,
            AdvertisementProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        CentralProxy.register(DarwinCentral.self, in: registrar)
        PeripheralProxy.register(DarwinPeripheral.self, in: registrar)
        ServiceProxy.register(DarwinService.self, in: registrar)
        CharacteristicProxy.register(DarwinCharacteristic.self, in: registrar)
        DescriptorProxy.register(DarwinDescriptor.self, in: registrar)
        AdvertisementProxy.register(DarwinAdvertisement.self, in: registrar)
        CentralDelegateProxy.registerInterface(in: registrar)
        PeripheralDelegateProxy.registerInterface(in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        [.bluetooth: BluetoothPermission(hub: .shared)]
    }

    // MARK: Objects passed back

    /// Finds the Swift object behind a proxy the guest passed back, such as
    /// a `DarwinPeripheral` it got from `didDiscover`. Replace it if the
    /// host runs on a `NativeRuntime` other than `shared`.
    nonisolated(unsafe) public static var objectResolver: (DynamicObject) -> AnyObject? = { proxy in
        NativeRuntime.shared.swiftObject(for: proxy)
    }

    /// The implementation object behind a contract object: itself when the
    /// caller is Swift, or the object a proxy stands for. `nil` if it isn't
    /// one of this module's objects.
    static func resolve<T: AnyObject>(_ object: AnyObject, as type: T.Type) -> T? {
        if let object = object as? T {
            return object
        }
        if let proxy = object as? DynamicObject {
            return objectResolver(proxy) as? T
        }
        return nil
    }

    // MARK: Delivery

    /// Calls the guest now, from a CoreBluetooth callback.
    static func deliver(_ body: () -> Void) {
        autoreleasepool(invoking: body)
    }

    /// Calls the guest on the next turn of the main queue, for results
    /// decided inside a guest's call: a failure is reported the same way
    /// as CoreBluetooth's own, after the call returns.
    static func post(_ body: @escaping () -> Void) {
        DispatchQueue.main.async {
            autoreleasepool(invoking: body)
        }
    }

    // MARK: Errors

    /// `CoreBluetoothMapping.errorCode`, logging errors the contract has no
    /// code for.
    static func errorCode(_ error: Error?, _ operation: StaticString) -> Int32 {
        let code = CoreBluetoothMapping.errorCode(error)
        if let error, code == BluetoothError.unknown.rawValue {
            AppHost.logger.error("Bluetooth \(operation, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        return code
    }
}

/// `.bluetooth` permission from `CBManager.authorization`.
///
/// `status` never prompts. `request` prompts by creating the shared
/// `CBCentralManager`, and completes once the user decides.
final class BluetoothPermission: PermissionProvider {

    let hub: CentralHub

    init(hub: CentralHub) {
        self.hub = hub
    }

    func status() -> PermissionStatus {
        if hub.manager?.state == .unsupported {
            return .unavailable
        }
        return CoreBluetoothMapping.permission(hub.authorization())
    }

    func request(_ completion: @escaping (PermissionStatus) -> Void) {
        hub.requestAuthorization { [self] _ in
            completion(status())
        }
    }
}

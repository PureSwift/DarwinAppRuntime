import CoreLocation
import DarwinHost
import DynamicLocation
import DynamicRuntime
import Foundation

/// The Location contracts over CoreLocation (`HostRuntime.md` §5.1).
public enum DarwinLocation: HostModule {

    public static var contracts: [ContractDescriptor] {
        [
            LocationManagerProxy.descriptor,
            LocationManagerDelegateProxy.descriptor,
            LocationProxy.descriptor,
            HeadingProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        LocationManagerProxy.register(DarwinLocationManager.self, in: registrar)
        LocationManagerDelegateProxy.registerInterface(in: registrar)
        LocationProxy.register(DarwinLocationFix.self, in: registrar)
        HeadingProxy.register(DarwinHeading.self, in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        [.location: LocationPermission()]
    }
}

/// `Permissions` for `location`: `granted`, or `limited` when the user
/// allowed approximate location only.
///
/// `request` asks for when-in-use access. It keeps a `CLLocationManager`
/// until CoreLocation reports a decision, then calls every waiting
/// completion on the main thread.
final class LocationPermission: NSObject, PermissionProvider, CLLocationManagerDelegate {

    /// The manager whose prompt is showing.
    private var requesting: CLLocationManager?

    private var completions: [(PermissionStatus) -> Void] = []

    func status() -> PermissionStatus {
        let manager = DarwinLocationManager.sharedStatusManager
        return LocationMapping.permission(manager.authorizationStatus, accuracy: manager.accuracyAuthorization)
    }

    func request(_ completion: @escaping (PermissionStatus) -> Void) {
        guard DarwinLocationManager.sharedStatusManager.authorizationStatus == .notDetermined else {
            completion(status())
            return
        }
        completions.append(completion)
        guard requesting == nil else { return }
        let manager = CLLocationManager()
        manager.delegate = self
        requesting = manager
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // A new manager reports `notDetermined` before the user answers.
        guard manager === requesting, manager.authorizationStatus != .notDetermined else { return }
        let status = LocationMapping.permission(manager.authorizationStatus, accuracy: manager.accuracyAuthorization)
        let waiting = completions
        completions = []
        requesting = nil
        manager.delegate = nil
        DarwinLocationManager.onMain {
            for completion in waiting {
                completion(status)
            }
        }
    }
}

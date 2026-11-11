import DynamicRuntime
import Foundation

/// The built-in `Permissions` contract, routing each capability to the
/// `PermissionProvider` of the module whose framework gates it.
///
/// - A capability the app's manifest doesn't declare is `denied`, whatever
///   the system says: the app has no usage string for it.
/// - A declared capability no provider covers is `unavailable`.
public final class DarwinPermissions: Permissions {

    /// The app's declared capabilities, from `RTCapabilities`.
    nonisolated(unsafe) public static var declared: Set<Capability> = []

    nonisolated(unsafe) public static var providers: [Capability: any PermissionProvider] = [:]

    public static func status(_ capability: Capability) -> Int32 {
        resolve(capability).status().rawValue
    }

    public static func request(_ capability: Capability, delegate: any PermissionsDelegate) {
        // The provider calls back later, on the main thread; the closure holds
        // the delegate until then.
        resolve(capability).request { status in
            delegate.didRequest(capability, status: status.rawValue)
        }
    }

    private static func resolve(_ capability: Capability) -> any PermissionProvider {
        guard declared.contains(capability) else {
            return DeniedPermission.shared
        }
        return providers[capability] ?? UnavailablePermission()
    }
}

/// An undeclared capability.
private final class DeniedPermission: PermissionProvider {

    static let shared = DeniedPermission()

    func status() -> PermissionStatus {
        .denied
    }

    func request(_ completion: @escaping (PermissionStatus) -> Void) {
        completion(.denied)
    }
}

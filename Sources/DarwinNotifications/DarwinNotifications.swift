import DarwinHost
import DynamicRuntime
import Foundation
import RuntimeABI
import RuntimeNotifications

/// The notifications contracts (`HostRuntime.md` §5.8): `Notifications`,
/// `PushNotifications`, their records and callbacks.
///
/// The contracts are AppRuntime's `HostNotifications`, which checks each
/// request and keeps what the user did until the guest listens. This module
/// gives it `UNUserNotificationCenter` (`DarwinNotificationCenter`), and
/// APNs through the app delegate, which forwards to it:
///
/// ```swift
/// func application(_ application: UIApplication, willFinishLaunchingWithOptions …) -> Bool {
///     DarwinNotifications.attach()
///     return true
/// }
/// func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
///     DarwinNotifications.registered(token)
/// }
/// ```
public enum DarwinNotifications: DarwinHost.HostModule {

    public static var contracts: [ContractDescriptor] {
        HostNotificationsModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        HostNotifications.presenter = center
        HostNotifications.declaresRemote = NotificationValues.declaresRemote(Bundle.main.infoDictionary ?? [:])
        HostNotifications.deliver = { answer in
            DispatchQueue.main.async {
                autoreleasepool(invoking: answer)
            }
        }
        HostNotificationsModule.register(in: registrar)
    }

    /// The center's permission, which `Notifications` and `Permissions`
    /// share.
    public static func permissionProviders() -> [Capability: any DarwinHost.PermissionProvider] {
        [.notifications: CenterPermission(center)]
    }

    nonisolated(unsafe) static var center = DarwinNotificationCenter.system()

    /// Becomes the system's notification delegate. Called before the app
    /// finishes launching, so the response that launched it reaches the
    /// guest.
    public static func attach() {
        center.attach()
    }

    /// The app delegate's device token.
    public static func registered(_ token: Data) {
        center.registered(token, development: isDevelopment)
    }

    /// The app delegate's failure to register.
    public static func failedToRegister(_ error: Error) {
        center.failedToRegister(error)
    }

    /// The app delegate's push with data, while the app runs.
    public static func receivedPush(_ payload: [AnyHashable: Any]) {
        center.receivedPush(payload)
    }

    /// Whether the token is APNs' sandbox's: the app's `aps-environment`,
    /// from its provisioning profile. The Simulator's is. An app from the
    /// App Store has no profile, and is production.
    static let isDevelopment: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        #if os(macOS)
        let profile = Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
        #else
        let profile = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        #endif
        guard let data = try? Data(contentsOf: profile) else { return false }
        return NotificationValues.apsEnvironment(profile: data) == "development"
        #endif
    }()
}

/// `Permissions` for notifications, from the same center: its status is
/// the one the center last read, so it follows what the guest asked
/// through `Notifications`.
final class CenterPermission: DarwinHost.PermissionProvider {

    let center: DarwinNotificationCenter

    init(_ center: DarwinNotificationCenter) {
        self.center = center
        center.settings { _ in }
    }

    func status() -> PermissionStatus {
        center.lastStatus
    }

    func request(_ completion: @escaping (PermissionStatus) -> Void) {
        center.requestAuthorization([.alert, .sound, .badge]) { result in
            completion((try? result.get())?.authorizationStatus ?? self.center.lastStatus)
        }
    }
}

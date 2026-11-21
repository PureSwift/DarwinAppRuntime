import DynamicNotifications
import DynamicRuntime
import Foundation
import RuntimeNotifications
import UserNotifications
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// `HostNotifications`' presenter over `UNUserNotificationCenter`, and its
/// delegate: what the user did, and what arrived while the app runs.
///
/// The system keeps and delivers scheduled notifications, with the app
/// closed and after a restart, and shows a push itself. Main thread only;
/// the center's answers come on its own queue and are brought back.
final class DarwinNotificationCenter: NSObject, NotificationPresenter {

    /// `nil` outside an app, such as in a test runner, where
    /// `UNUserNotificationCenter.current()` raises an exception.
    let center: UNUserNotificationCenter?

    /// Asks the system for a device token: `UIApplication`'s or
    /// `NSApplication`'s. `nil` outside an app.
    let registerWithSystem: (() -> Void)?

    let unregisterWithSystem: (() -> Void)?

    /// The app's categories by identifier: their sound and interruption go
    /// on each request.
    private(set) var categories: [String: NotificationCategory] = [:]

    /// How a notification is shown while the app is in front.
    private(set) var foreground: NotificationPresentationOptions = .all

    /// The permission as last read, for `Permissions.status`, which can't
    /// wait.
    private(set) var lastStatus: PermissionStatus

    /// What iOS keeps: past it, it drops new requests silently.
    static let pendingLimit = 64

    /// Asked for a token, and not yet answered.
    private var registering: [(Result<PushSubscription, NotificationError>) -> Void] = []

    /// The address last given to the app.
    private(set) var subscription: PushSubscription?

    private var observer: NSObjectProtocol?

    init(center: UNUserNotificationCenter?, registerWithSystem: (() -> Void)?, unregisterWithSystem: (() -> Void)?) {
        self.center = center
        self.registerWithSystem = registerWithSystem
        self.unregisterWithSystem = unregisterWithSystem
        self.lastStatus = center == nil ? .unavailable : .notDetermined
        super.init()
    }

    /// The running app's.
    static func system() -> DarwinNotificationCenter {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return DarwinNotificationCenter(center: nil, registerWithSystem: nil, unregisterWithSystem: nil)
        }
        #if canImport(UIKit)
        return DarwinNotificationCenter(center: .current(),
                                        registerWithSystem: { UIApplication.shared.registerForRemoteNotifications() },
                                        unregisterWithSystem: { UIApplication.shared.unregisterForRemoteNotifications() })
        #else
        return DarwinNotificationCenter(center: .current(),
                                        registerWithSystem: { NSApplication.shared.registerForRemoteNotifications() },
                                        unregisterWithSystem: { NSApplication.shared.unregisterForRemoteNotifications() })
        #endif
    }

    /// Becomes the center's delegate, before the app finishes launching, so
    /// the response that launched it isn't missed. Reads the permission
    /// now and whenever the app comes forward, where the user may have
    /// changed it in Settings.
    func attach() {
        guard let center, observer == nil else { return }
        center.delegate = self
        #if canImport(UIKit)
        let active = UIApplication.didBecomeActiveNotification
        #else
        let active = NSApplication.didBecomeActiveNotification
        #endif
        observer = NotificationCenter.default.addObserver(forName: active, object: nil, queue: .main) { [weak self] _ in
            self?.settings { _ in }
        }
        settings { _ in }
    }

    // MARK: Permission

    func settings(_ completion: @escaping (NotificationSettings) -> Void) {
        guard let center else {
            completion(NotificationSettings(authorizationStatus: .unavailable))
            return
        }
        center.getNotificationSettings { settings in
            let value = NotificationValues.settings(settings)
            DispatchQueue.main.async {
                self.lastStatus = value.authorizationStatus
                completion(value)
            }
        }
    }

    /// The system asks once. After that it answers at once, and the
    /// settings say what the user chose.
    func requestAuthorization(_ options: AuthorizationOptions, completion: @escaping (Result<NotificationSettings, NotificationError>) -> Void) {
        guard let center else {
            completion(.success(NotificationSettings(authorizationStatus: .unavailable)))
            return
        }
        center.requestAuthorization(options: NotificationValues.options(options)) { _, _ in
            DispatchQueue.main.async {
                self.settings { completion(.success($0)) }
            }
        }
    }

    // MARK: Notifications

    func setCategories(_ categories: [NotificationCategory]) {
        self.categories = Dictionary(categories.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        // The system keeps them across launches, so a push that arrives with
        // the app closed has its buttons.
        center?.setNotificationCategories(Set(categories.map(NotificationValues.category)))
    }

    func add(_ notification: HostNotification, completion: @escaping (NotificationError?) -> Void) {
        guard let center else {
            completion(.unsupported)
            return
        }
        let request = NotificationValues.request(notification, category: notification.category.flatMap { categories[$0] },
                                                 now: HostNotifications.now())
        let schedule = {
            center.add(request) { error in
                let error = error.map(Self.error)
                DispatchQueue.main.async { completion(error) }
            }
        }
        // One shown now isn't kept.
        guard notification.trigger != nil else {
            schedule()
            return
        }
        center.getPendingNotificationRequests { pending in
            let replaces = pending.contains { $0.identifier == notification.identifier }
            guard replaces || pending.count < Self.pendingLimit else {
                DispatchQueue.main.async { completion(.limitReached) }
                return
            }
            schedule()
        }
    }

    func pending(_ completion: @escaping ([String]) -> Void) {
        guard let center else {
            completion([])
            return
        }
        center.getPendingNotificationRequests { requests in
            let identifiers = requests.map(\.identifier)
            DispatchQueue.main.async { completion(identifiers) }
        }
    }

    func delivered(_ completion: @escaping ([String]) -> Void) {
        guard let center else {
            completion([])
            return
        }
        center.getDeliveredNotifications { notifications in
            let identifiers = notifications.map(\.request.identifier)
            DispatchQueue.main.async { completion(identifiers) }
        }
    }

    func removePending(_ identifiers: [String]?) {
        if let identifiers {
            center?.removePendingNotificationRequests(withIdentifiers: identifiers)
        } else {
            center?.removeAllPendingNotificationRequests()
        }
    }

    func removeDelivered(_ identifiers: [String]?) {
        if let identifiers {
            center?.removeDeliveredNotifications(withIdentifiers: identifiers)
        } else {
            center?.removeAllDeliveredNotifications()
        }
    }

    func setBadgeCount(_ count: Int) {
        guard let center else { return }
        if #available(iOS 16, macOS 13, *) {
            center.setBadgeCount(count) { _ in }
        } else {
            #if canImport(UIKit)
            UIApplication.shared.applicationIconBadgeNumber = count
            #else
            NSApplication.shared.dockTile.badgeLabel = count == 0 ? nil : String(count)
            #endif
        }
    }

    func setForegroundPresentation(_ options: NotificationPresentationOptions) {
        foreground = options
    }

    static func error(_ error: Error) -> NotificationError {
        guard let error = error as? UNError else { return .unknown }
        switch error.code {
        case .notificationsNotAllowed: return .notAuthorized
        case .notificationInvalidNoDate, .notificationInvalidNoContent: return .invalid
        default: return .unknown
        }
    }

    // MARK: Push

    /// The system answers in the app delegate: `registered(_:)` or
    /// `failedToRegister(_:)`.
    func registerForPush(serverKey: String?, completion: @escaping (Result<PushSubscription, NotificationError>) -> Void) {
        guard let registerWithSystem else {
            completion(.failure(.unsupported))
            return
        }
        registering.append(completion)
        // One request answers everyone waiting.
        if registering.count == 1 {
            registerWithSystem()
        }
    }

    func unregisterForPush(_ completion: @escaping (NotificationError?) -> Void) {
        guard let unregisterWithSystem else {
            completion(.unsupported)
            return
        }
        unregisterWithSystem()
        subscription = nil
        completion(nil)
    }

    /// The system gave the app a device token: an answer, or a new token
    /// while the app runs.
    func registered(_ token: Data, development: Bool) {
        let subscription = PushSubscription(service: .apns, address: NotificationValues.hex(token), isDevelopment: development)
        let changed = self.subscription.map { $0 != subscription } ?? false
        self.subscription = subscription
        let waiting = registering
        registering = []
        for completion in waiting {
            completion(.success(subscription))
        }
        if waiting.isEmpty, changed {
            HostNotifications.pushSubscriptionChanged(subscription)
        }
    }

    /// Without the `aps-environment` entitlement there's no push for this
    /// app (`NSCocoaErrorDomain` 3000). Otherwise the service couldn't be
    /// reached, such as with no network.
    func failedToRegister(_ error: Error) {
        let error = error as NSError
        let reason: NotificationError = error.domain == NSCocoaErrorDomain && error.code == 3000 ? .unsupported : .unavailable
        let waiting = registering
        registering = []
        for completion in waiting {
            completion(.failure(reason))
        }
    }

    /// A push with data only, which the system hands to a running app and
    /// doesn't show. One that shows something comes through `willPresent`.
    func receivedPush(_ payload: [AnyHashable: Any], date: Date = Date()) {
        let aps = payload["aps"] as? [String: Any] ?? [:]
        guard aps["alert"] == nil else { return }
        HostNotifications.received(NotificationValues.notification(push: payload, date: date))
    }
}

extension DarwinNotificationCenter: UNUserNotificationCenterDelegate {

    /// Arrived while the app is in front: the guest hears of it, and it's
    /// shown as the guest asked.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let delivered = Self.notification(notification)
        DispatchQueue.main.async {
            HostNotifications.received(delivered)
            completionHandler(NotificationValues.presentation(self.foreground))
        }
    }

    /// The user tapped a notification or one of its buttons. It waits in
    /// `HostNotifications` until the guest listens.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action: String
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            action = ""
        case UNNotificationDismissActionIdentifier:
            // Only sent to a category that asks; none do.
            completionHandler()
            return
        default:
            action = response.actionIdentifier
        }
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let delivered = Self.notification(response.notification)
        DispatchQueue.main.async {
            HostNotifications.responded(to: delivered, action: action, text: text)
            completionHandler()
        }
    }

    static func notification(_ notification: UNNotification) -> HostNotification {
        NotificationValues.notification(identifier: notification.request.identifier, content: notification.request.content,
                                        isRemote: notification.request.trigger is UNPushNotificationTrigger,
                                        date: notification.date)
    }
}

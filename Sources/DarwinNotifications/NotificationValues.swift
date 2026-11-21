import DynamicNotifications
import DynamicRuntime
import Foundation
import RuntimeNotifications
import UserNotifications

/// The contract's values as `UserNotifications`' and back.
///
/// None of it needs a notification center, which only an app has, so the
/// tests check it in a test runner.
enum NotificationValues {

    // MARK: Requests

    /// The request for a notification the app adds. Apple puts sound and
    /// interruption on each request, so they're copied from its category:
    /// `nil` for the default one.
    static func request(_ notification: HostNotification, category: NotificationCategory?, now: Date = Date()) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.categoryIdentifier = notification.category ?? ""
        content.threadIdentifier = notification.thread ?? ""
        content.badge = notification.badge.map { NSNumber(value: $0) }
        content.userInfo = notification.userInfo
        content.sound = notification.isSilent ? nil : sound(category?.sound ?? .default)
        content.interruptionLevel = interruptionLevel(category?.interruption ?? .active)
        return UNNotificationRequest(identifier: notification.identifier, content: content,
                                     trigger: trigger(notification.trigger, now: now))
    }

    /// `nil`: now.
    static func trigger(_ trigger: HostNotificationTrigger?, now: Date) -> UNNotificationTrigger? {
        switch trigger {
        case nil:
            return nil
        case .interval(let seconds, let repeats):
            return UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: repeats)
        case .date(let milliseconds):
            // A moment, whatever the time zone does before it: as an
            // interval from now. `HostNotifications` checked that it's to
            // come; one that passed since fires as soon as it can.
            let seconds = Date(timeIntervalSince1970: Double(milliseconds) / 1000).timeIntervalSince(now)
            return UNTimeIntervalNotificationTrigger(timeInterval: max(seconds, 1), repeats: false)
        case .calendar(let parts, let repeats):
            // Local time, following the device's time zone.
            return UNCalendarNotificationTrigger(dateMatching: parts.components, repeats: repeats)
        }
    }

    static func sound(_ sound: NotificationSound) -> UNNotificationSound? {
        switch sound {
        case .default:
            return .default
        case .none:
            return nil
        case .named(let name):
            // The packager copies the app's resources into the app's
            // bundle, where the system looks for it.
            return UNNotificationSound(named: UNNotificationSoundName(name))
        }
    }

    /// Time-sensitive needs the time-sensitive entitlement; without it the
    /// system delivers the notification as an active one.
    static func interruptionLevel(_ interruption: NotificationInterruption) -> UNNotificationInterruptionLevel {
        switch interruption {
        case .passive: .passive
        case .active: .active
        case .timeSensitive: .timeSensitive
        }
    }

    // MARK: Categories

    static func category(_ category: NotificationCategory) -> UNNotificationCategory {
        UNNotificationCategory(identifier: category.identifier, actions: category.actions.map(action),
                               intentIdentifiers: [], options: [])
    }

    static func action(_ action: NotificationAction) -> UNNotificationAction {
        var options: UNNotificationActionOptions = []
        if action.options.contains(.destructive) {
            options.insert(.destructive)
        }
        if action.options.contains(.authenticationRequired) {
            options.insert(.authenticationRequired)
        }
        // A button opens the app unless it's to run in the background.
        if !action.options.contains(.background) {
            options.insert(.foreground)
        }
        guard let text = action.textInput else {
            return UNNotificationAction(identifier: action.identifier, title: action.title, options: options)
        }
        return UNTextInputNotificationAction(identifier: action.identifier, title: action.title, options: options,
                                             textInputButtonTitle: text.buttonTitle, textInputPlaceholder: text.placeholder)
    }

    // MARK: Delivered

    /// A notification the system delivered, as the contract carries it.
    /// `date`: when it was delivered.
    static func notification(identifier: String, content: UNNotificationContent, isRemote: Bool, date: Date) -> HostNotification {
        HostNotification(
            identifier: identifier,
            title: content.title,
            subtitle: content.subtitle,
            body: content.body,
            category: content.categoryIdentifier.isEmpty ? nil : content.categoryIdentifier,
            thread: content.threadIdentifier.isEmpty ? nil : content.threadIdentifier,
            badge: content.badge?.intValue,
            isSilent: content.sound == nil,
            userInfo: userInfo(content.userInfo),
            isRemote: isRemote,
            delivered: milliseconds(date)
        )
    }

    /// A push's data, delivered to the app with nothing shown. Its `aps`
    /// says what a notification would have.
    static func notification(push payload: [AnyHashable: Any], date: Date) -> HostNotification {
        let aps = payload["aps"] as? [String: Any] ?? [:]
        var notification = HostNotification(
            identifier: payload["rt.identifier"] as? String ?? UUID().uuidString,
            category: aps["category"] as? String,
            thread: aps["thread-id"] as? String,
            badge: (aps["badge"] as? NSNumber)?.intValue,
            isSilent: aps["sound"] == nil,
            userInfo: userInfo(payload),
            isRemote: true,
            delivered: milliseconds(date)
        )
        if let alert = aps["alert"] as? [String: Any] {
            notification.title = alert["title"] as? String ?? ""
            notification.subtitle = alert["subtitle"] as? String ?? ""
            notification.body = alert["body"] as? String ?? ""
        } else if let body = aps["alert"] as? String {
            notification.body = body
        }
        return notification
    }

    /// The app's own values: a push's other top-level keys, or what a local
    /// notification was given. One that isn't a string comes as its JSON
    /// text.
    static func userInfo(_ info: [AnyHashable: Any]) -> [String: String] {
        var values: [String: String] = [:]
        for (key, value) in info {
            guard let key = key as? String, key != "aps" else { continue }
            if let string = value as? String {
                values[key] = string
            } else if JSONSerialization.isValidJSONObject([value]),
                      let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys, .fragmentsAllowed]),
                      let text = String(data: data, encoding: .utf8) {
                // Wrapped, so a number or a boolean is valid JSON too.
                values[key] = String(text.dropFirst().dropLast())
            }
        }
        return values
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: Settings

    /// `exactTiming` and `deliversWhenClosed` always hold: the system
    /// keeps scheduled notifications and delivers them on time.
    static func settings(status: UNAuthorizationStatus, alerts: UNNotificationSetting,
                         sounds: UNNotificationSetting, badges: UNNotificationSetting) -> NotificationSettings {
        NotificationSettings(
            authorizationStatus: permission(status),
            alerts: alerts == .enabled,
            sounds: sounds == .enabled,
            badges: badges == .enabled,
            exactTiming: true,
            deliversWhenClosed: true
        )
    }

    static func settings(_ settings: UNNotificationSettings) -> NotificationSettings {
        Self.settings(status: settings.authorizationStatus, alerts: settings.alertSetting,
                      sounds: settings.soundSetting, badges: settings.badgeSetting)
    }

    /// Quiet delivery without asking is `limited`. An App Clip's ephemeral
    /// permission lets notifications show for a time: `granted`.
    static func permission(_ status: UNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .granted
        case .provisional: .limited
        #if os(iOS)
        case .ephemeral: .granted
        #endif
        @unknown default: .denied
        }
    }

    static func options(_ options: AuthorizationOptions) -> UNAuthorizationOptions {
        var result: UNAuthorizationOptions = []
        if options.contains(.alert) { result.insert(.alert) }
        if options.contains(.sound) { result.insert(.sound) }
        if options.contains(.badge) { result.insert(.badge) }
        if options.contains(.provisional) { result.insert(.provisional) }
        return result
    }

    static func presentation(_ options: NotificationPresentationOptions) -> UNNotificationPresentationOptions {
        var result: UNNotificationPresentationOptions = []
        if options.contains(.banner) { result.insert(.banner) }
        if options.contains(.list) { result.insert(.list) }
        if options.contains(.sound) { result.insert(.sound) }
        if options.contains(.badge) { result.insert(.badge) }
        return result
    }

    // MARK: Push

    /// An APNs device token as its provider API takes it: lowercase hex.
    static func hex(_ token: Data) -> String {
        token.map { byte in
            let digits = String(byte, radix: 16)
            return byte < 16 ? "0" + digits : digits
        }.joined()
    }

    /// The `aps-environment` the app was signed with, from the provisioning
    /// profile embedded in it: `development` or `production`. `nil` when
    /// there's no profile, which means no push.
    static func apsEnvironment(profile data: Data) -> String? {
        // The profile is a signed message around a property list.
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            return nil
        }
        return (entitlements["aps-environment"] ?? entitlements["com.apple.developer.aps-environment"]) as? String
    }

    /// Whether the manifest declares push: `RTCapabilityOptions.notifications.remote`,
    /// which the packager copies from the universal bundle as it is.
    static func declaresRemote(_ info: [String: Any]) -> Bool {
        let options = info["RTCapabilityOptions"] as? [String: Any]
        let remote = (options?["notifications"] as? [String: Any])?["remote"]
        return remote as? String == "true" || remote as? Bool == true
    }
}

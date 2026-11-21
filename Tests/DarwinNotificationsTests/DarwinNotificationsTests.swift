import DynamicNotifications
import DynamicRuntime
import Foundation
import RuntimeHost
import RuntimeNative
import RuntimeNotifications
import Testing
import UserNotifications
@testable import DarwinNotifications

/// The contract's values as `UserNotifications`' and back.
@Suite("Notification values")
struct NotificationValuesTests {

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aRequestCarriesTheNotificationAndItsCategory() throws {
        let notification = HostNotification(
            identifier: "timer-1", title: "Tea", subtitle: "Green", body: "Your timer is done.",
            category: "timer", thread: "kitchen", badge: 3, userInfo: ["minutes": "5"])
        let category = NotificationCategory(identifier: "timer", name: "Timers", interruption: .timeSensitive, sound: .named("chime.wav"))
        let request = NotificationValues.request(notification, category: category, now: now)
        #expect(request.identifier == "timer-1")
        #expect(request.trigger == nil, "now")
        let content = request.content
        #expect(content.title == "Tea")
        #expect(content.subtitle == "Green")
        #expect(content.body == "Your timer is done.")
        #expect(content.categoryIdentifier == "timer")
        #expect(content.threadIdentifier == "kitchen")
        #expect(content.badge == 3)
        #expect(content.userInfo as? [String: String] == ["minutes": "5"])
        #expect(content.interruptionLevel == .timeSensitive, "from the category")
        #expect(content.sound != nil)

        let plain = NotificationValues.request(HostNotification(identifier: "a"), category: nil, now: now).content
        #expect(plain.categoryIdentifier == "")
        #expect(plain.badge == nil, "the badge as it is")
        #expect(plain.interruptionLevel == .active, "the default category")
        #expect(plain.sound == .default)

        var silent = notification
        silent.isSilent = true
        #expect(NotificationValues.request(silent, category: category, now: now).content.sound == nil, "whatever its category says")
        #expect(NotificationValues.sound(.none) == nil)
    }

    @Test func triggers() throws {
        let interval = try #require(NotificationValues.trigger(.interval(seconds: 300, repeats: true), now: now) as? UNTimeIntervalNotificationTrigger)
        #expect(interval.timeInterval == 300)
        #expect(interval.repeats)

        // A moment is a moment, whatever the time zone does before it.
        let date = try #require(NotificationValues.trigger(.date(milliseconds: 1_800_000_090_500), now: now) as? UNTimeIntervalNotificationTrigger)
        #expect(date.timeInterval == 90.5)
        #expect(!date.repeats)

        let calendar = try #require(NotificationValues.trigger(
            .calendar(HostNotificationDateParts(hour: 7, minute: 0, weekday: 2), repeats: true), now: now) as? UNCalendarNotificationTrigger)
        #expect(calendar.dateComponents == DateComponents(hour: 7, minute: 0, weekday: 2))
        #expect(calendar.repeats)

        #expect(NotificationValues.trigger(nil, now: now) == nil)
    }

    @Test func categoriesAndTheirButtons() throws {
        let category = NotificationValues.category(NotificationCategory(
            identifier: "message", name: "Messages",
            actions: [
                NotificationAction(identifier: "stop", title: "Stop", options: [.destructive, .authenticationRequired]),
                NotificationAction(identifier: "snooze", title: "Snooze", options: .background),
                .textInput(identifier: "reply", title: "Reply", buttonTitle: "Send", placeholder: "Message"),
            ]))
        #expect(category.identifier == "message")
        #expect(category.actions.map(\.identifier) == ["stop", "snooze", "reply"])
        #expect(category.actions[0].options == [.destructive, .authenticationRequired, .foreground])
        #expect(category.actions[1].options == [], "doesn't open the app")
        let reply = try #require(category.actions[2] as? UNTextInputNotificationAction)
        #expect(reply.textInputButtonTitle == "Send")
        #expect(reply.textInputPlaceholder == "Message")
        #expect(reply.options == .foreground)
    }

    @Test func aDeliveredNotificationIsWhatWasAsked() {
        let content = NotificationValues.request(HostNotification(
            identifier: "timer-1", title: "Tea", body: "Done.", category: "timer", badge: 1, userInfo: ["minutes": "5"]),
            category: nil, now: now).content
        let delivered = NotificationValues.notification(identifier: "timer-1", content: content, isRemote: false, date: now)
        #expect(delivered == HostNotification(
            identifier: "timer-1", title: "Tea", body: "Done.", category: "timer", badge: 1,
            userInfo: ["minutes": "5"], delivered: 1_800_000_000_000))
    }

    @Test func aPushsValues() {
        let payload: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Order", "subtitle": "Shipped", "body": "On its way."], "badge": 2,
                    "category": "order", "thread-id": "orders", "sound": "default"],
            "order": "42",
            "items": [1, 2],
            "express": true,
            "rt.identifier": "order-42",
        ]
        let push = NotificationValues.notification(push: payload, date: now)
        #expect(push.identifier == "order-42")
        #expect(push.title == "Order")
        #expect(push.subtitle == "Shipped")
        #expect(push.body == "On its way.")
        #expect(push.category == "order")
        #expect(push.thread == "orders")
        #expect(push.badge == 2)
        #expect(!push.isSilent)
        #expect(push.isRemote)
        #expect(push.userInfo == ["order": "42", "items": "[1,2]", "express": "true", "rt.identifier": "order-42"],
                "a value that isn't a string arrives as its JSON text")

        let short = NotificationValues.notification(push: ["aps": ["alert": "Hello"]], date: now)
        #expect(short.body == "Hello")
        #expect(short.isSilent)
        #expect(!short.identifier.isEmpty)
    }

    @Test func settingsAndOptions() {
        let settings = NotificationValues.settings(status: .provisional, alerts: .enabled, sounds: .disabled, badges: .notSupported)
        #expect(settings == NotificationSettings(authorizationStatus: .limited, alerts: true, sounds: false, badges: false,
                                                 exactTiming: true, deliversWhenClosed: true))
        #expect(NotificationValues.permission(.notDetermined) == .notDetermined)
        #expect(NotificationValues.permission(.denied) == .denied)
        #expect(NotificationValues.permission(.authorized) == .granted)

        #expect(NotificationValues.options([.alert, .sound, .badge, .provisional]) == [.alert, .sound, .badge, .provisional])
        #expect(NotificationValues.presentation(.all) == [.banner, .list, .sound, .badge])
        #expect(NotificationValues.presentation([]) == [])
    }

    @Test func pushTokensAndEnvironments() {
        #expect(NotificationValues.hex(Data([0x00, 0x0f, 0xa0, 0xff])) == "000fa0ff")

        func profile(_ entitlements: String) -> Data {
            // A signed message around the property list.
            Data([0x30, 0x80, 0x06, 0x09]) + Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <plist version="1.0"><dict><key>Entitlements</key><dict>\(entitlements)</dict></dict></plist>
                """.utf8) + Data([0xa0, 0x82, 0x0e, 0x00])
        }
        #expect(NotificationValues.apsEnvironment(profile: profile("<key>aps-environment</key><string>development</string>")) == "development")
        #expect(NotificationValues.apsEnvironment(profile: profile("<key>com.apple.developer.aps-environment</key><string>production</string>")) == "production")
        #expect(NotificationValues.apsEnvironment(profile: profile("")) == nil)
        #expect(NotificationValues.apsEnvironment(profile: Data("not a profile".utf8)) == nil)
    }

    @Test func theManifestDeclaresPush() {
        #expect(NotificationValues.declaresRemote(["RTCapabilityOptions": ["notifications": ["remote": "true"]]]))
        #expect(NotificationValues.declaresRemote(["RTCapabilityOptions": ["notifications": ["remote": true]]]))
        #expect(!NotificationValues.declaresRemote(["RTCapabilityOptions": ["notifications": ["exactTiming": "true"]]]))
        #expect(!NotificationValues.declaresRemote([:]))
    }
}

/// The module, from a guest's `UserNotificationCenter`, over AppRuntime's
/// `HostNotifications`. A test runner has no notification center, so the
/// system's part is what the center does without one, and push is a
/// registration the test answers.
@Suite("Notifications", .serialized)
final class DarwinNotificationsTests {

    var registrations = 0

    let center = UserNotificationCenter.current

    init() {
        let native = NativeRuntime.shared
        native.bindDirectly()
        native.capabilities = nil
        HostNotifications.reset()
        DarwinNotifications.center = DarwinNotificationCenter(center: nil, registerWithSystem: { [unowned self] in
            registrations += 1
        }, unregisterWithSystem: { })
        DarwinNotifications.register(in: native)
        HostNotifications.deliver = { $0() }
        HostNotifications.declaresRemote = true
        center.onReceive(nil)
        center.onSubscriptionChange(nil)
    }

    deinit {
        center.onReceive(nil)
        center.onSubscriptionChange(nil)
        HostNotifications.reset()
        DarwinNotifications.center = DarwinNotificationCenter.system()
    }

    @Test func moduleListsItsContracts() {
        #expect(DarwinNotifications.contracts.map(\.name) == [
            "org.pureswift.notifications.Notifications", "org.pureswift.notifications.Record",
            "org.pureswift.notifications.Callback", "org.pureswift.notifications.Delegate",
            "org.pureswift.notifications.Push", "org.pureswift.notifications.PushCallback",
            "org.pureswift.notifications.PushDelegate",
        ])
        #expect(HostNotifications.presenter === DarwinNotifications.center)
        #expect(DarwinNotifications.permissionProviders()[.notifications]?.status() == .unavailable, "no center here")
    }

    @Test func withoutACenterThereAreNoNotifications() throws {
        var settings: Result<NotificationSettings, NotificationError>?
        center.settings { settings = $0 }
        #expect(try #require(settings).get().authorizationStatus == .unavailable)

        var status: Result<PermissionStatus, NotificationError>?
        center.requestAuthorization { status = $0 }
        #expect(try #require(status).get() == .unavailable)

        var added: Result<Void, NotificationError>?
        center.add(NotificationRequest(identifier: "a", content: NotificationContent(title: "A"))) { added = $0 }
        #expect(throws: NotificationError.notAuthorized) { try #require(added).get() }

        var pending: Result<[String], NotificationError>?
        center.pendingIdentifiers { pending = $0 }
        #expect(try #require(pending).get() == [])
    }

    @Test func aDeviceTokenIsTheAppsAddress() throws {
        var first: Result<PushSubscription, NotificationError>?
        var second: Result<PushSubscription, NotificationError>?
        center.registerForRemoteNotifications { first = $0 }
        center.registerForRemoteNotifications { second = $0 }
        #expect(registrations == 1, "one request answers both")
        #expect(first == nil, "until the system answers")

        DarwinNotifications.center.registered(Data([0xab, 0x01]), development: true)
        let subscription = PushSubscription(service: .apns, address: "ab01", isDevelopment: true)
        #expect(try #require(first).get() == subscription)
        #expect(try #require(second).get() == subscription)

        // A new token while the app runs.
        var changes: [PushSubscription] = []
        center.onSubscriptionChange { changes.append($0) }
        DarwinNotifications.center.registered(Data([0xab, 0x01]), development: true)
        #expect(changes.isEmpty, "the same address")
        DarwinNotifications.center.registered(Data([0xcd]), development: true)
        #expect(changes == [PushSubscription(service: .apns, address: "cd", isDevelopment: true)])
    }

    @Test func aFailedRegistrationSaysWhy() throws {
        var result: Result<PushSubscription, NotificationError>?
        center.registerForRemoteNotifications { result = $0 }
        DarwinNotifications.center.failedToRegister(NSError(domain: NSCocoaErrorDomain, code: 3000))
        #expect(throws: NotificationError.unsupported, "no aps-environment") { try #require(result).get() }

        center.registerForRemoteNotifications { result = $0 }
        #expect(registrations == 2, "asks again")
        DarwinNotifications.center.failedToRegister(URLError(.notConnectedToInternet))
        #expect(throws: NotificationError.unavailable) { try #require(result).get() }
    }

    @Test func aPushWithDataReachesTheRunningApp() throws {
        var received: [DeliveredNotification] = []
        center.onReceive { received.append($0) }
        DarwinNotifications.receivedPush(["aps": ["content-available": 1], "order": "42"])
        DarwinNotifications.receivedPush(["aps": ["alert": "Shown, and reported when it's presented"]])
        let push = try #require(received.first)
        #expect(received.count == 1)
        #expect(push.isRemote)
        #expect(push.userInfo == ["order": "42"])
    }
}

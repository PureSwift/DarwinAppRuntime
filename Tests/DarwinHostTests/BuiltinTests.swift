import DynamicRuntime
import Foundation
import Testing
@testable import DarwinHost

// MARK: - Fakes

final class RecordingPermissionsDelegate: PermissionsDelegate {

    var results: [(Capability, Int32)] = []

    func didRequest(_ capability: Capability, status: Int32) {
        results.append((capability, status))
    }
}

final class FakePermission: PermissionProvider {

    var current: PermissionStatus

    var answer: PermissionStatus

    var requests = 0

    init(_ current: PermissionStatus, answer: PermissionStatus) {
        self.current = current
        self.answer = answer
    }

    func status() -> PermissionStatus {
        current
    }

    func request(_ completion: @escaping (PermissionStatus) -> Void) {
        requests += 1
        current = answer
        completion(answer)
    }
}

final class RecordingApplicationDelegate: ApplicationDelegate {

    var events: [String] = []

    var handles: (String) -> Bool = { _ in true }

    func didChangeState(_ application: any Application, state: Int32) {
        events.append("state \(state)")
    }

    func didReceiveMemoryWarning(_ application: any Application) {
        events.append("memory warning")
    }

    func open(_ application: any Application, url: String) -> Bool {
        events.append("open \(url)")
        return handles(url)
    }
}

// MARK: - Tests

/// The built-ins share static state, so the suite is serialized.
@Suite(.serialized) struct BuiltinTests {

    // MARK: Permissions

    @Test func permissionsRouteToProviders() {
        let bluetooth = FakePermission(.notDetermined, answer: .granted)
        DarwinPermissions.declared = [.bluetooth, .location]
        DarwinPermissions.providers = [.bluetooth: bluetooth]
        defer {
            DarwinPermissions.declared = []
            DarwinPermissions.providers = [:]
        }
        #expect(DarwinPermissions.status(.bluetooth) == PermissionStatus.notDetermined.rawValue)
        #expect(DarwinPermissions.status(.location) == PermissionStatus.unavailable.rawValue, "no provider")
        #expect(DarwinPermissions.status(.camera) == PermissionStatus.denied.rawValue, "not declared")

        let delegate = RecordingPermissionsDelegate()
        DarwinPermissions.request(.bluetooth, delegate: delegate)
        DarwinPermissions.request(.camera, delegate: delegate)
        #expect(delegate.results.map(\.0) == [.bluetooth, .camera])
        #expect(delegate.results.map(\.1) == [PermissionStatus.granted.rawValue, PermissionStatus.denied.rawValue])
        #expect(bluetooth.requests == 1)
        #expect(DarwinPermissions.status(.bluetooth) == PermissionStatus.granted.rawValue)
    }

    @Test func systemProviders() {
        let providers = SystemPermissions.providers()
        #expect(providers[.network]?.status() == .granted)
        #expect(providers[.graphics]?.status() == .granted)
        #expect(providers[.camera] != nil)
        #expect(providers[.notifications] != nil)
    }

    // MARK: Bundle

    @Test func bundleReadsInfoAndStrings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DarwinHostTests-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at: directory) }
        let english = directory.appendingPathComponent("Contents/Resources/en.lproj")
        try FileManager.default.createDirectory(at: english, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "org.example.Test",
            "CFBundleShortVersionString": "1.2",
            "CFBundleVersion": "42",
            "CFBundleDevelopmentRegion": "en",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("Contents/Info.plist"))
        try "\"greeting\" = \"Hello\";\n\"same\" = \"same\";\n".write(
            to: english.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        try "\"title\" = \"Error\";\n".write(
            to: english.appendingPathComponent("Errors.strings"), atomically: true, encoding: .utf8)

        let previous = DarwinBundle.bundle
        let bundle = Foundation.Bundle(url: directory)
        DarwinBundle.bundle = try #require(bundle)
        defer { DarwinBundle.bundle = previous }

        #expect(DarwinBundle.identifier() == "org.example.Test")
        #expect(DarwinBundle.version() == "1.2")
        #expect(DarwinBundle.build() == "42")
        #expect(!DarwinBundle.preferredLanguages().isEmpty)
        #expect(DarwinBundle.localizedString("greeting", table: nil) == "Hello")
        #expect(DarwinBundle.localizedString("same", table: nil) == "same", "a value equal to its key isn't missing")
        #expect(DarwinBundle.localizedString("title", table: "Errors") == "Error")
        #expect(DarwinBundle.localizedString("missing", table: nil) == nil)
        #expect(DarwinBundle.localizedString("greeting", table: "Errors") == nil)
    }

    // MARK: Application

    @Test func applicationReportsLifecycleAndURLs() throws {
        let center = NotificationCenter()
        let previousCenter = DarwinApplication.notificationCenter
        let previousState = DarwinApplication.initialState
        DarwinApplication.notificationCenter = center
        DarwinApplication.initialState = { .inactive }
        defer {
            DarwinApplication.notificationCenter = previousCenter
            DarwinApplication.initialState = previousState
        }

        // A URL before the guest made an application waits for one.
        #expect(DarwinApplication.open(try #require(URL(string: "example://early"))))

        let delegate = RecordingApplicationDelegate()
        delegate.handles = { $0.hasPrefix("example:") }
        do {
            let application = DarwinApplication.make(delegate)
            #expect(delegate.events == ["open example://early"])
            #expect(application.state() == ApplicationState.inactive.rawValue)

            let (active, background) = Self.notifications
            center.post(name: active, object: nil)
            center.post(name: active, object: nil)
            #expect(application.state() == ApplicationState.active.rawValue)
            center.post(name: background, object: nil)
            #expect(application.state() == ApplicationState.background.rawValue)
            #expect(DarwinApplication.open(try #require(URL(string: "example://item/1"))))
            #expect(!DarwinApplication.open(try #require(URL(string: "https://example.org"))))
            #expect(delegate.events == [
                "open example://early",
                "state \(ApplicationState.active.rawValue)",
                "state \(ApplicationState.background.rawValue)",
                "open example://item/1",
                "open https://example.org",
            ], "a repeated state isn't reported twice")
        }
        // Released: its observers are gone.
        center.post(name: Self.notifications.active, object: nil)
        #expect(delegate.events.count == 5)
    }

    static var notifications: (active: Notification.Name, background: Notification.Name) {
        let names = DarwinApplication.stateNotifications
        let active = names.first { $0.1 == .active }!.0
        let background = names.first { $0.1 == .background }!.0
        return (active, background)
    }
}

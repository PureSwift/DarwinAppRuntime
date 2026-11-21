import DynamicBackgroundTasks
import DynamicRuntime
import Foundation
import RuntimeBackgroundTasks
import Testing
@testable import DarwinBackgroundTasks

@Suite("Background values")
struct BackgroundValuesTests {

    @Test func readsTheManifestsTasks() {
        let info: [String: Any] = [
            "RTBackgroundTasks": [
                ["Identifier": "org.example.mail.sync", "Kind": "refresh"],
                ["Identifier": "org.example.mail.index", "Kind": "processing"],
                // From another version, or damaged.
                ["Identifier": "org.example.other", "Kind": "sometimes"],
                ["Kind": "refresh"],
            ],
            "BGTaskSchedulerPermittedIdentifiers": ["org.example.mail.sync", "org.example.mail.index"],
        ]
        #expect(BackgroundValues.declared(info) == ["org.example.mail.sync": .refresh, "org.example.mail.index": .processing])
        #expect(BackgroundValues.permitted(info) == ["org.example.mail.sync", "org.example.mail.index"])
        #expect(BackgroundValues.declared([:]).isEmpty)
    }

    @Test func timesARequest() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(BackgroundValues.earliestDate(0, now: now) == nil, "any time")
        #expect(BackgroundValues.earliestDate(900, now: now) == Date(timeIntervalSince1970: 1_900))
    }

    @Test func saysTheTimeLeft() {
        #expect(BackgroundValues.timeRemaining(25.5) == 25.5)
        #expect(BackgroundValues.timeRemaining(-1) == 0)
        // In front, the system says the time is unlimited.
        #expect(BackgroundValues.timeRemaining(.greatestFiniteMagnitude) == nil)
        #expect(BackgroundValues.timeRemaining(.infinity) == nil)
    }
}

/// The macOS scheduler, through `HostBackgroundTasks` as the guest uses it.
/// They share `HostBackgroundTasks`' settings, so one test at a time.
@Suite("Background scheduler", .serialized)
@MainActor
struct BackgroundSchedulerTests {

    static let refresh = "org.example.feed.refresh"

    init() {
        HostBackgroundTasks.reset()
        HostBackgroundTasks.scheduler = DarwinBackgroundScheduler()
        HostBackgroundTasks.declared = [Self.refresh: .refresh]
    }

    /// What a guest's callback heard.
    final class Callback: BackgroundCallback {
        var completed = false
        var listed: [String]?
        var failure: BackgroundError?
        func didComplete() { completed = true }
        func didList(_ identifiers: [String]) { listed = identifiers }
        func didFail(_ error: Int32) { failure = BackgroundError(rawValue: error) }
    }

    func wait(_ what: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("timed out waiting: \(what)")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func pending() async throws -> [String]? {
        let callback = Callback()
        HostBackgroundTasks.shared().pending(callback)
        try await wait("listed") { callback.listed != nil }
        return callback.listed
    }

    #if os(macOS)
    @Test func schedulesAndCancels() async throws {
        let tasks = HostBackgroundTasks.shared()
        #expect(tasks.status() == PermissionStatus.granted.rawValue)
        let submitted = Callback()
        tasks.submit(Self.refresh, kind: BackgroundTaskKind.refresh.rawValue, earliest: 0, interval: 900, requirements: 0, callback: submitted)
        try await wait("submitted") { submitted.completed || submitted.failure != nil }
        #expect(submitted.completed)
        #expect(try await pending() == [Self.refresh])
        // Remembered, to ask for again at the next launch.
        #expect(HostBackgroundTasks.repeatingRequests.map(\.identifier) == [Self.refresh])
        tasks.cancel(Self.refresh)
        #expect(try await pending() == [])
        #expect(HostBackgroundTasks.repeatingRequests.isEmpty)
    }

    @Test func refusesWhatTheManifestDoesntName() async throws {
        let refused = Callback()
        HostBackgroundTasks.shared().submit("org.example.other", kind: 0, earliest: 0, interval: 0, requirements: 0, callback: refused)
        try await wait("refused") { refused.failure != nil }
        #expect(refused.failure == .notDeclared)
        #expect(try await pending() == [])
    }

    @Test func holdsTheAppForAnActivity() {
        let tasks = HostBackgroundTasks.shared()
        let activity = tasks.beginActivity("Saving")
        #expect(activity != 0, "a Mac app's activity is never expired")
        #expect(!HostBackgroundTasks.isIdle)
        // Unlimited: a Mac app isn't suspended.
        #expect(tasks.timeRemaining() == -1)
        tasks.endActivity(activity)
        #expect(HostBackgroundTasks.isIdle)
    }

    @Test func asksAgainAtLaunch() async throws {
        let scheduler = DarwinBackgroundScheduler()
        HostBackgroundTasks.scheduler = scheduler
        scheduler.restore([HostBackgroundRequest(identifier: Self.refresh, interval: 3600)])
        #expect(try await pending() == [Self.refresh])
        scheduler.cancel(nil)
        #expect(try await pending() == [])
    }
    #endif
}

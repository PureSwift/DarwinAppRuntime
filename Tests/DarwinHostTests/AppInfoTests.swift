import Foundation
import Testing
@testable import DarwinHost
import RuntimeABI

@Suite struct AppInfoTests {

    @Test func readsThePackagersKeys() throws {
        let info = try AppInfo(infoDictionary: [
            "CFBundleIdentifier": "org.pureswift.example",
            "RTABIVersion": 1,
            "RTTargets": ["wasm32", "macos"],
            "RTCapabilities": ["bluetooth"],
            "RTContracts": [
                ["Name": "org.pureswift.example.Beacon", "Version": 1, "Kind": "contract"],
                ["Name": "org.pureswift.example.CounterDelegate", "Version": 2, "Kind": "callback"],
            ],
            "RTCapabilityUsage": ["bluetooth": "perm.bluetooth"],
        ])
        #expect(info.identifier == "org.pureswift.example")
        #expect(info.abiVersion == 1)
        #expect(info.targets == ["wasm32", "macos"])
        #expect(info.capabilities == [.bluetooth])
        #expect(info.contracts == [
            .init(name: "org.pureswift.example.Beacon", version: 1, kind: .contract),
            .init(name: "org.pureswift.example.CounterDelegate", version: 2, kind: .callback),
        ])
        #expect(info.capabilityUsage == ["bluetooth": "perm.bluetooth"])
    }

    @Test func missingAndMalformedKeys() {
        #expect(throws: AppInfoError.missing("RTABIVersion")) {
            try AppInfo(infoDictionary: [:])
        }
        #expect(throws: AppInfoError.malformed("RTContracts")) {
            try AppInfo(infoDictionary: ["RTABIVersion": 1, "RTContracts": [["Name": "x", "Version": 1, "Kind": "other"]]])
        }
    }
}

@Suite struct DispatchClockTests {

    @Test func nowIsMonotonicNanoseconds() {
        let clock = DispatchClock()
        let first = clock.now()
        let second = clock.now()
        #expect(first > 0)
        #expect(second >= first)
    }

    @Test func timersFireOnTheMainQueueAfterTheirDelay() async {
        let clock = DispatchClock()
        let start = clock.now()
        let elapsed: Int64 = await withCheckedContinuation { continuation in
            clock.schedule(after: 20_000_000) {
                #expect(Thread.isMainThread)
                continuation.resume(returning: clock.now() - start)
            }
        }
        #expect(elapsed >= 20_000_000)
    }
}

import Foundation
import Testing
@testable import DarwinPackager

@Suite struct CompatibilityTests {

    let temporary = try! TemporaryDirectory()

    func check(_ fixture: FixtureBundle, _ platform: ApplePlatform, allowsMissing: Bool = false) throws -> [Diagnostic] {
        Compatibility(platform: platform, allowsMissingContracts: allowsMissing).check(try fixture.read(in: temporary.url))
    }

    func contracts(_ entries: [(String, Int, String)]) -> [[String: Any]] {
        entries.map { ["Name": $0.0, "Version": $0.1, "Kind": $0.2] }
    }

    @Test(arguments: ApplePlatform.allCases)
    func acceptsTheFixture(platform: ApplePlatform) throws {
        #expect(try check(FixtureBundle(), platform) == [])
    }

    @Test func rejectsANewerABI() throws {
        let diagnostics = try check(FixtureBundle().with(["RTABIVersion": 99]), .macos)
        #expect(diagnostics == [.error("the app needs rt ABI 99; this host provides 1")])
    }

    @Test func rejectsUnknownContracts() throws {
        let fixture = FixtureBundle().with(["RTContracts": contracts([("org.example.Thing", 1, "contract")])])
        #expect(try check(fixture, .ios) == [.error("org.example.Thing has no implementation in this host")])
        let allowed = try check(fixture, .ios, allowsMissing: true)
        #expect(!allowed.hasErrors)
        #expect(allowed.count == 1)
    }

    @Test func acceptsBuiltinContracts() throws {
        let fixture = FixtureBundle().with(["RTContracts": contracts([
            ("org.pureswift.runtime.Clock", 1, "contract"),
            ("org.pureswift.runtime.ClockDelegate", 1, "callback"),
            ("org.pureswift.ui.Renderer", 1, "contract"),
        ])])
        #expect(try check(fixture, .macos) == [])
    }

    @Test func rejectsNewerContractVersionsAndOtherKinds() throws {
        let fixture = FixtureBundle().with(["RTContracts": contracts([
            ("org.pureswift.bluetooth.Central", 9, "contract"),
            ("org.pureswift.bluetooth.CentralDelegate", 1, "contract"),
        ])])
        let messages = try check(fixture, .ios).map(\.message)
        #expect(messages == [
            "org.pureswift.bluetooth.Central version 9 is newer than this host's 1",
            "org.pureswift.bluetooth.CentralDelegate is a contract in the app and a callback in this host",
        ])
    }

    @Test func requiresTheContractsCapabilities() throws {
        let fixture = FixtureBundle().with([
            "RTContracts": contracts([("org.pureswift.location.LocationManager", 1, "contract")]),
        ])
        let messages = try check(fixture, .ios).map(\.message)
        #expect(messages == ["org.pureswift.location.LocationManager requires capability 'location', which the manifest doesn't declare"])
    }

    @Test func rejectsNFCOnMacOS() throws {
        let fixture = FixtureBundle().with([
            "RTCapabilities": ["nfc"],
            "RTCapabilityUsage": ["nfc": "perm.bluetooth"],
            "RTContracts": contracts([("org.pureswift.nfc.Reader", 1, "contract")]),
        ])
        #expect(try check(fixture, .ios) == [])
        #expect(try check(fixture, .iosSimulator) == [])
        let messages = try check(fixture, .macos).map(\.message)
        #expect(messages == [
            "org.pureswift.nfc.Reader isn't available on macos: DarwinNFC runs on ios, ios-simulator only",
            "capability 'nfc' isn't supported on macos",
        ])
    }

    @Test func rejectsNFCDeclaredWithoutContractsOnMacOS() throws {
        let fixture = FixtureBundle().with([
            "RTCapabilities": ["bluetooth", "nfc"],
            "RTCapabilityUsage": ["bluetooth": "perm.bluetooth", "nfc": "perm.bluetooth"],
        ])
        #expect(try check(fixture, .macos) == [.error("capability 'nfc' isn't supported on macos")])
    }

    @Test func rejectsUnknownCapabilities() throws {
        let fixture = FixtureBundle().with(["RTCapabilities": ["bluetooth", "graphics"]])
        #expect(try check(fixture, .ios) == [.error("capability 'graphics' isn't supported by this host")])
    }

    @Test func requiresUsageTexts() throws {
        let fixture = FixtureBundle().with(["RTCapabilityUsage": [String: String]()])
        #expect(try check(fixture, .ios).map(\.message) == ["capability 'bluetooth' has no usage text; the system stops an app that uses it without one"])
        // Network has no usage text.
        let network = FixtureBundle().with(["RTCapabilities": ["network"], "RTContracts": [], "RTCapabilityUsage": nil])
        #expect(try check(network, .macos) == [])
    }

    @Test func requiresTheManifestToListThePlatform() throws {
        let fixture = FixtureBundle().with(["RTPlatforms": ["android": ["MinSDK": 26]]])
        #expect(try check(fixture, .ios) == [.error("the manifest doesn't list ios in its platforms (android)")])
    }

    @Test func picksTheHigherDeploymentTarget() throws {
        let higher = try FixtureBundle().with(["RTPlatforms": ["ios": ["Minimum": "17.2"], "macos": ["Minimum": "11.0"]]]).read(in: temporary.url)
        #expect(try Compatibility(platform: .ios).deploymentTarget(higher) == "17.2")
        #expect(try Compatibility(platform: .iosSimulator).deploymentTarget(higher) == "17.2")
        #expect(try Compatibility(platform: .macos).deploymentTarget(higher) == "12.0")
        let none = try FixtureBundle().with(["RTPlatforms": nil]).read(in: temporary.url)
        #expect(try Compatibility(platform: .ios).deploymentTarget(none) == "15.0")
    }

    @Test func registersEveryContractModuleOnIOS() {
        let ios = HostContracts.descriptors(for: .ios)
        let macos = HostContracts.descriptors(for: .macos)
        #expect(ios["org.pureswift.nfc.Reader"] != nil)
        #expect(macos["org.pureswift.nfc.Reader"] == nil)
        #expect(macos["org.pureswift.ui.Renderer"] != nil)
        #expect(macos["org.pureswift.runtime.Bundle"] != nil)
        #expect(ios.count == macos.count + 5)
    }
}

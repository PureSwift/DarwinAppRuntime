import Foundation
import Testing
@testable import DarwinPackager

@Suite struct SigningTests {

    let temporary = try! TemporaryDirectory()

    func bundle(_ fixture: FixtureBundle) throws -> UniversalBundle {
        try fixture.read(in: temporary.url)
    }

    @Test func sandboxesMacOSApps() throws {
        let bundle = try bundle(FixtureBundle().with(["RTCapabilities": ["bluetooth", "network"]]))
        let release = Entitlements.forCapabilities(bundle, platform: .macos, configuration: .release)
        #expect(Set(release.keys) == [
            "com.apple.security.app-sandbox", "com.apple.security.device.bluetooth", "com.apple.security.network.client",
        ])
        let debug = Entitlements.forCapabilities(bundle, platform: .macos, configuration: .debug)
        #expect(debug["com.apple.security.get-task-allow"] as? Bool == true)
        #expect(Entitlements.forCapabilities(bundle, platform: .ios, configuration: .release).isEmpty)
    }

    @Test func entitlesNFC() throws {
        let tags = try bundle(FixtureBundle().with(["RTCapabilities": ["nfc"], "RTContracts": [["Name": "org.pureswift.nfc.Reader", "Version": 1, "Kind": "contract"]]]))
        #expect(Entitlements.forCapabilities(tags, platform: .ios, configuration: .release)["com.apple.developer.nfc.readersession.formats"] as? [String] == ["TAG"])
        let ndef = try bundle(FixtureBundle().with(["RTCapabilities": ["nfc"], "RTContracts": [["Name": "org.pureswift.nfc.NDEFMessage", "Version": 1, "Kind": "contract"]]]))
        #expect(Entitlements.forCapabilities(ndef, platform: .ios, configuration: .release)["com.apple.developer.nfc.readersession.formats"] as? [String] == ["TAG", "NDEF"])
    }

    @Test func entitlesRemoteNotifications() throws {
        let local = try bundle(FixtureBundle().with(["RTCapabilities": ["notifications"]]))
        #expect(Entitlements.forCapabilities(local, platform: .ios, configuration: .release).isEmpty)
        let remote = try bundle(FixtureBundle().with(["RTCapabilities": ["notifications"], "RTCapabilityOptions": ["notifications": ["remote": "true"]]]))
        #expect(Entitlements.forCapabilities(remote, platform: .ios, configuration: .release)["aps-environment"] as? String == "production")
        #expect(Entitlements.forCapabilities(remote, platform: .ios, configuration: .debug)["aps-environment"] as? String == "development")
        #expect(Entitlements.forCapabilities(remote, platform: .macos, configuration: .release)["com.apple.developer.aps-environment"] as? String == "production")
    }

    static func profile(identifier: String = "TEAM123456.org.pureswift.*", entitlements: [String: Any] = [:]) throws -> ProvisioningProfile {
        var allowed = entitlements
        allowed["application-identifier"] = identifier
        allowed["get-task-allow"] = true
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "TeamIdentifier": ["TEAM123456"],
            "Entitlements": allowed,
        ], format: .xml, options: 0)
        return try ProvisioningProfile.parse(data, url: URL(fileURLWithPath: "/p/App.mobileprovision"))
    }

    @Test func mergesTheProfile() throws {
        let profile = try Self.profile()
        #expect(profile.teamIdentifier == "TEAM123456")
        #expect(profile.allows(bundleIdentifier: "org.pureswift.example"))
        #expect(!profile.allows(bundleIdentifier: "com.other.example"))
        let merged = try profile.entitlements(adding: ["com.apple.developer.nfc.readersession.formats": ["TAG"]], bundleIdentifier: "org.pureswift.example", platform: .ios)
        #expect(merged.entitlements["application-identifier"] as? String == "TEAM123456.org.pureswift.example")
        #expect(merged.entitlements["com.apple.developer.team-identifier"] as? String == "TEAM123456")
        #expect(merged.entitlements["get-task-allow"] as? Bool == true)
        #expect(merged.diagnostics == [.warning("the profile doesn't grant com.apple.developer.nfc.readersession.formats; the app may not install or launch")])
    }

    @Test func rejectsAProfileForAnotherApp() throws {
        let profile = try Self.profile(identifier: "TEAM123456.com.other.app")
        #expect(throws: PackagerError.self) {
            try profile.entitlements(adding: [:], bundleIdentifier: "org.pureswift.example", platform: .ios)
        }
    }

    @Test func signsWithCodesign() {
        let app = URL(fileURLWithPath: "/out/ExampleApp.app")
        let entitlements = URL(fileURLWithPath: "/work/ExampleApp.entitlements")
        #expect(CodeSign.sign(app: app, identity: "-", entitlements: entitlements, platform: .iosSimulator).description
            == "xcrun codesign --force --sign - --entitlements /work/ExampleApp.entitlements /out/ExampleApp.app")
        #expect(CodeSign.sign(app: app, identity: "-", entitlements: entitlements, platform: .macos).description
            == "xcrun codesign --force --sign - --entitlements /work/ExampleApp.entitlements --options runtime --timestamp=none /out/ExampleApp.app")
        #expect(CodeSign.sign(app: app, identity: "Developer ID Application: Example (TEAM123456)", entitlements: entitlements, platform: .macos).arguments
            == ["codesign", "--force", "--sign", "Developer ID Application: Example (TEAM123456)", "--entitlements", "/work/ExampleApp.entitlements", "--options", "runtime", "--timestamp", "/out/ExampleApp.app"])
        #expect(CodeSign.verify(app: app).description == "xcrun codesign --verify --deep --strict --verbose=2 /out/ExampleApp.app")
    }
}

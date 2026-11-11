import Foundation
import Testing
@testable import DarwinPackager

@Suite struct InfoPlistTests {

    static let sdk = SDKInfo(name: "iphoneos", path: "/SDK", version: "27.2", build: "24C100", xcodeVersion: "27.2", xcodeBuild: "27B52")

    let temporary = try! TemporaryDirectory()

    func translator(_ fixture: FixtureBundle = FixtureBundle(), _ platform: ApplePlatform, target: String? = nil) throws -> InfoPlistTranslator {
        let bundle = try fixture.read(in: temporary.url)
        return InfoPlistTranslator(bundle: bundle, platform: platform, deploymentTarget: target ?? platform.hostMinimum)
    }

    @Test func translatesForIOS() throws {
        let translator = try translator(FixtureBundle(), .ios)
        let info = try translator.infoPlist(sdk: Self.sdk)
        #expect(info["CFBundleIdentifier"] as? String == "org.pureswift.example")
        #expect(info["CFBundleExecutable"] as? String == "ExampleApp")
        #expect(info["CFBundlePackageType"] as? String == "APPL")
        #expect(info["MinimumOSVersion"] as? String == "15.0")
        #expect(info["LSMinimumSystemVersion"] == nil)
        #expect(info["UIDeviceFamily"] as? [Int] == [1, 2])
        #expect((info["UILaunchScreen"] as? [String: Any])?.isEmpty == true)
        #expect((info["UIApplicationSceneManifest"] as? [String: Any])?["UIApplicationSupportsMultipleScenes"] as? Bool == false)
        #expect(info["NSBluetoothAlwaysUsageDescription"] as? String == "Looks for beacons.")
        #expect(info["UIRequiredDeviceCapabilities"] == nil)
        #expect(info["CFBundleSupportedPlatforms"] as? [String] == ["iPhoneOS"])
        #expect(info["DTSDKName"] as? String == "iphoneos27.2")
        #expect(info["DTXcode"] as? String == "2720")
        // The RT keys, for the host's start-up checks.
        #expect(info["RTABIVersion"] as? Int == 1)
        #expect((info["RTContracts"] as? [Any])?.count == 2)
        #expect(info["RTPlatformExtras"] != nil)
    }

    @Test func translatesForMacOS() throws {
        let translator = try translator(FixtureBundle(), .macos)
        let info = try translator.infoPlist(sdk: nil)
        #expect(info["LSMinimumSystemVersion"] as? String == "12.0")
        #expect(info["MinimumOSVersion"] == nil)
        #expect(info["NSPrincipalClass"] as? String == "NSApplication")
        #expect(info["LSApplicationCategoryType"] as? String == "public.app-category.developer-tools")
        #expect(info["UIDeviceFamily"] == nil)
        #expect(info["NSBluetoothAlwaysUsageDescription"] as? String == "Looks for beacons.")
    }

    @Test func translatesLocation() throws {
        let fixture = FixtureBundle().with([
            "RTCapabilities": ["location"],
            "RTCapabilityUsage": ["location": "perm.bluetooth"],
            "RTCapabilityOptions": ["location": ["access": "always", "required": "true"]],
        ])
        let ios = try translator(fixture, .ios)
        let info = try ios.infoPlist(sdk: nil)
        #expect(info["NSLocationWhenInUseUsageDescription"] as? String == "Looks for beacons.")
        #expect(info["NSLocationAlwaysAndWhenInUseUsageDescription"] as? String == "Looks for beacons.")
        #expect(info["UIRequiredDeviceCapabilities"] as? [String] == ["location-services"])
        let macos = try translator(fixture, .macos)
        let macInfo = try macos.infoPlist(sdk: nil)
        #expect(macInfo["NSLocationUsageDescription"] as? String == "Looks for beacons.")
        #expect(macInfo["NSLocationAlwaysAndWhenInUseUsageDescription"] == nil)
    }

    @Test func mergesExtrasLast() throws {
        let fixture = FixtureBundle().with(["RTPlatformExtras": ["apple": ["extraInfoPlist": [
            "UIBackgroundModes": ["bluetooth-central"],
            "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
        ]]]])
        let translator = try translator(fixture, .ios)
        let info = try translator.infoPlist(sdk: nil)
        #expect(info["UIBackgroundModes"] as? [String] == ["bluetooth-central"])
        #expect(info["UISupportedInterfaceOrientations"] as? [String] == ["UIInterfaceOrientationPortrait"])
        #expect(info["LSApplicationCategoryType"] == nil)
    }

    @Test func rejectsExtrasThatReplaceGeneratedKeys() throws {
        let fixture = FixtureBundle().with(["RTPlatformExtras": ["apple": ["extraInfoPlist": [
            "CFBundleIdentifier": "other", "NSBluetoothAlwaysUsageDescription": "x",
        ]]]])
        let translator = try translator(fixture, .ios)
        #expect {
            try translator.infoPlist(sdk: nil)
        } throws: {
            ($0 as? PackagerError)?.message == "apple.extraInfoPlist sets keys the packager generates: CFBundleIdentifier, NSBluetoothAlwaysUsageDescription"
        }
    }

    @Test func mergesTheIconKeys() throws {
        let translator = try translator(FixtureBundle(), .macos)
        let info = try translator.infoPlist(sdk: nil, iconKeys: ["CFBundleIconFile": "AppIcon", "CFBundleIconName": "AppIcon"])
        #expect(info["CFBundleIconName"] as? String == "AppIcon")
    }

    @Test func writesInfoPlistStrings() throws {
        let translator = try translator(FixtureBundle(), .ios)
        let strings = try translator.infoPlistStrings()
        #expect(strings == [
            "en": ["CFBundleDisplayName": "Example", "CFBundleName": "Example", "NSBluetoothAlwaysUsageDescription": "Looks for beacons."],
            "es": ["CFBundleDisplayName": "Ejemplo", "CFBundleName": "Ejemplo", "NSBluetoothAlwaysUsageDescription": "Busca balizas."],
        ])
    }

    @Test func requiresEveryKeyInEveryLanguage() throws {
        var fixture = FixtureBundle()
        fixture.files["resources/es.lproj/Manifest.strings"] = Data("\"app.name\" = \"Ejemplo\";".utf8)
        let translator = try translator(fixture, .ios)
        #expect {
            try translator.infoPlistStrings()
        } throws: {
            ($0 as? PackagerError)?.message == "resources/es.lproj/Manifest.strings has no 'perm.bluetooth', the usage text of 'bluetooth'"
        }
    }

    @Test func needsNoStringsWithoutLocalizedText() throws {
        var fixture = FixtureBundle().with(["RTDisplayNameKey": nil, "RTCapabilities": [], "RTCapabilityUsage": nil, "RTContracts": []])
        fixture.files = ["wasm32/App.wasm": Data("\0asm".utf8)]
        let translator = try translator(fixture, .ios)
        #expect(try translator.infoPlistStrings().isEmpty)
        #expect(try translator.infoPlist(sdk: nil)["CFBundleDisplayName"] as? String == "Example")
    }

    @Test func writesThePrivacyManifest() throws {
        let manifest = PrivacyManifest.manifest()
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        let accessed = manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        #expect(accessed?.count == 1)
        #expect(accessed?.first?["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategorySystemBootTime")
        #expect(accessed?.first?["NSPrivacyAccessedAPITypeReasons"] as? [String] == ["35F9.1"])
        #expect(try PropertyListSerialization.propertyList(from: try manifest.propertyListData(), format: nil) is [String: Any])
    }

    @Test func mergesTheAppsPrivacy() throws {
        let manifest = PrivacyManifest.manifest(privacy: [
            "NSPrivacyTracking": true,
            "NSPrivacyTrackingDomains": ["example.com"],
            "NSPrivacyAccessedAPITypes": [
                ["NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategorySystemBootTime", "NSPrivacyAccessedAPITypeReasons": ["35F9.1", "8FFB.1"]],
                ["NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults", "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]],
            ],
        ])
        #expect(manifest["NSPrivacyTracking"] as? Bool == true)
        #expect(manifest["NSPrivacyTrackingDomains"] as? [String] == ["example.com"])
        let accessed = manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        #expect(accessed.count == 2)
        #expect(accessed[0]["NSPrivacyAccessedAPITypeReasons"] as? [String] == ["35F9.1", "8FFB.1"])
    }
}

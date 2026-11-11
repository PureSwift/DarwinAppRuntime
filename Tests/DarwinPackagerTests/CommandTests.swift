import Foundation
import Testing
@testable import DarwinPackager

@Suite struct CommandTests {

    @Test func quotesForLogs() {
        let command = Command("xcrun", ["codesign", "--sign", "Apple Development: A (B)", "it's"], environment: ["A": "1"], directory: "/a b")
        #expect(command.description == "(cd '/a b' && A=1 xcrun codesign --sign 'Apple Development: A (B)' 'it'\\''s')")
    }

    @Test func compilesTheIcon() {
        let compiler = IconCompiler(platform: .iosSimulator, deploymentTarget: "15.0")
        let command = compiler.compile(
            catalog: URL(fileURLWithPath: "/work/icon/Assets.xcassets"),
            into: URL(fileURLWithPath: "/out/ExampleApp.app"),
            partialInfoPlist: URL(fileURLWithPath: "/work/icon/partial-Info.plist")
        )
        #expect(command.description == "xcrun actool /work/icon/Assets.xcassets --compile /out/ExampleApp.app --platform iphonesimulator --minimum-deployment-target 15.0 --app-icon AppIcon --output-partial-info-plist /work/icon/partial-Info.plist --target-device iphone --target-device ipad --errors --warnings --output-format human-readable-text")
        let mac = IconCompiler(platform: .macos, deploymentTarget: "12.0").compile(
            catalog: URL(fileURLWithPath: "/c"), into: URL(fileURLWithPath: "/r"), partialInfoPlist: URL(fileURLWithPath: "/p")
        )
        #expect(mac.arguments.contains("macosx"))
        #expect(mac.arguments.suffix(6).starts(with: ["--target-device", "mac"]))
    }

    @Test func describesTheIconSet() {
        #expect(IconCompiler(platform: .ios, deploymentTarget: "15.0").images.map(\.entry) == [
            ["filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"],
        ])
        let mac = IconCompiler(platform: .macos, deploymentTarget: "12.0").images
        #expect(mac.count == 10)
        #expect(mac.first?.pixels == 16)
        #expect(mac.last?.pixels == nil)
        #expect(mac.last?.entry == ["filename": "icon_512x512@2x.png", "idiom": "mac", "scale": "2x", "size": "512x512"])
    }

    @Test func installsAndLaunchesOnTheSimulator() {
        let app = URL(fileURLWithPath: "/out/ExampleApp.app")
        #expect(Distribution.simulatorInstall(app: app, device: "booted").description == "xcrun simctl install booted /out/ExampleApp.app")
        let launch = Distribution.simulatorLaunch(bundleIdentifier: "org.pureswift.example", device: "booted")
        #expect(launch.description == "xcrun simctl launch --console-pty --terminate-running-process booted org.pureswift.example")
        #expect(launch.streamsOutput)
    }

    @Test func notarizes() {
        #expect(Distribution.zipForNotarization(app: URL(fileURLWithPath: "/out/A.app"), output: URL(fileURLWithPath: "/work/A.zip")).description
            == "ditto -c -k --sequesterRsrc --keepParent /out/A.app /work/A.zip")
        #expect(Distribution.notarize(zip: URL(fileURLWithPath: "/work/A.zip"), keychainProfile: "notary").description
            == "xcrun notarytool submit /work/A.zip --keychain-profile notary --wait")
        #expect(Distribution.staple(app: URL(fileURLWithPath: "/out/A.app")).description == "xcrun stapler staple /out/A.app")
    }

    @Test func zipsAnIPA() {
        #expect(Distribution.ipa(payload: URL(fileURLWithPath: "/work/Payload"), output: URL(fileURLWithPath: "/out/A.ipa")).description
            == "ditto -c -k --sequesterRsrc --keepParent /work/Payload /out/A.ipa")
    }

    @Test func laysOutApps() {
        let ios = AppLayout(app: URL(fileURLWithPath: "/A.app"), platform: .ios)
        #expect(ios.infoPlist.path == "/A.app/Info.plist")
        #expect(ios.executable(named: "A").path == "/A.app/A")
        #expect(ios.embeddedProfile.path == "/A.app/embedded.mobileprovision")
        let mac = AppLayout(app: URL(fileURLWithPath: "/A.app"), platform: .macos)
        #expect(mac.infoPlist.path == "/A.app/Contents/Info.plist")
        #expect(mac.executable(named: "A").path == "/A.app/Contents/MacOS/A")
        #expect(mac.resources.path == "/A.app/Contents/Resources")
        #expect(mac.pkgInfo.path == "/A.app/Contents/PkgInfo")
    }

    @Test func readsTheSDK() throws {
        let runner = RecordingRunner()
        runner.answerSDKQueries(platform: .macos)
        let sdk = try SDKInfo.read(for: .macos, runner: runner)
        #expect(sdk == SDKInfo(name: "macosx", path: "/SDKs/macosx.sdk", version: "27.2", build: "24C100", xcodeVersion: "27.2", xcodeBuild: "27B52"))
        #expect(sdk.xcodeNumber == "2720")
    }

    @Test func throwsOnFailure() {
        let runner = RecordingRunner()
        runner.on({ _ in true }, { _ in CommandOutput(status: 1, standardError: "boom") })
        #expect {
            try runner.check(.xcrun("actool"))
        } throws: {
            ($0 as? PackagerError)?.message.contains("boom") == true
        }
    }

    @Test func runsProcesses() throws {
        let runner = ProcessRunner(log: .silent)
        let output = try runner.run(Command("sh", ["-c", "echo out; echo err >&2; echo $X; exit 3"], environment: ["X": "x"]))
        #expect(output == CommandOutput(status: 3, standardOutput: "out\nx\n", standardError: "err\n"))
    }
}

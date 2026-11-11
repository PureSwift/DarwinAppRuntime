import Foundation
import Testing
@testable import DarwinPackager

@Suite struct PipelineTests {

    struct Setup {
        let directory: TemporaryDirectory
        let runner: RecordingRunner
        let options: PackageOptions
    }

    func setup(_ fixture: FixtureBundle = FixtureBundle(), platform: ApplePlatform, real: Bool = false, configure: (inout PackageOptions) -> Void = { _ in }) throws -> Setup {
        let directory = try TemporaryDirectory()
        let bundle = try fixture.write(in: directory.url)
        let runner = RecordingRunner(fallback: real ? ProcessRunner(log: .silent) : nil)
        if !real {
            runner.answerSDKQueries(platform: platform)
        }
        let architectures = platform == .ios ? ["arm64"] : ["x86_64", "arm64"]
        runner.answerSliceQueries(platform: platform, architectures: architectures, minimum: platform.isMac ? "11.0" : "13.0")
        runner.fakeHostBuild(in: directory.url, binary: real ? URL(fileURLWithPath: "/usr/bin/true") : nil)
        var options = PackageOptions(
            bundle: bundle,
            platform: platform,
            output: directory.file(platform == .ios ? "out/ExampleApp.ipa" : "out/ExampleApp.app"),
            workDirectory: directory.file("work"),
            hostPackage: HostPackage.defaultHostPackage,
            environment: ["APPRUNTIME_PATH": "/src/AppRuntime"]
        )
        configure(&options)
        return Setup(directory: directory, runner: runner, options: options)
    }

    func plist(_ url: URL) throws -> [String: Any] {
        try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] ?? [:]
    }

    @Test func packagesForMacOS() throws {
        let setup = try setup(platform: .macos)
        let result = try Packager(options: setup.options, runner: setup.runner, log: .silent).package()
        let app = setup.directory.file("out/ExampleApp.app")
        let work = setup.directory.file("work")
        #expect(result.app.path == app.path)
        #expect(result.artifact.path == app.path)
        #expect(result.executable.path == app.appendingPathComponent("Contents/MacOS/ExampleApp").path)

        // The app's files.
        let fileManager = FileManager.default
        #expect(fileManager.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/ExampleApp").path))
        #expect(try String(contentsOf: app.appendingPathComponent("Contents/PkgInfo"), encoding: .utf8) == "APPL????")
        #expect(fileManager.fileExists(atPath: app.appendingPathComponent("Contents/Resources/en.lproj/Manifest.strings").path))
        #expect(fileManager.fileExists(atPath: app.appendingPathComponent("Contents/Resources/PrivacyInfo.xcprivacy").path))
        let strings = try StringsFile.read(app.appendingPathComponent("Contents/Resources/es.lproj/InfoPlist.strings"))
        #expect(strings["CFBundleDisplayName"] == "Ejemplo")
        let info = try plist(app.appendingPathComponent("Contents/Info.plist"))
        #expect(info["LSMinimumSystemVersion"] as? String == "12.0")
        #expect(info["DTPlatformVersion"] as? String == "27.2")
        #expect(info["NSBluetoothAlwaysUsageDescription"] as? String == "Looks for beacons.")
        let entitlements = try plist(work.appendingPathComponent("ExampleApp.entitlements"))
        #expect(Set(entitlements.keys) == ["com.apple.security.app-sandbox", "com.apple.security.device.bluetooth"])

        // The host package links the staged slice.
        let manifest = try String(contentsOf: work.appendingPathComponent("host/Package.swift"), encoding: .utf8)
        let staged = try fileManager.contentsOfDirectory(atPath: work.path).filter { $0.hasPrefix("libapp-") }
        #expect(staged.count == 1)
        #expect(manifest.contains(work.appendingPathComponent(staged[0]).path))

        // The commands, in order.
        let lines = setup.runner.lines
        let build = try #require(setup.runner.commands.first { $0.streamsOutput })
        #expect(build.environment == ["APPRUNTIME_PATH": "/src/AppRuntime"])
        #expect(build.arguments.suffix(4) == ["--arch", "arm64", "--arch", "x86_64"])
        #expect(lines.suffix(2) == [
            "xcrun codesign --force --sign - --entitlements \(work.path)/ExampleApp.entitlements --options runtime --timestamp=none \(app.path)",
            "xcrun codesign --verify --deep --strict --verbose=2 \(app.path)",
        ])
        #expect(!lines.contains { $0.contains("actool") })
    }

    @Test func packagesAnIPA() throws {
        var fixture = FixtureBundle().with(["RTIcon": "icon.png"])
        fixture.files["icon.png"] = Data("png".utf8)
        let setup = try setup(fixture, platform: .ios)
        let result = try Packager(options: setup.options, runner: setup.runner, log: .silent).package()
        let work = setup.directory.file("work")
        #expect(result.app.path == work.appendingPathComponent("Payload/ExampleApp.app").path)
        #expect(result.artifact.path == setup.directory.file("out/ExampleApp.ipa").path)
        #expect(result.diagnostics.contains(.warning("an ad hoc signed app doesn't install on a device; pass --sign and --profile")))
        let info = try plist(result.app.appendingPathComponent("Info.plist"))
        #expect(info["MinimumOSVersion"] as? String == "15.0")
        #expect(FileManager.default.fileExists(atPath: result.app.appendingPathComponent("ExampleApp").path))
        let lines = setup.runner.lines
        let build = try #require(setup.runner.commands.first { $0.streamsOutput })
        #expect(build.arguments.suffix(4) == ["--triple", "arm64-apple-ios15.0", "--sdk", "/SDKs/iphoneos.sdk"])
        #expect(lines.contains { $0.hasPrefix("xcrun actool \(work.path)/icon/Assets.xcassets --compile \(result.app.path) --platform iphoneos") })
        #expect(lines.last == "ditto -c -k --sequesterRsrc --keepParent \(work.path)/Payload \(result.artifact.path)")
    }

    @Test func translatesWasmWithoutASlice() throws {
        var fixture = FixtureBundle()
        fixture.files["lib/ios-simulator/libapp.a"] = nil
        let appRuntime = try TemporaryDirectory()
        try FileManager.default.createDirectory(at: appRuntime.file("Scripts"), withIntermediateDirectories: true)
        try Data().write(to: appRuntime.file("Scripts/wasm2c-shim.py"))
        let setup = try setup(fixture, platform: .iosSimulator) { $0.appRuntime = appRuntime.url.path }
        let work = setup.directory.file("work")
        setup.runner.on({ $0.executable == "python3" }, { _ in
            try FileManager.default.createDirectory(at: work.appendingPathComponent("wasm2c"), withIntermediateDirectories: true)
            try Data("wasm2c".utf8).write(to: work.appendingPathComponent("wasm2c/libapp.a"))
            return CommandOutput()
        })
        _ = try Packager(options: setup.options, runner: setup.runner, log: .silent).package()
        let shim = try #require(setup.runner.commands.first { $0.executable == "python3" })
        #expect(shim.arguments == [
            appRuntime.url.appendingPathComponent("Scripts/wasm2c-shim.py").path, "build",
            "--wasm", work.appendingPathComponent("bundle/wasm32/App.wasm").path,
            "--output", work.appendingPathComponent("wasm2c").path,
            "--target", "\(HostArchitecture.current)-apple-ios15.0-simulator", "--sdk", "iphonesimulator",
        ])
        #expect(setup.runner.lines.contains("xcrun nm -u \(work.path)/wasm2c/libapp.a"))
    }

    @Test func stopsOnValidationErrors() throws {
        let setup = try setup(FixtureBundle().with(["RTABIVersion": 2]), platform: .macos)
        #expect {
            try Packager(options: setup.options, runner: setup.runner, log: .silent).package()
        } throws: { error in
            (error as? PackagerError)?.diagnostics == [.error("the app needs rt ABI 2; this host provides 1"), .warning("the app has no icon")]
        }
        #expect(!setup.runner.commands.contains { $0.streamsOutput })
    }

    @Test func checksSigningOptions() throws {
        let notarize = try setup(platform: .macos) { $0.notarize = true }
        #expect(throws: PackagerError.self) {
            try Packager(options: notarize.options, runner: notarize.runner, log: .silent).package()
        }
        let device = try setup(platform: .ios) { $0.identity = "Apple Distribution: Example" }
        #expect {
            try Packager(options: device.options, runner: device.runner, log: .silent).package()
        } throws: { ($0 as? PackagerError)?.message.contains("--profile") == true }
    }

    @Test func notarizesAndStaples() throws {
        let setup = try setup(platform: .macos) {
            $0.identity = "Developer ID Application: Example (TEAM123456)"
            $0.notarize = true
            $0.keychainProfile = "notary"
        }
        _ = try Packager(options: setup.options, runner: setup.runner, log: .silent).package()
        let app = setup.directory.file("out/ExampleApp.app").path
        let zip = setup.directory.file("work/ExampleApp.zip").path
        #expect(setup.runner.lines.suffix(3) == [
            "ditto -c -k --sequesterRsrc --keepParent \(app) \(zip)",
            "xcrun notarytool submit \(zip) --keychain-profile notary --wait",
            "xcrun stapler staple \(app)",
        ])
    }

    @Test func runsOnTheSimulator() throws {
        let setup = try setup(platform: .iosSimulator) { $0.configuration = .debug }
        setup.runner.on(["simctl", "list"], output: "== Devices ==\n-- iOS 26.5 --\n    iPhone 17 (1314BAE9) (Booted)\n")
        try Packager(options: setup.options, runner: setup.runner, log: .silent).run()
        let app = setup.directory.file("out/ExampleApp.app").path
        #expect(setup.runner.lines.suffix(2) == [
            "xcrun simctl install booted \(app)",
            "xcrun simctl launch --console-pty --terminate-running-process booted org.pureswift.example",
        ])
        let build = try #require(setup.runner.commands.first { $0.streamsOutput })
        #expect(build.arguments.contains("debug"))
    }

    @Test func needsABootedSimulator() throws {
        let setup = try setup(platform: .iosSimulator)
        setup.runner.on(["simctl", "list"], output: "== Devices ==\n")
        #expect {
            try Packager(options: setup.options, runner: setup.runner, log: .silent).run()
        } throws: { ($0 as? PackagerError)?.message.contains("no simulator is booted") == true }
    }

    @Test func runsOnMacOS() throws {
        let setup = try setup(platform: .macos)
        try Packager(options: setup.options, runner: setup.runner, log: .silent).run()
        #expect(setup.runner.lines.last == setup.directory.file("out/ExampleApp.app/Contents/MacOS/ExampleApp").path)
    }

    // MARK: - With Xcode's tools

    static let hasXcode = FileManager.default.fileExists(atPath: "/usr/bin/xcrun")
        && FileManager.default.fileExists(atPath: "/Applications/Xcode.app")

    /// The pipeline with the real `actool`, `sips` and `codesign`, and a
    /// stand-in executable instead of the host build.
    @Test(.enabled(if: hasXcode), arguments: [ApplePlatform.macos, .iosSimulator])
    func packagesWithXcodesTools(platform: ApplePlatform) throws {
        var fixture = FixtureBundle().with(["RTIcon": "icon.png"])
        fixture.files["icon.png"] = Data()
        let setup = try setup(fixture, platform: platform, real: true)
        try writeIcon(to: setup.options.bundle.appendingPathComponent("icon.png"))
        try FixtureBundle.writeCodeResources(for: setup.options.bundle)
        let result = try Packager(options: setup.options, runner: setup.runner, log: .silent).package()
        let layout = AppLayout(app: result.app, platform: platform)
        let fileManager = FileManager.default
        #expect(fileManager.fileExists(atPath: layout.resources.appendingPathComponent("Assets.car").path))
        let info = try plist(layout.infoPlist)
        if platform.isMac {
            #expect(info["CFBundleIconName"] as? String == "AppIcon")
            #expect(fileManager.fileExists(atPath: layout.resources.appendingPathComponent("AppIcon.icns").path))
        } else {
            let icons = info["CFBundleIcons"] as? [String: Any]
            #expect((icons?["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconName"] as? String == "AppIcon")
        }
        // codesign --verify passed inside package(); check the entitlements.
        let output = try ProcessRunner(log: .silent).check(.xcrun("codesign", "-d", "--entitlements", ":-", result.app.path)).standardOutput
        if platform.isMac {
            #expect(output.contains("com.apple.security.app-sandbox"))
        }
    }
}

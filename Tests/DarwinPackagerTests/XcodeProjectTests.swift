import Foundation
import Testing
@testable import DarwinPackager

@Suite struct XcodeProjectTests {

    func writer(platform: ApplePlatform = .iosSimulator, team: String? = nil, entitlements: Bool = true) -> XcodeProjectWriter {
        XcodeProjectWriter(
            name: "ExampleApp",
            bundleIdentifier: "org.example.app",
            platform: platform,
            deploymentTarget: platform.isMac ? "12.0" : "15.0",
            architectures: ["arm64", "x86_64"],
            hostPackage: URL(fileURLWithPath: "/src/DarwinAppRuntime"),
            directory: URL(fileURLWithPath: "/src/MyApp/build/xcode/\(platform.rawValue)"),
            resources: ["en.lproj", "PrivacyInfo.xcprivacy"],
            hasEntitlements: entitlements,
            team: team
        )
    }

    /// `project.pbxproj` parsed, as Xcode reads it: an OpenStep property list.
    func parse(_ writer: XcodeProjectWriter) throws -> (objects: [String: [String: Any]], root: [String: Any]) {
        let text = writer.pbxproj
        let parsed = try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
        let plist = try #require(parsed as? [String: Any])
        #expect(plist["objectVersion"] as? String == "60")
        let objects = try #require(plist["objects"] as? [String: [String: Any]])
        return (objects, try lookup(objects, plist["rootObject"]))
    }

    /// The object an ID names; `id` may be an array, for its first.
    func lookup(_ objects: [String: [String: Any]], _ id: Any?) throws -> [String: Any] {
        let key = try #require((id as? String) ?? (id as? [String])?.first)
        return try #require(objects[key])
    }

    func targetSettings(_ objects: [String: [String: Any]], _ root: [String: Any], configuration: String = "Debug") throws -> [String: Any] {
        let target = try lookup(objects, root["targets"])
        let list = try lookup(objects, target["buildConfigurationList"])
        let configurations = (list["buildConfigurations"] as? [String] ?? []).compactMap { objects[$0] }
        let debug = try #require(configurations.first { $0["name"] as? String == configuration })
        return try #require(debug["buildSettings"] as? [String: Any])
    }

    @Test func theProjectIsAnOpenStepPropertyList() throws {
        let (objects, root) = try parse(writer())
        #expect(root["isa"] as? String == "PBXProject")
        let target = try lookup(objects, root["targets"])
        #expect(target["isa"] as? String == "PBXNativeTarget")
        #expect(target["name"] as? String == "ExampleApp")
        #expect(target["productType"] as? String == "com.apple.product-type.application")

        let package = try lookup(objects, root["packageReferences"])
        #expect(package["isa"] as? String == "XCLocalSwiftPackageReference")
        #expect(package["relativePath"] as? String == "../../../../DarwinAppRuntime")
        let product = try lookup(objects, target["packageProductDependencies"])
        #expect(product["productName"] as? String == "DarwinHostApp")

        let phases = (target["buildPhases"] as? [String] ?? []).compactMap { objects[$0] }
        #expect(phases.map { $0["isa"] as? String } == ["PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase"])
        let resources = (phases[2]["files"] as? [String] ?? []).compactMap { objects[$0]?["fileRef"] as? String }.compactMap { objects[$0] }
        #expect(resources.map { $0["path"] as? String } == ["en.lproj", "PrivacyInfo.xcprivacy"])
    }

    @Test func targetSettings() throws {
        let (objects, root) = try parse(writer())
        let settings = try targetSettings(objects, root)
        #expect(settings["PRODUCT_NAME"] as? String == "ExampleApp")
        #expect(settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String == "org.example.app")
        #expect(settings["INFOPLIST_FILE"] as? String == "ExampleApp/Info.plist")
        #expect(settings["GENERATE_INFOPLIST_FILE"] as? String == "NO")
        #expect(settings["OTHER_LDFLAGS"] as? [String] == ["$(PROJECT_DIR)/ExampleApp/libapp.a"])
        #expect(settings["CODE_SIGN_ENTITLEMENTS"] as? String == "ExampleApp/ExampleApp.entitlements")
        #expect(settings["CODE_SIGN_IDENTITY"] as? String == "-")
        #expect(settings["ARCHS"] as? String == "arm64 x86_64")
        #expect(settings["TARGETED_DEVICE_FAMILY"] as? String == "1,2")

        let list = try lookup(objects, root["buildConfigurationList"])
        let project = (list["buildConfigurations"] as? [String] ?? []).compactMap { objects[$0] }
        let debug = try #require(project.first { $0["name"] as? String == "Debug" }?["buildSettings"] as? [String: Any])
        #expect(debug["SDKROOT"] as? String == "iphoneos")
        #expect(debug["SUPPORTED_PLATFORMS"] as? String == "iphonesimulator")
        #expect(debug["IPHONEOS_DEPLOYMENT_TARGET"] as? String == "15.0")
        #expect(debug["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] as? String == "DEBUG")
    }

    @Test func macOSAndTeams() throws {
        let (objects, root) = try parse(writer(platform: .macos, team: "ABCDE12345", entitlements: false))
        let settings = try targetSettings(objects, root, configuration: "Release")
        #expect(settings["DEVELOPMENT_TEAM"] as? String == "ABCDE12345")
        #expect(settings["CODE_SIGN_IDENTITY"] == nil)
        #expect(settings["CODE_SIGN_ENTITLEMENTS"] == nil)
        #expect(settings["TARGETED_DEVICE_FAMILY"] == nil)
        #expect(settings["LD_RUNPATH_SEARCH_PATHS"] as? [String] == ["$(inherited)", "@executable_path/../Frameworks"])
    }

    @Test func theSameProjectComesOutTheSame() {
        #expect(writer().pbxproj == writer().pbxproj)
        #expect(writer().id("target") != writer().id("project"))
        #expect(writer().id("target").count == 24)
    }

    @Test func theSchemeRunsTheTarget() throws {
        let writer = writer()
        #expect(writer.schemeFile.path.hasSuffix("ExampleApp.xcodeproj/xcshareddata/xcschemes/ExampleApp.xcscheme"))
        #expect(writer.scheme.contains(#"BlueprintIdentifier = "\#(writer.id("target"))""#))
        #expect(writer.scheme.contains(#"ReferencedContainer = "container:ExampleApp.xcodeproj""#))
        #expect(writer.scheme.contains("<LaunchAction"))
        let (_, root) = try parse(writer)
        #expect((root["targets"] as? [String]) == [writer.id("target")])
    }

    @Test func quoting() {
        #expect(XcodeProjectWriter.Value.quote("iphoneos") == "iphoneos")
        #expect(XcodeProjectWriter.Value.quote("") == "\"\"")
        #expect(XcodeProjectWriter.Value.quote("-Onone") == "\"-Onone\"")
        #expect(XcodeProjectWriter.Value.quote("<group>") == "\"<group>\"")
        #expect(XcodeProjectWriter.Value.quote("say \"hi\"\n") == #""say \"hi\"\n""#)
    }

    @Test func relativePaths() {
        func path(_ from: String, _ to: String) -> String {
            XcodeProjectWriter.relativePath(from: URL(fileURLWithPath: from), to: URL(fileURLWithPath: to))
        }
        #expect(path("/src/app/build", "/src/DarwinAppRuntime") == "../../DarwinAppRuntime")
        #expect(path("/src/app", "/src/app/host") == "host")
        #expect(path("/src/app", "/src/app") == ".")
        #expect(path("/tmp/app", "/Users/me/DarwinAppRuntime") == "/Users/me/DarwinAppRuntime")
    }

    // MARK: darwin-app xcodeproj

    @Test func writesTheProjectAndItsFiles() throws {
        let directory = try TemporaryDirectory()
        let bundle = try FixtureBundle().write(in: directory.url)
        let runner = RecordingRunner()
        runner.answerSDKQueries(platform: .iosSimulator)
        runner.answerSliceQueries(platform: .iosSimulator, architectures: ["arm64", "x86_64"])
        let options = PackageOptions(
            bundle: bundle,
            platform: .iosSimulator,
            output: directory.file("xcode"),
            workDirectory: directory.file("work"),
            hostPackage: HostPackage.defaultHostPackage
        )
        let project = try Packager(options: options, runner: runner, log: .silent).xcodeProject()
        #expect(project.path == directory.file("xcode/ExampleApp.xcodeproj").path)

        let fileManager = FileManager.default
        let support = directory.file("xcode/ExampleApp")
        #expect(try String(contentsOf: support.appendingPathComponent("main.swift"), encoding: .utf8) == HostPackage.mainSwift)
        #expect(fileManager.fileExists(atPath: support.appendingPathComponent("libapp.a").path))
        #expect(fileManager.fileExists(atPath: support.appendingPathComponent("Resources/en.lproj/Manifest.strings").path))
        #expect(fileManager.fileExists(atPath: support.appendingPathComponent("Resources/es.lproj/InfoPlist.strings").path))
        #expect(fileManager.fileExists(atPath: support.appendingPathComponent("Resources/PrivacyInfo.xcprivacy").path))
        #expect(!fileManager.fileExists(atPath: support.appendingPathComponent("Resources/PkgInfo").path), "Xcode writes it")
        #expect(!fileManager.fileExists(atPath: support.appendingPathComponent("Resources/Info.plist").path))
        let infoData = try Data(contentsOf: support.appendingPathComponent("Info.plist"))
        let info = try #require(try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any])
        #expect(info["CFBundleExecutable"] as? String == "ExampleApp")
        #expect(info["NSBluetoothAlwaysUsageDescription"] as? String == "Looks for beacons.")
        #expect(info["UIDeviceFamily"] == nil, "Xcode writes it from TARGETED_DEVICE_FAMILY")

        #expect(fileManager.fileExists(atPath: project.appendingPathComponent("project.pbxproj").path))
        #expect(fileManager.fileExists(atPath: project.appendingPathComponent("xcshareddata/xcschemes/ExampleApp.xcscheme").path))
        let pbxproj = try String(contentsOf: project.appendingPathComponent("project.pbxproj"), encoding: .utf8)
        let identifier = try #require(info["CFBundleIdentifier"] as? String)
        #expect(pbxproj.contains("PRODUCT_BUNDLE_IDENTIFIER = \(identifier);"))
        #expect(!fileManager.fileExists(atPath: directory.file("work/xcode-files").path), "the staged files are moved")

        // Writing again replaces it.
        _ = try Packager(options: options, runner: runner, log: .silent).xcodeProject()
        #expect(fileManager.fileExists(atPath: support.appendingPathComponent("main.swift").path))
    }
}

import Foundation

/// What `validate`, `package` and `run` work from.
public struct PackageOptions {

    /// The universal bundle, `<id>.app`.
    public var bundle: URL

    public var platform: ApplePlatform

    public var configuration: BuildConfiguration

    /// `nil` picks the slice when there is one, otherwise wasm2c.
    public var engine: Engine?

    /// A `codesign` identity; `-` signs ad hoc.
    public var identity: String

    /// A provisioning profile, for device builds.
    public var profile: URL?

    /// The `.app`, or for an iOS device the `.ipa`. By default
    /// `build/<platform>/<executable>.app` (or `.ipa`) in the current
    /// directory.
    public var output: URL?

    /// Where the bundle's copy, wasm2c output, the host package and its
    /// build go. By default `.build/darwin-app/<platform>` in the current
    /// directory. Reusing it reuses the host's build.
    public var workDirectory: URL?

    /// Notarizes and staples a macOS app.
    public var notarize: Bool

    /// The `notarytool store-credentials` profile.
    public var keychainProfile: String?

    /// DarwinAppRuntime's checkout, which the host package depends on.
    public var hostPackage: URL

    /// AppRuntime's checkout, for wasm2c and `APPRUNTIME_PATH`; by default
    /// `APPRUNTIME_PATH`.
    public var appRuntime: String?

    /// See `Compatibility.allowsMissingContracts`.
    public var allowsMissingContracts: Bool

    /// The `swift` command that builds the host; Xcode's by default, since
    /// App Store builds have to be linked with Xcode's toolchain (§5).
    public var swift: [String]

    /// For `run` on the simulator: a device name or UDID.
    public var simulator: String

    /// The packager's environment, for `APPRUNTIME_PATH`.
    public var environment: [String: String]

    public init(
        bundle: URL,
        platform: ApplePlatform,
        configuration: BuildConfiguration = .release,
        engine: Engine? = nil,
        identity: String = CodeSign.adHoc,
        profile: URL? = nil,
        output: URL? = nil,
        workDirectory: URL? = nil,
        notarize: Bool = false,
        keychainProfile: String? = nil,
        hostPackage: URL = HostPackage.defaultHostPackage,
        appRuntime: String? = nil,
        allowsMissingContracts: Bool = false,
        swift: [String] = ["xcrun", "swift"],
        simulator: String = "booted",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.bundle = bundle
        self.platform = platform
        self.configuration = configuration
        self.engine = engine
        self.identity = identity
        self.profile = profile
        self.output = output
        self.workDirectory = workDirectory
        self.notarize = notarize
        self.keychainProfile = keychainProfile
        self.hostPackage = hostPackage
        self.appRuntime = appRuntime
        self.allowsMissingContracts = allowsMissingContracts
        self.swift = swift
        self.simulator = simulator
        self.environment = environment
    }

    var currentDirectory: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    var resolvedWorkDirectory: URL {
        workDirectory ?? currentDirectory.appendingPathComponent(".build/darwin-app/\(platform.rawValue)")
    }

    /// `APPRUNTIME_PATH` for the host build, when there's one.
    var appRuntimePath: String? {
        appRuntime ?? environment["APPRUNTIME_PATH"]
    }
}

/// What `validate` found.
public struct Validation {

    public var bundle: UniversalBundle

    public var diagnostics: [Diagnostic]

    /// `nil` when no engine fits.
    public var engine: EngineChoice?

    public var deploymentTarget: String?
}

/// What `package` made.
public struct PackageResult {

    /// The signed app.
    public var app: URL

    /// The deliverable: the `.ipa` for an iOS device, the app otherwise.
    public var artifact: URL

    public var bundleIdentifier: String

    /// The app's main executable.
    public var executable: URL

    public var diagnostics: [Diagnostic]
}

/// `darwin-app`'s pipeline (`ManifestPackager.md` §3).
public struct Packager {

    public var options: PackageOptions

    public var runner: any CommandRunner

    public var log: PackagerLog

    public init(options: PackageOptions, runner: any CommandRunner = ProcessRunner(), log: PackagerLog = .standardError) {
        self.options = options
        self.runner = runner
        self.log = log
    }

    var platform: ApplePlatform {
        options.platform
    }

    var fileManager: FileManager {
        .default
    }

    // MARK: - validate

    /// Steps 1–3 and the slice checks, on the bundle in place. Never
    /// throws for problems in the bundle: they're diagnostics.
    public func validate() throws -> Validation {
        log.step("Reading \(options.bundle.path)")
        let bundle = try UniversalBundle(url: options.bundle)
        return try validate(bundle)
    }

    func validate(_ bundle: UniversalBundle) throws -> Validation {
        log.step("Verifying files against \(UniversalBundle.codeResourcesPath)")
        var diagnostics = try bundle.verify()
        log.step("Checking compatibility with this host on \(platform.rawValue)")
        let compatibility = Compatibility(platform: platform, allowsMissingContracts: options.allowsMissingContracts)
        diagnostics += compatibility.check(bundle)
        let deploymentTarget = try? compatibility.deploymentTarget(bundle)
        var choice: EngineChoice?
        do {
            choice = try EngineChoice.choose(for: bundle, platform: platform, requested: options.engine, configuration: options.configuration)
        } catch {
            diagnostics.append(.error(error.message))
        }
        if let choice {
            log.info("engine: \(choice.engine.rawValue) (\(choice.reason))")
        }
        if let choice, choice.engine == .native, let slice = bundle.slice(for: platform), let deploymentTarget {
            log.step("Checking lib/\(platform.sliceTarget)/libapp.a")
            diagnostics += try checkLibrary(slice, engine: .native, deploymentTarget: deploymentTarget).diagnostics
        }
        if bundle.iconURL == nil {
            diagnostics.append(.warning("the app has no icon"))
        }
        return Validation(bundle: bundle, diagnostics: diagnostics, engine: choice, deploymentTarget: deploymentTarget)
    }

    /// The architectures the app is built for: arm64 on a device, the Mac's
    /// own in the simulator, and on macOS each of arm64 and x86_64 that the
    /// library has (both, for a universal app).
    func architectures(library: [String]?) -> [String] {
        switch platform {
        case .ios:
            return ["arm64"]
        case .iosSimulator:
            return [HostArchitecture.current]
        case .macos:
            guard let library else {
                return ["arm64", "x86_64"]
            }
            let both = ["arm64", "x86_64"].filter(library.contains)
            return both.isEmpty ? [HostArchitecture.current] : both
        }
    }

    func checkLibrary(_ library: URL, engine: Engine, deploymentTarget: String) throws -> (architectures: [String], diagnostics: [Diagnostic]) {
        let inspector = SliceInspector(runner: runner)
        let report = try inspector.inspect(library)
        let architectures = architectures(library: report.architectures)
        log.info("architectures: \(report.architectures.joined(separator: ", ")); building \(architectures.joined(separator: ", "))")
        let diagnostics = SliceInspector.check(report, platform: platform, architectures: architectures, deploymentTarget: deploymentTarget, engine: engine)
        return (architectures, diagnostics)
    }

    // MARK: - package

    /// Steps 1–8.
    public func package() throws -> PackageResult {
        let work = options.resolvedWorkDirectory
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        try checkSigningOptions()

        // 1–3, on a copy, so the bundle can't change after it's verified.
        log.step("Copying \(options.bundle.path) to the work directory \(work.path)")
        let copy = work.appendingPathComponent("bundle")
        try replace(copy, with: options.bundle)
        let bundle = try UniversalBundle(url: copy)
        let validation = try validate(bundle)
        report(validation.diagnostics)
        try PackagerError.check(validation.diagnostics, "validation")
        var diagnostics = validation.diagnostics
        guard let choice = validation.engine, let deploymentTarget = validation.deploymentTarget else {
            throw PackagerError("no engine fits the bundle")
        }
        log.info("bundle: \(bundle.identifier) \(bundle.version) (\(bundle.build)), \(platform.rawValue) \(deploymentTarget)")

        let sdk = try SDKInfo.read(for: platform, runner: runner)
        log.info("SDK: \(sdk.name) \(sdk.version), Xcode \(sdk.xcodeVersion) (\(sdk.xcodeBuild))")

        // 4. The library.
        let library: URL
        let architectures: [String]
        switch choice.engine {
        case .native:
            library = bundle.slice(for: platform)!
            architectures = self.architectures(library: try SliceInspector(runner: runner).inspect(library).architectures)
        case .wasm2c:
            log.step("Translating wasm32/App.wasm with wasm2c")
            let appRuntime = try Wasm2cBuild.appRuntime(option: options.appRuntime, environment: options.environment)
            let build = Wasm2cBuild(
                appRuntime: appRuntime,
                wasm: bundle.wasm!,
                output: work.appendingPathComponent("wasm2c"),
                platform: platform,
                architectures: self.architectures(library: nil),
                deploymentTarget: deploymentTarget
            )
            try runner.check(build.command)
            log.step("Checking the wasm2c library")
            let checked = try checkLibrary(build.library, engine: .wasm2c, deploymentTarget: deploymentTarget)
            report(checked.diagnostics)
            try PackagerError.check(checked.diagnostics, "the wasm2c library's checks")
            diagnostics += checked.diagnostics
            library = build.library
            architectures = checked.architectures
        case .interpreter:
            throw PackagerError("--engine interpreter isn't implemented yet")
        }

        // 5. The executable.
        let linked = try stageLibrary(library, in: work)
        let executable = try buildExecutable(library: linked, work: work, deploymentTarget: deploymentTarget, architectures: architectures, sdk: sdk)

        // 6. The app.
        let artifact = outputURL(bundle)
        let app = platform == .ios
            ? work.appendingPathComponent("Payload/\(bundle.executable).app")
            : artifact
        let layout = AppLayout(app: app, platform: platform)
        diagnostics += try assemble(bundle, executable: executable, layout: layout, deploymentTarget: deploymentTarget, sdk: sdk, work: work)

        // 7. Signing.
        diagnostics += try sign(bundle, layout: layout, work: work)

        // 8. Packaging.
        if platform == .ios {
            log.step("Zipping \(artifact.lastPathComponent)")
            try removeIfPresent(artifact)
            try fileManager.createDirectory(at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
            try runner.check(Distribution.ipa(payload: app.deletingLastPathComponent(), output: artifact))
        }
        if options.notarize {
            try notarize(app: app, work: work)
        }
        log.step("Done: \(artifact.path)")
        return PackageResult(
            app: app,
            artifact: artifact,
            bundleIdentifier: bundle.identifier,
            executable: layout.executable(named: bundle.executable),
            diagnostics: diagnostics
        )
    }

    func checkSigningOptions() throws {
        if options.notarize {
            guard platform == .macos else {
                throw PackagerError("--notarize is for macOS apps")
            }
            guard options.identity != CodeSign.adHoc else {
                throw PackagerError("--notarize needs --sign with a Developer ID Application identity")
            }
            guard options.keychainProfile != nil else {
                throw PackagerError("--notarize needs --keychain-profile, a profile saved with `xcrun notarytool store-credentials`")
            }
            guard options.configuration == .release else {
                throw PackagerError("--notarize needs --configuration release; debug builds allow debuggers to attach, which notarization rejects")
            }
        }
        if platform == .ios, options.identity != CodeSign.adHoc, options.profile == nil {
            throw PackagerError("signing for an iOS device needs --profile, the app's provisioning profile")
        }
        if platform == .iosSimulator, options.profile != nil {
            throw PackagerError("simulator builds are signed ad hoc and take no --profile")
        }
    }

    func outputURL(_ bundle: UniversalBundle) -> URL {
        if let output = options.output {
            return output
        }
        let name = bundle.executable + (platform == .ios ? ".ipa" : ".app")
        return options.currentDirectory.appendingPathComponent("build/\(platform.rawValue)/\(name)")
    }

    /// Copies the library to `libapp-<hash>.a` in the work directory. The
    /// hash in the name changes the host package's manifest when the
    /// library changes, so SwiftPM relinks; it doesn't track linker inputs
    /// passed as flags.
    func stageLibrary(_ library: URL, in work: URL) throws -> URL {
        let hash = try UniversalBundle.sha256Hex(of: library).prefix(16)
        let staged = work.appendingPathComponent("libapp-\(hash).a")
        for name in try fileManager.contentsOfDirectory(atPath: work.path)
            where name.hasPrefix("libapp-") && name.hasSuffix(".a") && name != staged.lastPathComponent {
            try fileManager.removeItem(at: work.appendingPathComponent(name))
        }
        if !fileManager.fileExists(atPath: staged.path) {
            try fileManager.copyItem(at: library, to: staged)
        }
        return staged
    }

    func buildExecutable(library: URL, work: URL, deploymentTarget: String, architectures: [String], sdk: SDKInfo) throws -> URL {
        log.step("Building the host executable with DarwinHostApp from \(options.hostPackage.path)")
        let package = HostPackage(
            hostPackage: options.hostPackage,
            library: library,
            platform: platform,
            deploymentTarget: deploymentTarget,
            sdkVersion: sdk.version
        )
        let directory = work.appendingPathComponent("host")
        try package.write(to: directory)
        log.info("host package: \(directory.path)")
        var environment = [String: String]()
        if let appRuntime = options.appRuntimePath {
            environment["APPRUNTIME_PATH"] = appRuntime
        }
        let build = package.buildCommand(
            directory: directory, configuration: options.configuration, architectures: architectures,
            sdkPath: sdk.path, swift: options.swift, environment: environment
        )
        try runner.check(build)
        let binPath = try runner.output(of: package.binPathCommand(
            directory: directory, configuration: options.configuration, architectures: architectures,
            sdkPath: sdk.path, swift: options.swift, environment: environment
        ))
        // `--show-bin-path` may print resolution notes before the path.
        let lastLine = binPath.split(whereSeparator: \.isNewline).last.map(String.init) ?? binPath
        let executable = URL(fileURLWithPath: lastLine).appendingPathComponent(HostPackage.targetName)
        guard fileManager.fileExists(atPath: executable.path) else {
            throw PackagerError("swift build didn't produce \(executable.path)")
        }
        return executable
    }

    // MARK: - Assembly

    /// Names the packager writes at the top of the app's resources, which
    /// `resources/` can't hold.
    static let reservedResourceNames: Set<String> = [
        "Info.plist", "PkgInfo", "_CodeSignature", "PrivacyInfo.xcprivacy", "Assets.car",
        "embedded.mobileprovision", "MacOS", "Resources", "Contents",
    ]

    func assemble(_ bundle: UniversalBundle, executable: URL, layout: AppLayout, deploymentTarget: String, sdk: SDKInfo, work: URL) throws -> [Diagnostic] {
        log.step("Assembling \(layout.app.path)")
        var diagnostics = [Diagnostic]()
        try removeIfPresent(layout.app)
        try fileManager.createDirectory(at: layout.executableDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: layout.resources, withIntermediateDirectories: true)
        try fileManager.copyItem(at: executable, to: layout.executable(named: bundle.executable))

        // Resources, as they are.
        if let resources = bundle.resources {
            for name in try fileManager.contentsOfDirectory(atPath: resources.path).sorted() {
                if Self.reservedResourceNames.contains(name) || name == bundle.executable {
                    throw PackagerError("resources/\(name) would replace a file the packager writes")
                }
                try fileManager.copyItem(at: resources.appendingPathComponent(name), to: layout.resources.appendingPathComponent(name))
            }
        }

        // InfoPlist.strings (§4.2).
        let translator = InfoPlistTranslator(bundle: bundle, platform: platform, deploymentTarget: deploymentTarget)
        for (language, strings) in try translator.infoPlistStrings() {
            let directory = layout.resources.appendingPathComponent("\(language).lproj")
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("InfoPlist.strings")
            if fileManager.fileExists(atPath: file.path) {
                diagnostics.append(.warning("resources/\(language).lproj/InfoPlist.strings is replaced by the one generated from Manifest.strings"))
            }
            try StringsFile.text(strings).write(to: file, atomically: true, encoding: .utf8)
        }

        // The icon (§4.3).
        var iconKeys = [String: Any]()
        if let icon = bundle.iconURL {
            log.step("Compiling the icon with actool")
            let compiler = IconCompiler(platform: platform, deploymentTarget: deploymentTarget)
            let directory = work.appendingPathComponent("icon")
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let catalog = try compiler.writeCatalog(icon: icon, in: directory, runner: runner)
            let partial = directory.appendingPathComponent("partial-Info.plist")
            try runner.check(compiler.compile(catalog: catalog, into: layout.resources, partialInfoPlist: partial))
            if let data = try? Data(contentsOf: partial),
               let keys = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                iconKeys = keys
            }
        } else if bundle.icon != nil {
            diagnostics.append(.warning("RTIcon names \(bundle.icon!), which the bundle doesn't have; the app has no icon"))
        }

        // The privacy manifest (§6).
        try PrivacyManifest.manifest(privacy: bundle.apple.privacy).propertyListData()
            .write(to: layout.resources.appendingPathComponent(PrivacyManifest.fileName))

        // Info.plist and PkgInfo.
        let info = try translator.infoPlist(sdk: sdk, iconKeys: iconKeys)
        try info.propertyListData().write(to: layout.infoPlist)
        try Data("APPL????".utf8).write(to: layout.pkgInfo)
        report(diagnostics)
        return diagnostics
    }

    // MARK: - Signing

    func sign(_ bundle: UniversalBundle, layout: AppLayout, work: URL) throws -> [Diagnostic] {
        log.step("Signing with \(options.identity == CodeSign.adHoc ? "an ad hoc signature" : options.identity)")
        var diagnostics = [Diagnostic]()
        var entitlements = Entitlements.forCapabilities(bundle, platform: platform, configuration: options.configuration)
        if let profileURL = options.profile {
            let profile = try ProvisioningProfile.read(profileURL, runner: runner)
            let merged = try profile.entitlements(adding: entitlements, bundleIdentifier: bundle.identifier, platform: platform)
            entitlements = merged.entitlements
            diagnostics += merged.diagnostics
            try fileManager.copyItem(at: profileURL, to: layout.embeddedProfile)
        } else if options.identity == CodeSign.adHoc {
            if platform == .macos {
                for key in entitlements.keys.sorted() where Entitlements.isRestricted(key) {
                    entitlements[key] = nil
                    diagnostics.append(.warning("left out \(key): an ad hoc signed app can't have it; sign with --sign and --profile"))
                }
            }
            if platform == .ios {
                diagnostics.append(.warning("an ad hoc signed app doesn't install on a device; pass --sign and --profile"))
            }
        }
        let entitlementsURL = work.appendingPathComponent("\(bundle.executable).entitlements")
        try entitlements.propertyListData().write(to: entitlementsURL)
        log.info("entitlements: \(entitlements.keys.sorted().joined(separator: ", "))")
        report(diagnostics)
        try runner.check(CodeSign.sign(app: layout.app, identity: options.identity, entitlements: entitlementsURL, platform: platform))
        try runner.check(CodeSign.verify(app: layout.app))
        return diagnostics
    }

    func notarize(app: URL, work: URL) throws {
        log.step("Notarizing \(app.lastPathComponent)")
        let zip = work.appendingPathComponent(app.deletingPathExtension().lastPathComponent + ".zip")
        try removeIfPresent(zip)
        try runner.check(Distribution.zipForNotarization(app: app, output: zip))
        try runner.check(Distribution.notarize(zip: zip, keychainProfile: options.keychainProfile!))
        try runner.check(Distribution.staple(app: app))
    }

    // MARK: - run

    /// Packages, then installs and launches the app on the simulator, or
    /// launches the macOS app, streaming its output until it exits.
    public func run() throws {
        switch platform {
        case .ios:
            throw PackagerError("run supports ios-simulator and macos; install a device build from its .ipa with Xcode or `xcrun devicectl device install app`")
        case .iosSimulator:
            if options.simulator == "booted" {
                let booted = try runner.output(of: Distribution.bootedSimulators())
                guard booted.contains("(Booted)") else {
                    throw PackagerError("no simulator is booted; boot one with `xcrun simctl boot \"iPhone 17\"` (see `xcrun simctl list devices`), or pass --simulator")
                }
            }
            let result = try package()
            log.step("Installing on the simulator (\(options.simulator))")
            try runner.check(Distribution.simulatorInstall(app: result.app, device: options.simulator))
            log.step("Launching \(result.bundleIdentifier); its output follows")
            try runner.check(Distribution.simulatorLaunch(bundleIdentifier: result.bundleIdentifier, device: options.simulator))
        case .macos:
            let result = try package()
            log.step("Launching \(result.app.lastPathComponent); its output follows")
            try runner.check(Distribution.macLaunch(executable: result.executable))
        }
    }

    // MARK: - Helpers

    func report(_ diagnostics: [Diagnostic]) {
        for diagnostic in diagnostics {
            log.diagnostic(diagnostic)
        }
    }

    func removeIfPresent(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func replace(_ destination: URL, with source: URL) throws {
        try removeIfPresent(destination)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
    }
}

import ArgumentParser
import DarwinPackager
import Foundation

/// `darwin-app`: an AppRuntime universal bundle into a signed iOS or macOS
/// app (`ManifestPackager.md` §2).
struct DarwinApp: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "darwin-app",
        abstract: "Turns an AppRuntime universal bundle into a signed iOS or macOS app.",
        subcommands: [Validate.self, Package.self, Run.self, Dev.self, XcodeProject.self]
    )
}

extension ApplePlatform: ExpressibleByArgument {}

extension BuildConfiguration: ExpressibleByArgument {}

extension Engine: ExpressibleByArgument {}

/// The bundle and platform every command takes.
struct BundleOptions: ParsableArguments {

    @Argument(help: "The universal bundle, <id>.app, from AppRuntime's `guest.py bundle`.")
    var bundle: String

    @Option(help: "ios, ios-simulator or macos.")
    var platform: ApplePlatform

    @Option(help: "native (the bundle's slice) or wasm2c (App.wasm translated to C). Default: the slice when the bundle has one.")
    var engine: Engine?

    @Flag(help: "Contracts this host doesn't implement are warnings, not errors. For test apps such as AppRuntime's ExampleApp.")
    var allowMissingContracts = false

    @Option(help: "AppRuntime's checkout, for wasm2c and the host build. Default: $APPRUNTIME_PATH.")
    var appruntime: String?

    var bundleURL: URL {
        URL(fileURLWithPath: bundle).standardizedFileURL
    }
}

/// The options of commands that build.
struct BuildOptions: ParsableArguments {

    @Option(help: "Sign with this identity; `-` signs ad hoc.")
    var sign: String = CodeSign.adHoc

    @Option(help: "The provisioning profile, for device builds.")
    var profile: String?

    @Option(help: "The .app, or .ipa for an iOS device. Default: build/<platform>/<executable>.app or .ipa.")
    var output: String?

    @Option(help: "Where the host package and its build go. Default: .build/darwin-app/<platform>. Reusing it reuses the host's build.")
    var workDirectory: String?

    @Option(help: "DarwinAppRuntime's checkout, which the host executable is built from. Default: the one darwin-app was built from.")
    var hostPackage: String?

    @Option(help: "The swift command that builds the host executable. Default: `xcrun swift`, Xcode's.")
    var swift: String?

    func packageOptions(_ bundle: BundleOptions, configuration: BuildConfiguration) -> PackageOptions {
        PackageOptions(
            bundle: bundle.bundleURL,
            platform: bundle.platform,
            configuration: configuration,
            engine: bundle.engine,
            identity: sign,
            profile: profile.map(Self.url),
            output: output.map(Self.url),
            workDirectory: workDirectory.map(Self.url),
            hostPackage: hostPackage.map(Self.url) ?? HostPackage.defaultHostPackage,
            appRuntime: bundle.appruntime.map { Self.url($0).path },
            allowsMissingContracts: bundle.allowMissingContracts,
            swift: swift.map { $0.split(separator: " ").map(String.init) } ?? ["xcrun", "swift"]
        )
    }

    static func url(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL
    }
}

/// Prints a packager error with its diagnostics, and exits with 1.
func fail(_ error: Error) -> ExitCode {
    let log = PackagerLog.standardError
    if let error = error as? PackagerError {
        for diagnostic in error.diagnostics {
            log.diagnostic(diagnostic)
        }
        log.write("error: \(error.message)")
    } else {
        log.write("error: \(error)")
    }
    return .failure
}

struct Validate: ParsableCommand {

    static let configuration = CommandConfiguration(
        abstract: "Checks a bundle against this host for a platform: files, ABI, contracts, capabilities, engine and slice."
    )

    @OptionGroup var bundle: BundleOptions

    @Option(help: "debug or release.")
    var configuration: BuildConfiguration = .release

    func run() throws {
        let options = PackageOptions(
            bundle: bundle.bundleURL,
            platform: bundle.platform,
            configuration: configuration,
            engine: bundle.engine,
            appRuntime: bundle.appruntime,
            allowsMissingContracts: bundle.allowMissingContracts
        )
        let log = PackagerLog.standardError
        do {
            let validation = try Packager(options: options, runner: ProcessRunner(log: log), log: log).validate()
            for diagnostic in validation.diagnostics {
                log.diagnostic(diagnostic)
            }
            if validation.diagnostics.hasErrors {
                log.write("error: \(bundle.bundle) can't be packaged for \(bundle.platform.rawValue)")
                throw ExitCode.failure
            }
            print("ok: \(validation.bundle.identifier) can be packaged for \(bundle.platform.rawValue) with \(validation.engine?.engine.rawValue ?? "?")")
        } catch let exit as ExitCode {
            throw exit
        } catch {
            throw fail(error)
        }
    }
}

struct Package: ParsableCommand {

    static let configuration = CommandConfiguration(
        abstract: "Builds, signs and packages the app: an .app, or an .ipa for an iOS device."
    )

    @OptionGroup var bundle: BundleOptions

    @OptionGroup var build: BuildOptions

    @Option(help: "debug or release.")
    var configuration: BuildConfiguration = .release

    @Flag(help: "Notarize and staple a macOS app (needs --sign and --keychain-profile).")
    var notarize = false

    @Option(help: "The `xcrun notarytool store-credentials` profile.")
    var keychainProfile: String?

    func run() throws {
        var options = build.packageOptions(bundle, configuration: configuration)
        options.notarize = notarize
        options.keychainProfile = keychainProfile
        do {
            let result = try Packager(options: options).package()
            print(result.artifact.path)
        } catch {
            throw fail(error)
        }
    }
}

struct Run: ParsableCommand {

    static let configuration = CommandConfiguration(
        abstract: "Packages the app, then installs and launches it on the booted simulator, or launches it on this Mac, streaming its output."
    )

    @OptionGroup var bundle: BundleOptions

    @OptionGroup var build: BuildOptions

    @Option(help: "debug or release.")
    var configuration: BuildConfiguration = .debug

    @Option(help: "The simulator, a name or UDID.")
    var simulator: String = "booted"

    func run() throws {
        var options = build.packageOptions(bundle, configuration: configuration)
        options.simulator = simulator
        do {
            try Packager(options: options).run()
        } catch {
            throw fail(error)
        }
    }
}

struct Dev: ParsableCommand {

    static let configuration = CommandConfiguration(
        abstract: "Runs the app in an interpreter host that reloads App.wasm when it changes (not implemented yet)."
    )

    @OptionGroup var bundle: BundleOptions

    func run() throws {
        throw fail(PackagerError("dev isn't implemented yet: it needs DarwinWasmHost, the WasmKit host, which is blocked on where AppRuntime's RuntimeWasm package lives (HostRuntime.md §11). Use `darwin-app run` meanwhile."))
    }
}

struct XcodeProject: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "xcodeproj",
        abstract: "Writes an Xcode project that builds and runs the app, for debugging the host and the guest in Xcode."
    )

    @OptionGroup var bundle: BundleOptions

    @Option(help: "The directory for <executable>.xcodeproj and its files. Default: build/xcode/<platform>.")
    var output: String?

    @Option(help: "Where the bundle's copy and wasm2c output go. Default: .build/darwin-app/<platform>.")
    var workDirectory: String?

    @Option(help: "DarwinAppRuntime's checkout, which the project depends on. Default: the one darwin-app was built from.")
    var hostPackage: String?

    @Option(help: "The development team, for a device or restricted entitlements. Without one, the app is signed to run locally.")
    var team: String?

    func run() throws {
        let options = PackageOptions(
            bundle: bundle.bundleURL,
            platform: bundle.platform,
            configuration: .debug,
            engine: bundle.engine,
            output: output.map(BuildOptions.url),
            workDirectory: workDirectory.map(BuildOptions.url),
            hostPackage: hostPackage.map(BuildOptions.url) ?? HostPackage.defaultHostPackage,
            appRuntime: bundle.appruntime.map { BuildOptions.url($0).path },
            allowsMissingContracts: bundle.allowMissingContracts
        )
        do {
            let project = try Packager(options: options).xcodeProject(team: team)
            print(project.path)
        } catch {
            throw fail(error)
        }
    }
}

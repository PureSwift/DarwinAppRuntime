import Foundation

/// How the guest runs in the app (`HostRuntime.md` §2.1).
public enum Engine: String, CaseIterable, Sendable {

    /// The bundle's slice for the platform, linked as it is.
    case native

    /// `App.wasm` translated to C by WABT's wasm2c and compiled.
    case wasm2c

    /// `App.wasm` interpreted by WasmKit: development builds only.
    case interpreter
}

/// Step 3: the engine for a bundle on a platform.
public struct EngineChoice: Equatable, Sendable {

    public var engine: Engine

    /// Why, for logs.
    public var reason: String

    public init(engine: Engine, reason: String) {
        self.engine = engine
        self.reason = reason
    }

    /// Picks the slice when the bundle has one and `requested` allows it,
    /// otherwise wasm2c.
    public static func choose(
        for bundle: UniversalBundle,
        platform: ApplePlatform,
        requested: Engine?,
        configuration: BuildConfiguration
    ) throws(PackagerError) -> EngineChoice {
        let hasSlice = bundle.slice(for: platform) != nil
        let hasWasm = bundle.wasm != nil
        switch requested {
        case .native:
            guard hasSlice else {
                throw PackagerError("--engine native needs lib/\(platform.sliceTarget)/libapp.a, which the bundle doesn't have; build it with guest.py bundle --target \(platform.sliceTarget), or use --engine wasm2c")
            }
            return EngineChoice(engine: .native, reason: "requested; lib/\(platform.sliceTarget)/libapp.a")
        case .wasm2c:
            guard hasWasm else {
                throw PackagerError("--engine wasm2c needs wasm32/App.wasm, which the bundle doesn't have")
            }
            return EngineChoice(engine: .wasm2c, reason: "requested; wasm32/App.wasm")
        case .interpreter:
            if configuration == .release {
                throw PackagerError("--engine interpreter is for debug builds only; release builds never interpret App.wasm")
            }
            throw PackagerError("--engine interpreter isn't implemented yet: it needs DarwinWasmHost, which is blocked on where AppRuntime's RuntimeWasm package lives (HostRuntime.md §11)")
        case nil:
            if hasSlice {
                return EngineChoice(engine: .native, reason: "the bundle has lib/\(platform.sliceTarget)/libapp.a")
            }
            if hasWasm {
                return EngineChoice(engine: .wasm2c, reason: "the bundle has no \(platform.sliceTarget) slice; translating wasm32/App.wasm")
            }
            throw PackagerError("the bundle has neither lib/\(platform.sliceTarget)/libapp.a nor wasm32/App.wasm")
        }
    }
}

/// AppRuntime's `Scripts/wasm2c-shim.py build`, which turns `App.wasm` into
/// a `libapp.a` like a native slice (step 4).
public struct Wasm2cBuild: Equatable, Sendable {

    /// AppRuntime's checkout.
    public var appRuntime: URL

    public var wasm: URL

    /// The directory the script writes into; it leaves `libapp.a` there.
    public var output: URL

    public var platform: ApplePlatform

    public var architectures: [String]

    public var deploymentTarget: String

    public init(appRuntime: URL, wasm: URL, output: URL, platform: ApplePlatform, architectures: [String], deploymentTarget: String) {
        self.appRuntime = appRuntime
        self.wasm = wasm
        self.output = output
        self.platform = platform
        self.architectures = architectures
        self.deploymentTarget = deploymentTarget
    }

    public var script: URL {
        appRuntime.appendingPathComponent("Scripts/wasm2c-shim.py")
    }

    public var library: URL {
        output.appendingPathComponent("libapp.a")
    }

    public var command: Command {
        var arguments = [script.path, "build", "--wasm", wasm.path, "--output", output.path]
        for architecture in architectures {
            arguments += ["--target", platform.triple(architecture: architecture, minimum: deploymentTarget)]
        }
        arguments += ["--sdk", platform.sdk]
        return Command("python3", arguments)
    }

    /// AppRuntime's checkout from `--appruntime` or `APPRUNTIME_PATH`.
    public static func appRuntime(option: String?, environment: [String: String]) throws(PackagerError) -> URL {
        guard let path = option ?? environment["APPRUNTIME_PATH"], !path.isEmpty else {
            throw PackagerError("wasm2c needs AppRuntime's Scripts/wasm2c-shim.py: pass --appruntime PATH or set APPRUNTIME_PATH to an AppRuntime checkout")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("Scripts/wasm2c-shim.py").path) else {
            throw PackagerError("\(url.path) has no Scripts/wasm2c-shim.py; is it an AppRuntime checkout?")
        }
        return url
    }
}

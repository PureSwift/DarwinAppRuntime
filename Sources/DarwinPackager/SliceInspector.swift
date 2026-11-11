import Foundation

/// The checks on a `libapp.a` before linking (step 5): its architectures,
/// its undefined symbols, and its `LC_BUILD_VERSION`.
public struct SliceInspector {

    public var runner: any CommandRunner

    public init(runner: any CommandRunner) {
        self.runner = runner
    }

    /// What a library holds.
    public struct Report: Equatable, Sendable {

        public var architectures: [String]

        /// Undefined symbols, without the leading underscore.
        public var undefinedSymbols: Set<String>

        /// Each object's `LC_BUILD_VERSION`.
        public var buildVersions: [BuildVersion]
    }

    /// One object's `LC_BUILD_VERSION`.
    public struct BuildVersion: Equatable, Sendable {

        /// The member, such as `libapp.a(app-arm64.o) (architecture arm64)`.
        public var object: String

        /// `PLATFORM_*` from `<mach-o/loader.h>`.
        public var platform: UInt32

        public var minimum: String
    }

    /// Runs `lipo -archs`, `nm -u` and `otool -l` on the library.
    ///
    /// `vtool -show-build` reads only Mach-O files, not archives, so the
    /// build versions come from `otool -l`, which reads every member of a
    /// thin or universal archive.
    public func inspect(_ library: URL) throws -> Report {
        let architectures = try runner.output(of: .xcrun("lipo", "-archs", library.path))
            .split(whereSeparator: \.isWhitespace).map(String.init)
        let symbols = try runner.output(of: .xcrun("nm", "-u", library.path))
        let loadCommands = try runner.output(of: .xcrun("otool", "-l", library.path))
        return Report(
            architectures: architectures,
            undefinedSymbols: Self.parseUndefined(symbols),
            buildVersions: Self.parseBuildVersions(loadCommands)
        )
    }

    /// Checks a library for a platform.
    ///
    /// - Parameters:
    ///   - architectures: the architectures the app is built for; each must
    ///     be in the library.
    ///   - engine: wasm2c output also uses the libc functions of WABT's
    ///     runtime.
    public func check(
        _ library: URL,
        platform: ApplePlatform,
        architectures: [String],
        deploymentTarget: String,
        engine: Engine
    ) throws -> [Diagnostic] {
        let report = try inspect(library)
        return Self.check(report, platform: platform, architectures: architectures, deploymentTarget: deploymentTarget, engine: engine)
    }

    public static func check(
        _ report: Report,
        platform: ApplePlatform,
        architectures: [String],
        deploymentTarget: String,
        engine: Engine
    ) -> [Diagnostic] {
        var diagnostics = [Diagnostic]()
        let missing = architectures.filter { !report.architectures.contains($0) }
        if !missing.isEmpty {
            diagnostics.append(.error("the library has \(report.architectures.joined(separator: ", ")), not \(missing.joined(separator: ", ")), which \(platform.rawValue) needs"))
        }
        let disallowed = report.undefinedSymbols.filter { !isAllowed($0, engine: engine) }.sorted()
        if !disallowed.isEmpty {
            diagnostics.append(.error("the library leaves symbols undefined that only rt_* and libc may: \(disallowed.joined(separator: ", "))"))
        }
        if report.buildVersions.isEmpty {
            diagnostics.append(.error("the library has no LC_BUILD_VERSION; it wasn't built for \(platform.rawValue)"))
        }
        let target = OSVersion(deploymentTarget)
        for version in report.buildVersions {
            if version.platform != platform.machOPlatform {
                diagnostics.append(.error("\(version.object) is built for \(platformName(version.platform)), not \(platformName(platform.machOPlatform))"))
            } else if let minimum = OSVersion(version.minimum), let target, minimum > target {
                diagnostics.append(.error("\(version.object) needs \(platformName(version.platform)) \(version.minimum), above the app's minimum \(deploymentTarget)"))
            }
        }
        return diagnostics
    }

    // MARK: Symbols

    /// What a sealed native slice may leave undefined (AppRuntime's
    /// `guest.py`, `ALLOWED_UNDEFINED` and `ALLOWED_APPLE`; §7.5), less
    /// OpenGL, which this host doesn't provide.
    static let nativeAllowed: Set<String> = [
        "malloc", "free", "posix_memalign", "memcpy", "memmove", "memset", "memcmp",
        "abort", "write", "clock_gettime", "arc4random_buf", "getentropy", "putchar",
        "bzero", "__bzero", "ceil", "floor", "trunc", "round", "roundf", "sqrt", "fmod",
        "__stack_chk_fail", "__stack_chk_guard",
    ]

    /// What WABT's runtime and the wasm2c shim add.
    static let wasm2cAllowed: Set<String> = [
        "calloc", "realloc", "strlen", "fwrite", "perror", "__stderrp", "__assert_rtn",
        "clock_getres", "mmap", "munmap", "mprotect", "sigsetjmp", "siglongjmp",
        "pthread_mutex_init", "pthread_mutex_lock", "pthread_mutex_unlock", "_tlv_bootstrap",
    ]

    /// compiler-rt helpers that libSystem re-exports, as in `guest.py`:
    /// `__<stem>[a-z]*[0-9]?`.
    static let compilerRuntimeStems = [
        "ashl", "ashr", "lshr", "mul", "div", "udiv", "mod", "umod", "neg", "add", "sub",
        "eq", "ne", "lt", "le", "gt", "ge", "unord", "cmp", "ucmp", "fix", "fixuns",
        "float", "floatun", "extend", "trunc", "pow",
    ]

    static func isCompilerRuntime(_ symbol: String) -> Bool {
        guard symbol.hasPrefix("__") else {
            return false
        }
        let name = symbol.dropFirst(2)
        return compilerRuntimeStems.contains { stem in
            guard name.hasPrefix(stem) else {
                return false
            }
            var rest = name.dropFirst(stem.count)
            if let last = rest.last, last.isASCII, last.isNumber {
                rest = rest.dropLast()
            }
            return rest.allSatisfy { $0.isASCII && $0.isLowercase }
        }
    }

    static func isAllowed(_ symbol: String, engine: Engine) -> Bool {
        if symbol.hasPrefix("rt_") || nativeAllowed.contains(symbol) {
            return true
        }
        if engine == .wasm2c, wasm2cAllowed.contains(symbol) {
            return true
        }
        return isCompilerRuntime(symbol)
    }

    /// `nm -u` output: symbol lines, and `path(member):` headers.
    static func parseUndefined(_ output: String) -> Set<String> {
        var symbols = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasSuffix(":") else {
                continue
            }
            // Mach-O C symbols carry a leading underscore.
            symbols.insert(text.hasPrefix("_") ? String(text.dropFirst()) : text)
        }
        return symbols
    }

    // MARK: Build versions

    /// `otool -l` output: a header line per object, then its load commands.
    static func parseBuildVersions(_ output: String) -> [BuildVersion] {
        var versions = [BuildVersion]()
        var object = ""
        var inBuildVersion = false
        var platform: UInt32?
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix(" "), text.hasSuffix(":"), !text.hasPrefix("Load command") {
                object = URL(fileURLWithPath: String(text.dropLast())).lastPathComponent
                inBuildVersion = false
                continue
            }
            if text.hasPrefix("cmd ") {
                inBuildVersion = text == "cmd LC_BUILD_VERSION"
                platform = nil
                continue
            }
            guard inBuildVersion else {
                continue
            }
            let words = text.split(separator: " ", omittingEmptySubsequences: true)
            guard words.count >= 2 else {
                continue
            }
            if words[0] == "platform" {
                platform = UInt32(words[1]) ?? platformNumber(String(words[1]))
            } else if words[0] == "minos", let platform {
                versions.append(BuildVersion(object: object, platform: platform, minimum: String(words[1])))
                inBuildVersion = false
            }
        }
        return versions
    }

    static let platformNames: [UInt32: String] = [
        1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 6: "Mac Catalyst",
        7: "iOS Simulator", 8: "tvOS Simulator", 9: "watchOS Simulator",
        11: "visionOS", 12: "visionOS Simulator",
    ]

    static func platformName(_ platform: UInt32) -> String {
        platformNames[platform] ?? "platform \(platform)"
    }

    /// `vtool`'s and newer `otool`'s spellings.
    static func platformNumber(_ name: String) -> UInt32? {
        let names: [String: UInt32] = [
            "MACOS": 1, "IOS": 2, "TVOS": 3, "WATCHOS": 4, "MACCATALYST": 6,
            "IOSSIMULATOR": 7, "TVOSSIMULATOR": 8, "WATCHOSSIMULATOR": 9,
            "VISIONOS": 11, "XROS": 11, "VISIONOSSIMULATOR": 12, "XROSSIMULATOR": 12,
        ]
        return names[name.uppercased()]
    }
}

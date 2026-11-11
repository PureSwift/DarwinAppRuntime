import CryptoKit
import Foundation
@testable import DarwinPackager

/// A temporary directory, removed when the value is deinitialized.
final class TemporaryDirectory {

    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DarwinPackagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ path: String) -> URL {
        url.appendingPathComponent(path)
    }
}

/// A universal bundle written the way `guest.py bundle` writes one.
struct FixtureBundle {

    var info: [String: Any] = FixtureBundle.defaultInfo

    /// Relative path → contents.
    var files: [String: Data] = [
        "wasm32/App.wasm": Data("\0asm".utf8),
        "lib/macos/libapp.a": Data("macos".utf8),
        "lib/ios-arm64/libapp.a": Data("ios".utf8),
        "lib/ios-simulator/libapp.a": Data("sim".utf8),
        "resources/en.lproj/Manifest.strings": Data("""
            "app.name" = "Example";
            "perm.bluetooth" = "Looks for beacons.";
            """.utf8),
        "resources/es.lproj/Manifest.strings": Data("""
            "app.name" = "Ejemplo";
            "perm.bluetooth" = "Busca balizas.";
            """.utf8),
    ]

    static var defaultInfo: [String: Any] {
        [
            "CFBundleIdentifier": "org.pureswift.example",
            "CFBundleName": "Example",
            "CFBundleDisplayName": "Example",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleExecutable": "ExampleApp",
            "CFBundleLocalizations": ["en", "es"],
            "CFBundleDevelopmentRegion": "en",
            "RTABIVersion": 1,
            "RTTargets": ["wasm32", "macos", "ios-arm64", "ios-simulator"],
            "RTCapabilities": ["bluetooth"],
            "RTCapabilityUsage": ["bluetooth": "perm.bluetooth"],
            "RTContracts": [
                ["Name": "org.pureswift.bluetooth.Central", "Version": 1, "Kind": "contract"],
                ["Name": "org.pureswift.bluetooth.CentralDelegate", "Version": 1, "Kind": "callback"],
            ],
            "RTDisplayNameKey": "app.name",
            "RTPlatforms": [
                "ios": ["Minimum": "15.0"],
                "macos": ["Minimum": "12.0"],
                "android": ["MinSDK": 26, "TargetSDK": 35],
            ],
            "RTPlatformExtras": [
                "apple": ["category": "public.app-category.developer-tools", "extraInfoPlist": [String: Any]()],
            ],
        ]
    }

    /// Writes `<id>.app` into `directory`, with `CodeResources`.
    func write(in directory: URL) throws -> URL {
        let bundle = directory.appendingPathComponent("\(info["CFBundleIdentifier"] as? String ?? "app").app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        var all = files
        all["Info.plist"] = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        for (path, data) in all {
            let url = bundle.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try Self.writeCodeResources(for: bundle)
        return bundle
    }

    /// `guest.py`'s `code_resources`: `{"files": {path: SHA-256}}`.
    static func writeCodeResources(for bundle: URL) throws {
        var hashes = [String: Data]()
        for path in try UniversalBundle.files(in: bundle) {
            hashes[path] = Data(SHA256.hash(data: try Data(contentsOf: bundle.appendingPathComponent(path))))
        }
        let directory = bundle.appendingPathComponent("_CodeSignature")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["files": hashes], format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("CodeResources"))
    }

    /// Writes the bundle into a new directory inside `directory`, and reads
    /// it.
    func read(in directory: URL) throws -> UniversalBundle {
        try UniversalBundle(url: write(in: directory.appendingPathComponent(UUID().uuidString)))
    }

    /// The bundle with Info.plist values replaced; `nil` removes a key.
    func with(_ changes: [String: Any?]) -> FixtureBundle {
        var copy = self
        for (key, value) in changes {
            copy.info[key] = value
        }
        return copy
    }
}

/// Records commands and answers them from canned outputs.
final class RecordingRunner: CommandRunner, @unchecked Sendable {

    private let lock = NSLock()

    private var recorded = [Command]()

    /// Runs commands no answer matches; `nil` makes them succeed silently.
    let fallback: (any CommandRunner)?

    init(fallback: (any CommandRunner)? = nil) {
        self.fallback = fallback
    }

    /// Answers, first match wins; an unmatched command succeeds silently.
    private var responses = [(matches: @Sendable (Command) -> Bool, respond: @Sendable (Command) throws -> CommandOutput)]()

    var commands: [Command] {
        lock.withLock { recorded }
    }

    /// Each command's executable and arguments, joined by spaces.
    var lines: [String] {
        commands.map { ([$0.executable] + $0.arguments).joined(separator: " ") }
    }

    func on(_ matches: @escaping @Sendable (Command) -> Bool, _ respond: @escaping @Sendable (Command) throws -> CommandOutput) {
        lock.withLock { responses.append((matches, respond)) }
    }

    /// Answers commands whose arguments start with `prefix` (after `xcrun`)
    /// with `output`.
    func on(_ prefix: [String], output: String) {
        on({ command in
            let words = command.executable == "xcrun" ? command.arguments : [command.executable] + command.arguments
            return words.starts(with: prefix)
        }, { _ in CommandOutput(standardOutput: output) })
    }

    func run(_ command: Command) throws -> CommandOutput {
        let handler: (@Sendable (Command) throws -> CommandOutput)? = lock.withLock {
            recorded.append(command)
            return responses.first { $0.matches(command) }?.respond
        }
        if let handler {
            return try handler(command)
        }
        return try fallback?.run(command) ?? CommandOutput()
    }

    /// The answers about Xcode 27.2 and its SDKs.
    func answerSDKQueries(platform: ApplePlatform) {
        on(["--sdk", platform.sdk, "--show-sdk-path"], output: "/SDKs/\(platform.sdk).sdk\n")
        on(["--sdk", platform.sdk, "--show-sdk-version"], output: "27.2\n")
        on(["--sdk", platform.sdk, "--show-sdk-build-version"], output: "24C100\n")
        on(["xcodebuild", "-version"], output: "Xcode 27.2\nBuild version 27B52\n")
    }

    /// Fakes the host build: `swift build` writes `binary` as the
    /// executable, and `--show-bin-path` answers with its directory.
    func fakeHostBuild(in directory: URL, binary: URL? = nil) {
        let bin = directory.appendingPathComponent("fake-bin")
        on({ $0.arguments.contains("build") && $0.arguments.contains("--package-path") }, { command in
            if command.arguments.contains("--show-bin-path") {
                return CommandOutput(standardOutput: bin.path + "\n")
            }
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let executable = bin.appendingPathComponent(HostPackage.targetName)
            try? FileManager.default.removeItem(at: executable)
            if let binary {
                try FileManager.default.copyItem(at: binary, to: executable)
            } else {
                try Data("executable".utf8).write(to: executable)
            }
            return CommandOutput()
        })
    }

    /// Answers the slice checks for a clean library with `architectures`.
    func answerSliceQueries(platform: ApplePlatform, architectures: [String], minimum: String = "13.0") {
        on(["lipo", "-archs"], output: architectures.joined(separator: " ") + "\n")
        on(["nm", "-u"], output: "/x/libapp.a(app.o):\n_rt_call\n_malloc\n_free\n")
        on(["otool", "-l"], output: architectures.map { """
            /x/libapp.a(app-\($0).o) (architecture \($0)):
            Load command 1
                  cmd LC_BUILD_VERSION
              cmdsize 24
             platform \(platform.machOPlatform)
                minos \(minimum)
                  sdk n/a
            """ }.joined(separator: "\n"))
    }
}

/// A 1024×1024 PNG.
func writeIcon(to url: URL) throws {
    // A minimal PNG, built with zlib's stored blocks so no image library is
    // needed: one color, 1024×1024.
    let width = 1024
    var raw = Data()
    let row = Data([0]) + Data(repeating: 0x40, count: width * 3)
    for _ in 0 ..< width {
        raw.append(row)
    }
    var zlib = Data([0x78, 0x01])
    var offset = 0
    while offset < raw.count {
        let size = min(65535, raw.count - offset)
        let final: UInt8 = offset + size == raw.count ? 1 : 0
        zlib.append(final)
        zlib.append(contentsOf: [UInt8(size & 0xff), UInt8(size >> 8), UInt8(~size & 0xff), UInt8((~size >> 8) & 0xff)])
        zlib.append(raw[offset ..< offset + size])
        offset += size
    }
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in raw {
        a = (a + UInt32(byte)) % 65521
        b = (b + a) % 65521
    }
    zlib.append(contentsOf: bigEndian((b << 16) | a))
    func chunk(_ type: String, _ data: Data) -> Data {
        let body = Data(type.utf8) + data
        return Data(bigEndian(UInt32(data.count))) + body + Data(bigEndian(crc32(body)))
    }
    var header = Data(bigEndian(UInt32(width)) + bigEndian(UInt32(width)))
    header.append(contentsOf: [8, 2, 0, 0, 0])
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        + chunk("IHDR", header) + chunk("IDAT", zlib) + chunk("IEND", Data())
    try png.write(to: url)
}

private func bigEndian(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
}

private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffffffff
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0 ..< 8 {
            crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB88320 : 0)
        }
    }
    return ~crc
}

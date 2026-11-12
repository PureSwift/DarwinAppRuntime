import CryptoKit
import Foundation

/// A universal bundle from AppRuntime's `guest.py bundle`
/// (`ManifestPackager.md` §1.1): a directory `<id>.app` with the portable
/// `Info.plist`, `wasm32/App.wasm`, `lib/<target>/libapp.a`, `resources/`,
/// `icon.png` and `_CodeSignature/CodeResources`.
public struct UniversalBundle {

    /// A contract the app uses, from `RTContracts`.
    public struct Contract: Equatable, Hashable, Sendable {

        public var name: String

        public var version: UInt32

        /// `contract` or `callback`.
        public var kind: String

        public init(name: String, version: UInt32, kind: String) {
            self.name = name
            self.version = version
            self.kind = kind
        }
    }

    /// A platform's entry in `RTPlatforms`.
    public struct PlatformRequirement: Equatable, Sendable {

        /// The minimum OS on Apple platforms.
        public var minimum: String?

        public init(minimum: String? = nil) {
            self.minimum = minimum
        }
    }

    /// The bundle's directory.
    public let url: URL

    /// The whole `Info.plist`.
    public let info: [String: Any]

    public let identifier: String

    public let executable: String

    public let name: String

    public let displayName: String

    public let version: String

    public let build: String

    /// `CFBundleLocalizations`; at least the development region.
    public let languages: [String]

    public let developmentRegion: String

    public let abiVersion: UInt32

    /// `RTTargets`.
    public let targets: [String]

    /// `RTCapabilities`.
    public let capabilities: [String]

    public let contracts: [Contract]

    /// `RTPlatforms`; `nil` for a bundle built without a manifest.
    public let platforms: [String: PlatformRequirement]?

    /// `RTCapabilityUsage`: capability → `Manifest.strings` key.
    public let capabilityUsage: [String: String]

    /// `RTCapabilityOptions`: capability → settings, such as location's
    /// `access`.
    public let capabilityOptions: [String: [String: String]]

    /// `RTDisplayNameKey`: the name's `Manifest.strings` key, when it's
    /// localized.
    public let displayNameKey: String?

    /// `RTIcon`: the icon's path in the bundle.
    public let icon: String?

    /// `RTPlatformExtras.apple`.
    public let apple: AppleExtras

    /// Reads the bundle's `Info.plist`.
    public init(url: URL) throws {
        let infoURL = url.appendingPathComponent("Info.plist")
        guard FileManager.default.fileExists(atPath: infoURL.path) else {
            throw PackagerError("\(url.path) is not a universal bundle: it has no Info.plist")
        }
        let data = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw PackagerError("\(infoURL.path) is not a dictionary")
        }
        try self.init(url: url, info: info)
    }

    /// A bundle at `url` with an `Info.plist` already read.
    public init(url: URL, info: [String: Any]) throws {
        self.url = url
        self.info = info
        func string(_ key: String) throws -> String {
            guard let value = info[key] as? String, !value.isEmpty else {
                throw PackagerError("Info.plist has no \(key)")
            }
            return value
        }
        identifier = try string("CFBundleIdentifier")
        executable = try string("CFBundleExecutable")
        name = try string("CFBundleName")
        displayName = info["CFBundleDisplayName"] as? String ?? name
        version = try string("CFBundleShortVersionString")
        build = try string("CFBundleVersion")
        guard let abi = (info["RTABIVersion"] as? NSNumber)?.uint32Value else {
            throw PackagerError("Info.plist has no RTABIVersion")
        }
        abiVersion = abi
        let localizations = info["CFBundleLocalizations"] as? [String] ?? []
        developmentRegion = info["CFBundleDevelopmentRegion"] as? String ?? localizations.first ?? "en"
        languages = localizations.isEmpty ? [developmentRegion] : localizations
        targets = info["RTTargets"] as? [String] ?? []
        capabilities = info["RTCapabilities"] as? [String] ?? []
        var contracts = [Contract]()
        for entry in info["RTContracts"] as? [[String: Any]] ?? [] {
            guard let name = entry["Name"] as? String,
                  let version = (entry["Version"] as? NSNumber)?.uint32Value,
                  let kind = entry["Kind"] as? String else {
                throw PackagerError("Info.plist has a malformed RTContracts entry: \(entry)")
            }
            contracts.append(Contract(name: name, version: version, kind: kind))
        }
        self.contracts = contracts
        if let entries = info["RTPlatforms"] as? [String: Any] {
            var platforms = [String: PlatformRequirement]()
            for (name, value) in entries {
                let values = value as? [String: Any] ?? [:]
                platforms[name] = PlatformRequirement(minimum: values["Minimum"] as? String)
            }
            self.platforms = platforms
        } else {
            platforms = nil
        }
        capabilityUsage = info["RTCapabilityUsage"] as? [String: String] ?? [:]
        var options = [String: [String: String]]()
        for (capability, value) in info["RTCapabilityOptions"] as? [String: Any] ?? [:] {
            var settings = [String: String]()
            for (key, setting) in value as? [String: Any] ?? [:] {
                settings[key] = (setting as? String) ?? "\(setting)"
            }
            options[capability] = settings
        }
        capabilityOptions = options
        displayNameKey = info["RTDisplayNameKey"] as? String
        icon = info["RTIcon"] as? String
        let extras = info["RTPlatformExtras"] as? [String: Any] ?? [:]
        apple = AppleExtras(extras["apple"] as? [String: Any] ?? [:])
    }
}

/// `apple:` in `App.swift`: `RTPlatformExtras.apple`.
public struct AppleExtras {

    /// `LSApplicationCategoryType`, such as
    /// `public.app-category.developer-tools`.
    public var category: String?

    /// Keys merged into the app's `Info.plist` last.
    public var extraInfoPlist: [String: Any]

    /// The app's privacy manifest keys (`NSPrivacyTracking`, …), from
    /// `apple.privacy` in `App.swift` (§1.3, §6).
    public var privacy: [String: Any]

    public init(_ values: [String: Any]) {
        category = values["category"] as? String
        extraInfoPlist = values["extraInfoPlist"] as? [String: Any] ?? [:]
        privacy = values["privacy"] as? [String: Any] ?? [:]
    }
}

public extension UniversalBundle {

    /// `lib/<target>/libapp.a`, when the bundle has the slice.
    func slice(for platform: ApplePlatform) -> URL? {
        let url = url.appendingPathComponent("lib/\(platform.sliceTarget)/libapp.a")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// `wasm32/App.wasm`, when the bundle has it.
    var wasm: URL? {
        let url = url.appendingPathComponent("wasm32/App.wasm")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// `resources/`, when the bundle has it.
    var resources: URL? {
        let url = url.appendingPathComponent("resources")
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue ? url : nil
    }

    /// The icon PNG, when the manifest has one.
    var iconURL: URL? {
        guard let icon else {
            return nil
        }
        let url = url.appendingPathComponent(icon)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A language's `resources/<language>.lproj/Manifest.strings`; `nil`
    /// when there's none.
    func manifestStrings(_ language: String) throws -> [String: String]? {
        guard let resources else {
            return nil
        }
        let url = resources.appendingPathComponent("\(language).lproj/Manifest.strings")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try StringsFile.read(url)
    }
}

// MARK: - Verification

public extension UniversalBundle {

    /// The path of the unsigned per-file hashes `guest.py` writes.
    static let codeResourcesPath = "_CodeSignature/CodeResources"

    /// Checks every file against `_CodeSignature/CodeResources` (step 1):
    /// each listed file exists with its SHA-256, and every file is listed.
    func verify() throws -> [Diagnostic] {
        let resourcesURL = url.appendingPathComponent(Self.codeResourcesPath)
        guard FileManager.default.fileExists(atPath: resourcesURL.path) else {
            return [.error("the bundle has no \(Self.codeResourcesPath); rebuild it with guest.py bundle")]
        }
        let data = try Data(contentsOf: resourcesURL)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let files = plist["files"] as? [String: Any] else {
            return [.error("\(Self.codeResourcesPath) has no files dictionary")]
        }
        var diagnostics = [Diagnostic]()
        if plist.keys.contains(where: { $0 != "files" }) || FileManager.default.fileExists(atPath: url.appendingPathComponent("_CodeSignature/CodeSignature").path) {
            diagnostics.append(.warning("the bundle carries a signature, which this packager doesn't check yet; only the file hashes are verified"))
        }
        let present = try Self.files(in: url)
        for path in files.keys.sorted() {
            guard let expected = files[path] as? Data else {
                diagnostics.append(.error("\(Self.codeResourcesPath) has no SHA-256 digest for \(path)"))
                continue
            }
            guard present.contains(path) else {
                diagnostics.append(.error("\(path) is listed in \(Self.codeResourcesPath) but missing"))
                continue
            }
            let actual = try Self.sha256(of: url.appendingPathComponent(path))
            if actual != expected {
                diagnostics.append(.error("\(path) doesn't match its hash in \(Self.codeResourcesPath): the bundle changed after guest.py built it"))
            }
        }
        for path in present.sorted() where files[path] == nil {
            diagnostics.append(.error("\(path) isn't listed in \(Self.codeResourcesPath)"))
        }
        return diagnostics
    }

    /// The bundle's files, relative to it, leaving out `_CodeSignature/`.
    static func files(in directory: URL) throws -> Set<String> {
        var files = Set<String>()
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return files
        }
        for case let file as URL in enumerator {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let path = file.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(root + "/") else {
                continue
            }
            let relative = String(path.dropFirst(root.count + 1))
            if !relative.hasPrefix("_CodeSignature/") {
                files.insert(relative)
            }
        }
        return files
    }

    /// A file's SHA-256 digest.
    static func sha256(of url: URL) throws -> Data {
        Data(SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)))
    }

    /// A file's SHA-256 digest in hex.
    static func sha256Hex(of url: URL) throws -> String {
        try sha256(of: url).map { String(format: "%02x", $0) }.joined()
    }
}

import Foundation
import RuntimeABI

/// The app's keys in the host app's `Info.plist`, which the packager copied
/// from the universal bundle (`ManifestPackager.md` §1.1, §4).
public struct AppInfo: Equatable, Sendable {

    /// A contract the app uses, from `RTContracts`.
    public struct Contract: Equatable, Hashable, Sendable {

        public var name: String

        public var version: UInt32

        public var kind: ContractKind

        public init(name: String, version: UInt32, kind: ContractKind) {
            self.name = name
            self.version = version
            self.kind = kind
        }
    }

    public var identifier: String

    public var abiVersion: UInt32

    public var targets: [String]

    public var capabilities: Set<Capability>

    public var contracts: [Contract]

    /// `RTCapabilityUsage`: each capability's usage-text key.
    public var capabilityUsage: [String: String]

    public init(
        identifier: String,
        abiVersion: UInt32,
        targets: [String] = [],
        capabilities: Set<Capability> = [],
        contracts: [Contract] = [],
        capabilityUsage: [String: String] = [:]
    ) {
        self.identifier = identifier
        self.abiVersion = abiVersion
        self.targets = targets
        self.capabilities = capabilities
        self.contracts = contracts
        self.capabilityUsage = capabilityUsage
    }

    /// Reads the keys from an `Info.plist` dictionary.
    public init(infoDictionary info: [String: Any]) throws(AppInfoError) {
        guard let abiVersion = (info["RTABIVersion"] as? NSNumber)?.uint32Value else {
            throw .missing("RTABIVersion")
        }
        var contracts = [Contract]()
        for entry in info["RTContracts"] as? [[String: Any]] ?? [] {
            guard let name = entry["Name"] as? String,
                  let version = (entry["Version"] as? NSNumber)?.uint32Value,
                  let kind = (entry["Kind"] as? String).flatMap(ContractKind.init(name:)) else {
                throw .malformed("RTContracts")
            }
            contracts.append(Contract(name: name, version: version, kind: kind))
        }
        self.init(
            identifier: info["CFBundleIdentifier"] as? String ?? "",
            abiVersion: abiVersion,
            targets: info["RTTargets"] as? [String] ?? [],
            capabilities: Set((info["RTCapabilities"] as? [String] ?? []).map(Capability.init(_:))),
            contracts: contracts,
            capabilityUsage: info["RTCapabilityUsage"] as? [String: String] ?? [:]
        )
    }

    /// The running app's keys.
    public static func main() throws(AppInfoError) -> AppInfo {
        try AppInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    public var contractNames: Set<String> {
        Set(contracts.map(\.name))
    }
}

/// A problem with the app's `Info.plist` keys.
public enum AppInfoError: Error, Equatable, CustomStringConvertible {

    case missing(String)

    case malformed(String)

    public var description: String {
        switch self {
        case .missing(let key): "Info.plist has no \(key); was the app packaged by darwin-app?"
        case .malformed(let key): "Info.plist's \(key) is malformed"
        }
    }
}

extension ContractKind {

    /// The `Kind` string in `RTContracts`.
    init?(name: String) {
        switch name {
        case "contract": self = .contract
        case "callback": self = .callback
        default: return nil
        }
    }
}

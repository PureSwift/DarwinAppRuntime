import DynamicRuntime

/// Step 2 of the pipeline: whether this host can run the bundle on a
/// platform (`ManifestPackager.md` §3).
public struct Compatibility {

    public var platform: ApplePlatform

    /// Contracts that this host doesn't implement are warnings instead of
    /// errors; the guest gets `rt_class == 0` for them. For test apps whose
    /// contracts only a test host implements, such as AppRuntime's
    /// `ExampleApp`.
    public var allowsMissingContracts: Bool

    public init(platform: ApplePlatform, allowsMissingContracts: Bool = false) {
        self.platform = platform
        self.allowsMissingContracts = allowsMissingContracts
    }

    /// Checks:
    /// - `RTABIVersion` ≤ the host's ABI version;
    /// - each contract in `RTContracts` registered on the platform, of the
    ///   same kind, with a version ≤ the host's;
    /// - every capability known, supported on the platform, and declared
    ///   by the contracts that require it; usage texts for those that
    ///   need one;
    /// - the manifest lists the platform, when it lists platforms.
    public func check(_ bundle: UniversalBundle) -> [Diagnostic] {
        var diagnostics = [Diagnostic]()
        if bundle.abiVersion > HostContracts.abiVersion {
            diagnostics.append(.error("the app needs rt ABI \(bundle.abiVersion); this host provides \(HostContracts.abiVersion)"))
        }
        diagnostics += checkContracts(bundle)
        diagnostics += checkCapabilities(bundle)
        do {
            _ = try deploymentTarget(bundle)
        } catch {
            diagnostics.append(.error(error.message))
        }
        return diagnostics
    }

    func checkContracts(_ bundle: UniversalBundle) -> [Diagnostic] {
        var diagnostics = [Diagnostic]()
        let registered = HostContracts.descriptors(for: platform)
        let declared = Set(bundle.capabilities)
        for contract in bundle.contracts {
            guard let provided = registered[contract.name] else {
                if let module = HostContracts.module(registering: contract.name) {
                    let platforms = module.platforms.map(\.rawValue).sorted().joined(separator: ", ")
                    diagnostics.append(.error("\(contract.name) isn't available on \(platform.rawValue): \(module.name) runs on \(platforms) only"))
                } else {
                    let message = "\(contract.name) has no implementation in this host"
                    diagnostics.append(allowsMissingContracts ? .warning(message + "; the app gets none at run time") : .error(message))
                }
                continue
            }
            let kind = provided.kind == .contract ? "contract" : "callback"
            if contract.kind != kind {
                diagnostics.append(.error("\(contract.name) is a \(contract.kind) in the app and a \(kind) in this host"))
            }
            if contract.version > provided.version {
                diagnostics.append(.error("\(contract.name) version \(contract.version) is newer than this host's \(provided.version)"))
            }
            if let capability = provided.capability, !declared.contains(capability.rawValue) {
                diagnostics.append(.error("\(contract.name) requires capability '\(capability.rawValue)', which the manifest doesn't declare"))
            }
        }
        return diagnostics
    }

    func checkCapabilities(_ bundle: UniversalBundle) -> [Diagnostic] {
        var diagnostics = [Diagnostic]()
        for capability in bundle.capabilities {
            guard let rule = Capabilities.rules[capability] else {
                diagnostics.append(.error("capability '\(capability)' isn't supported by this host"))
                continue
            }
            guard rule.platforms.contains(platform) else {
                diagnostics.append(.error("capability '\(capability)' isn't supported on \(platform.rawValue)"))
                continue
            }
            let options = bundle.capabilityOptions[capability] ?? [:]
            let keys = Capabilities.usageKeys(capability, options: options, platform: platform)
            if rule.needsUsage, !keys.isEmpty, bundle.capabilityUsage[capability] == nil {
                diagnostics.append(.error("capability '\(capability)' has no usage text; the system stops an app that uses it without one"))
            }
        }
        return diagnostics
    }

    /// The OS the app is built for: the host's minimum, or the manifest's
    /// when it's higher.
    public func deploymentTarget(_ bundle: UniversalBundle) throws(PackagerError) -> String {
        let host = OSVersion(platform.hostMinimum)!
        guard let platforms = bundle.platforms else {
            return host.description
        }
        guard let entry = platforms[platform.manifestName] else {
            let listed = platforms.keys.sorted().joined(separator: ", ")
            throw PackagerError("the manifest doesn't list \(platform.manifestName) in its platforms (\(listed))")
        }
        guard let text = entry.minimum else {
            return host.description
        }
        guard let minimum = OSVersion(text) else {
            throw PackagerError("the manifest's \(platform.manifestName) minimum '\(text)' isn't a version")
        }
        return max(host, minimum).description
    }
}

import Foundation

/// Entitlements and code signing (step 7, `ManifestPackager.md` §4.1).
public enum Entitlements {

    /// The entitlements the capabilities need, before the provisioning
    /// profile's.
    ///
    /// - Parameter usesNDEF: whether the app uses the NDEF contracts, which
    ///   adds `NDEF` to the NFC reader formats.
    public static func forCapabilities(
        _ bundle: UniversalBundle,
        platform: ApplePlatform,
        configuration: BuildConfiguration
    ) -> [String: Any] {
        var entitlements = [String: Any]()
        let usesNDEF = bundle.contracts.contains { $0.name.hasPrefix("org.pureswift.nfc.NDEF") }
        if platform.isMac {
            // Always sandboxed, as the Mac App Store requires.
            entitlements[Capabilities.appSandbox] = true
            if configuration == .debug {
                // Lets a debugger attach under the hardened runtime.
                entitlements["com.apple.security.get-task-allow"] = true
            }
        }
        for capability in bundle.capabilities {
            let options = bundle.capabilityOptions[capability] ?? [:]
            if platform.isMac {
                for key in Capabilities.rules[capability]?.sandboxEntitlements ?? [] {
                    entitlements[key] = true
                }
            }
            switch capability {
            case "nfc" where !platform.isMac:
                entitlements["com.apple.developer.nfc.readersession.formats"] = usesNDEF ? ["TAG", "NDEF"] : ["TAG"]
            case "notifications" where Capabilities.usesRemoteNotifications(options):
                let environment = configuration == .release ? "production" : "development"
                entitlements[platform.isMac ? "com.apple.developer.aps-environment" : "aps-environment"] = environment
            default:
                break
            }
        }
        return entitlements
    }

    /// Entitlements only a provisioning profile can grant. An ad hoc
    /// signed macOS app with one of them doesn't launch.
    public static func isRestricted(_ key: String) -> Bool {
        key.hasPrefix("com.apple.developer.") || key == "aps-environment"
    }
}

/// A decoded provisioning profile.
public struct ProvisioningProfile {

    public var url: URL

    public var teamIdentifier: String

    /// `application-identifier`, such as `ABCDE12345.org.example.*`.
    public var applicationIdentifier: String

    /// The entitlements the profile allows.
    public var entitlements: [String: Any]

    /// Decodes a profile's CMS envelope with `security cms -D`.
    public static func read(_ url: URL, runner: any CommandRunner) throws -> ProvisioningProfile {
        let output = try runner.check(Command("security", ["cms", "-D", "-i", url.path])).standardOutput
        return try parse(Data(output.utf8), url: url)
    }

    public static func parse(_ data: Data, url: URL) throws -> ProvisioningProfile {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw PackagerError("\(url.path) isn't a provisioning profile")
        }
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        guard let team = (plist["TeamIdentifier"] as? [String])?.first,
              let identifier = entitlements["application-identifier"] as? String
                ?? entitlements["com.apple.application-identifier"] as? String else {
            throw PackagerError("\(url.path) has no team or application identifier")
        }
        return ProvisioningProfile(url: url, teamIdentifier: team, applicationIdentifier: identifier, entitlements: entitlements)
    }

    /// Whether the profile's application identifier covers a bundle
    /// identifier, wildcards included.
    public func allows(bundleIdentifier: String) -> Bool {
        let expected = "\(teamIdentifier).\(bundleIdentifier)"
        if applicationIdentifier.hasSuffix("*") {
            return expected.hasPrefix(String(applicationIdentifier.dropLast()))
        }
        return applicationIdentifier == expected
    }

    /// The app's entitlements, with the profile's identifiers: the
    /// capabilities' entitlements, `application-identifier`, the team, and
    /// `get-task-allow` as the profile has it.
    public func entitlements(adding capabilities: [String: Any], bundleIdentifier: String, platform: ApplePlatform) throws -> (entitlements: [String: Any], diagnostics: [Diagnostic]) {
        guard allows(bundleIdentifier: bundleIdentifier) else {
            throw PackagerError("the profile \(url.lastPathComponent) is for \(applicationIdentifier), not \(teamIdentifier).\(bundleIdentifier)")
        }
        var entitlements = capabilities
        var diagnostics = [Diagnostic]()
        let identifierKey = platform.isMac ? "com.apple.application-identifier" : "application-identifier"
        entitlements[identifierKey] = "\(teamIdentifier).\(bundleIdentifier)"
        entitlements["com.apple.developer.team-identifier"] = teamIdentifier
        if !platform.isMac, let allowed = self.entitlements["get-task-allow"] as? Bool {
            entitlements["get-task-allow"] = allowed
        }
        for key in capabilities.keys.sorted() where Entitlements.isRestricted(key) && self.entitlements[key] == nil {
            diagnostics.append(.warning("the profile doesn't grant \(key); the app may not install or launch"))
        }
        return (entitlements, diagnostics)
    }
}

/// `codesign` commands.
public enum CodeSign {

    /// The ad hoc identity.
    public static let adHoc = "-"

    /// Signs the app.
    ///
    /// macOS builds use the hardened runtime that notarization needs, and
    /// a secure timestamp when signed with a real identity.
    public static func sign(app: URL, identity: String, entitlements: URL, platform: ApplePlatform) -> Command {
        var arguments = ["codesign", "--force", "--sign", identity, "--entitlements", entitlements.path]
        if platform.isMac {
            arguments += ["--options", "runtime"]
            arguments.append(identity == adHoc ? "--timestamp=none" : "--timestamp")
        }
        arguments.append(app.path)
        return .xcrun(arguments)
    }

    /// Checks the signature.
    public static func verify(app: URL) -> Command {
        .xcrun("codesign", "--verify", "--deep", "--strict", "--verbose=2", app.path)
    }
}

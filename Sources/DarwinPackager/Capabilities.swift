/// How each portable capability becomes Apple keys and entitlements
/// (`ManifestPackager.md` §4.1).
public struct CapabilityRule: Sendable {

    /// The capability's name, such as `bluetooth`.
    public var name: String

    /// Where the host supports it.
    public var platforms: Set<ApplePlatform>

    /// Whether the app has to explain it: the manifest must give a usage
    /// text.
    public var needsUsage: Bool

    /// `UIRequiredDeviceCapabilities` when the capability is required.
    public var requiredDeviceCapability: String?

    /// The macOS App Sandbox entitlements it needs.
    public var sandboxEntitlements: [String]

    public init(
        name: String,
        platforms: Set<ApplePlatform> = Set(ApplePlatform.allCases),
        needsUsage: Bool = false,
        requiredDeviceCapability: String? = nil,
        sandboxEntitlements: [String] = []
    ) {
        self.name = name
        self.platforms = platforms
        self.needsUsage = needsUsage
        self.requiredDeviceCapability = requiredDeviceCapability
        self.sandboxEntitlements = sandboxEntitlements
    }
}

public enum Capabilities {

    /// The App Sandbox, which every macOS app gets.
    public static let appSandbox = "com.apple.security.app-sandbox"

    static let iOS: Set<ApplePlatform> = [.ios, .iosSimulator]

    /// Every capability this host supports.
    public static let rules: [String: CapabilityRule] = {
        let rules = [
            CapabilityRule(
                name: "bluetooth", needsUsage: true, requiredDeviceCapability: "bluetooth-le",
                sandboxEntitlements: ["com.apple.security.device.bluetooth"]
            ),
            CapabilityRule(
                name: "location", needsUsage: true, requiredDeviceCapability: "location-services",
                sandboxEntitlements: ["com.apple.security.personal-information.location"]
            ),
            CapabilityRule(name: "motion", needsUsage: true),
            CapabilityRule(name: "nfc", platforms: iOS, needsUsage: true, requiredDeviceCapability: "nfc"),
            CapabilityRule(name: "network", sandboxEntitlements: ["com.apple.security.network.client"]),
            CapabilityRule(name: "localNetwork", needsUsage: true),
            CapabilityRule(
                name: "camera", needsUsage: true, requiredDeviceCapability: "still-camera",
                sandboxEntitlements: ["com.apple.security.device.camera"]
            ),
            CapabilityRule(name: "notifications"),
            // Sound and pictures through the media players (`DarwinMedia`).
            // It prompts for nothing; `background` plays on when the app
            // leaves the front.
            CapabilityRule(name: "audio"),
            // Work the system runs in the background (`DarwinBackgroundTasks`).
            // It prompts for nothing.
            CapabilityRule(name: "backgroundTasks"),
            // Secrets in the Keychain (`DarwinSecrets`). It prompts for
            // nothing, and the app's own items need no entitlement.
            CapabilityRule(name: "secrets"),
            // The user's address book (`DarwinContacts`). `.readOnly` changes
            // nothing here: the host refuses the writes.
            CapabilityRule(
                name: "contacts", needsUsage: true,
                sandboxEntitlements: ["com.apple.security.personal-information.addressbook"]
            ),
            // The user's own files, through the pickers (`DarwinDocuments`).
            // It prompts for nothing; the sandbox needs to let the app at
            // what the user picks, and keep bookmarks to it.
            CapabilityRule(
                name: "userFiles",
                sandboxEntitlements: [
                    "com.apple.security.files.user-selected.read-write",
                    "com.apple.security.files.bookmarks.app-scope",
                ]
            ),
            // OpenGL ES 2.0: OpenGLES.framework on iOS, desktop OpenGL on
            // macOS (`DarwinGraphics`).
            CapabilityRule(name: "graphics", requiredDeviceCapability: "opengles-2"),
        ]
        return Dictionary(uniqueKeysWithValues: rules.map { ($0.name, $0) })
    }()

    /// The `Info.plist` keys that hold a capability's usage text on a
    /// platform. `options` are its `RTCapabilityOptions`.
    public static func usageKeys(_ capability: String, options: [String: String], platform: ApplePlatform) -> [String] {
        switch (capability, platform.isMac) {
        case ("bluetooth", _):
            return ["NSBluetoothAlwaysUsageDescription"]
        case ("location", false):
            if options["access"] == "always" {
                return ["NSLocationWhenInUseUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription"]
            }
            return ["NSLocationWhenInUseUsageDescription"]
        case ("location", true):
            // §4.1 names NSLocationUsageDescription; macOS 11 and later also
            // read the when-in-use key, so both are written.
            return ["NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription"]
        case ("motion", false):
            return ["NSMotionUsageDescription"]
        case ("nfc", false):
            return ["NFCReaderUsageDescription"]
        case ("localNetwork", false):
            return ["NSLocalNetworkUsageDescription"]
        case ("camera", _):
            return ["NSCameraUsageDescription"]
        case ("contacts", _):
            return ["NSContactsUsageDescription"]
        default:
            return []
        }
    }

    /// The graphics APIs this host gives a guest (`RTCapabilityOptions.graphics.api`).
    public static let graphicsAPIs: Set<String> = ["gles2"]

    /// Whether the manifest marks the capability required
    /// (`RTCapabilityOptions.<capability>.required`). Capabilities are
    /// optional by default.
    public static func isRequired(_ options: [String: String]) -> Bool {
        options["required"] == "true"
    }

    /// `UIBackgroundModes` on iOS:
    ///
    /// - `audio` for `.audio(background: true)`
    ///   (`RTCapabilityOptions.audio.background`);
    /// - `fetch` for a refresh task and `processing` for a processing task
    ///   (`RTBackgroundTasks`);
    /// - `remote-notification` for `.notifications(remote: true, wakesApp: true)`.
    ///
    /// A Mac app isn't suspended, so it needs none.
    public static func backgroundModes(_ capabilities: [String], options: [String: [String: String]],
                                       tasks: [BackgroundTaskEntry] = [], platform: ApplePlatform) -> [String] {
        guard !platform.isMac else { return [] }
        var modes = [String]()
        if capabilities.contains("audio"), options["audio"]?["background"] == "true" {
            modes.append("audio")
        }
        if capabilities.contains("backgroundTasks") {
            if tasks.contains(where: { $0.kind == "refresh" }) {
                modes.append("fetch")
            }
            if tasks.contains(where: { $0.kind == "processing" }) {
                modes.append("processing")
            }
        }
        if capabilities.contains("notifications"), options["notifications"]?["wakesApp"] == "true" {
            modes.append("remote-notification")
        }
        return modes
    }

    /// `BGTaskSchedulerPermittedIdentifiers` on iOS: every task the manifest
    /// names. iOS runs no other.
    public static func permittedTasks(_ capabilities: [String], tasks: [BackgroundTaskEntry], platform: ApplePlatform) -> [String] {
        guard !platform.isMac, capabilities.contains("backgroundTasks") else { return [] }
        return tasks.map(\.identifier)
    }

    /// Whether notifications include remote (push) ones, which need
    /// `aps-environment` (`RTCapabilityOptions.notifications.remote`).
    public static func usesRemoteNotifications(_ options: [String: String]) -> Bool {
        options["remote"] == "true"
    }
}

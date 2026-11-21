import Foundation

/// The app's `Info.plist` and `InfoPlist.strings` from the bundle's
/// portable keys (`ManifestPackager.md` §4, §4.1, §4.2).
public struct InfoPlistTranslator {

    public var bundle: UniversalBundle

    public var platform: ApplePlatform

    public var deploymentTarget: String

    public init(bundle: UniversalBundle, platform: ApplePlatform, deploymentTarget: String) {
        self.bundle = bundle
        self.platform = platform
        self.deploymentTarget = deploymentTarget
    }

    /// Keys `apple.extraInfoPlist` may replace: defaults an app commonly
    /// changes.
    public static let overridableKeys: Set<String> = [
        "UISupportedInterfaceOrientations",
        "UISupportedInterfaceOrientations~ipad",
        "UILaunchScreen",
        "UIApplicationSceneManifest",
    ]

    /// Every capability's usage text in the development language, by
    /// `Info.plist` key.
    public func usageDescriptions() throws -> [String: String] {
        let development = try bundle.manifestStrings(bundle.developmentRegion) ?? [:]
        return try localizedKeys(development, language: bundle.developmentRegion, includeName: false)
    }

    /// The `Info.plist` keys of one language's `InfoPlist.strings`: the
    /// display name (when it's localized) and each usage text, translated
    /// through `RTDisplayNameKey` and `RTCapabilityUsage`.
    func localizedKeys(_ strings: [String: String], language: String, includeName: Bool) throws -> [String: String] {
        var keys = [String: String]()
        func value(_ key: String, for what: String) throws -> String {
            guard let value = strings[key] else {
                throw PackagerError("resources/\(language).lproj/Manifest.strings has no '\(key)', the \(what)")
            }
            return value
        }
        if includeName, let nameKey = bundle.displayNameKey {
            let name = try value(nameKey, for: "app's name")
            keys["CFBundleDisplayName"] = name
            keys["CFBundleName"] = name
        }
        for capability in bundle.capabilities.sorted() {
            guard let usageKey = bundle.capabilityUsage[capability] else {
                continue
            }
            let options = bundle.capabilityOptions[capability] ?? [:]
            let infoKeys = Capabilities.usageKeys(capability, options: options, platform: platform)
            guard !infoKeys.isEmpty else {
                continue
            }
            let text = try value(usageKey, for: "usage text of '\(capability)'")
            for infoKey in infoKeys {
                keys[infoKey] = text
            }
        }
        return keys
    }

    /// Each language's `InfoPlist.strings`, by language. Empty when there's
    /// nothing localized.
    public func infoPlistStrings() throws -> [String: [String: String]] {
        var files = [String: [String: String]]()
        for language in bundle.languages {
            let strings = try bundle.manifestStrings(language)
            let localizedTypes = bundle.documentTypes.contains { $0.nameKey != nil }
            if strings == nil, bundle.displayNameKey == nil, bundle.capabilityUsage.isEmpty, !localizedTypes {
                continue
            }
            var keys = try localizedKeys(strings ?? [:], language: language, includeName: true)
            // A document type's name is looked up by the development
            // language's name, which `CFBundleTypeName` holds.
            for type in bundle.documentTypes {
                guard let key = type.nameKey else { continue }
                guard let name = strings?[key] else {
                    throw PackagerError("resources/\(language).lproj/Manifest.strings has no '\(key)', the name of the document type '\(type.name)'")
                }
                keys[type.name] = name
            }
            if !keys.isEmpty {
                files[language] = keys
            }
        }
        return files
    }

    /// The generated keys, before the icon's and `apple.extraInfoPlist`.
    public func generatedKeys(sdk: SDKInfo?) throws -> [String: Any] {
        var info = [String: Any]()
        // The portable keys, and every RT key for the host's start-up checks.
        for (key, value) in bundle.info where key.hasPrefix("RT") {
            info[key] = value
        }
        info["CFBundleIdentifier"] = bundle.identifier
        info["CFBundleName"] = bundle.name
        info["CFBundleDisplayName"] = bundle.displayName
        info["CFBundleShortVersionString"] = bundle.version
        info["CFBundleVersion"] = bundle.build
        info["CFBundleLocalizations"] = bundle.languages
        info["CFBundleDevelopmentRegion"] = bundle.developmentRegion
        info["CFBundleExecutable"] = bundle.executable
        info["CFBundleInfoDictionaryVersion"] = "6.0"
        info["CFBundlePackageType"] = "APPL"
        info[platform.minimumOSKey] = deploymentTarget
        if let sdk {
            info.merge(sdk.infoPlistKeys(platform: platform)) { $1 }
        }
        if platform.isMac {
            info["NSPrincipalClass"] = "NSApplication"
            info["NSHighResolutionCapable"] = true
            if let category = bundle.apple.category {
                info["LSApplicationCategoryType"] = category
            }
        } else {
            info["LSRequiresIPhoneOS"] = true
            info["UIDeviceFamily"] = [1, 2]
            info["UIApplicationSceneManifest"] = ["UIApplicationSupportsMultipleScenes": false]
            info["UILaunchScreen"] = [String: Any]()
            info["UISupportedInterfaceOrientations"] = [
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight",
            ]
            info["UISupportedInterfaceOrientations~ipad"] = [
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationPortraitUpsideDown",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight",
            ]
            if let category = bundle.apple.category {
                info["LSApplicationCategoryType"] = category
            }
            let required = bundle.capabilities.sorted().compactMap { capability -> String? in
                guard Capabilities.isRequired(bundle.capabilityOptions[capability] ?? [:]) else {
                    return nil
                }
                return Capabilities.rules[capability]?.requiredDeviceCapability
            }
            if !required.isEmpty {
                info["UIRequiredDeviceCapabilities"] = required
            }
            let modes = Capabilities.backgroundModes(bundle.capabilities.sorted(), options: bundle.capabilityOptions, platform: platform)
            if !modes.isEmpty {
                info["UIBackgroundModes"] = modes
            }
        }
        info.merge(try usageDescriptions()) { $1 }
        info.merge(DocumentTypes.infoPlistKeys(bundle.documentTypes, bundleIdentifier: bundle.identifier, platform: platform)) { $1 }
        return info
    }

    /// The whole `Info.plist`: the generated keys, the icon's from
    /// `actool`, then `apple.extraInfoPlist`.
    ///
    /// An extra key that replaces a generated one is an error, except the
    /// defaults in `overridableKeys`. Extra `UIBackgroundModes` are added
    /// to the generated ones.
    public func infoPlist(sdk: SDKInfo?, iconKeys: [String: Any] = [:]) throws -> [String: Any] {
        var info = try generatedKeys(sdk: sdk)
        info.merge(iconKeys) { $1 }
        var extras = bundle.apple.extraInfoPlist
        if let generated = info["UIBackgroundModes"] as? [String], let extra = extras["UIBackgroundModes"] as? [String] {
            extras["UIBackgroundModes"] = generated + extra.filter { !generated.contains($0) }
        }
        let conflicts = extras.keys
            .filter { info[$0] != nil && !Self.overridableKeys.contains($0) && $0 != "UIBackgroundModes" }
            .sorted()
        if !conflicts.isEmpty {
            throw PackagerError("apple.extraInfoPlist sets keys the packager generates: \(conflicts.joined(separator: ", "))")
        }
        info.merge(extras) { $1 }
        return info
    }
}

extension Dictionary where Key == String, Value == Any {

    /// The dictionary as an XML property list.
    func propertyListData() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: self, format: .xml, options: 0)
    }
}

import Foundation

/// `PrivacyInfo.xcprivacy` (`ManifestPackager.md` §6): the host runtime's
/// required-reason API declarations, merged with the app's data collection
/// and tracking.
public enum PrivacyManifest {

    /// The host runtime's declarations: `mach_absolute_time` for
    /// `Clock.now` (`35F9.1`, time between events in the app).
    public static var hostAccessedAPITypes: [[String: Any]] { [
        [
            "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategorySystemBootTime",
            "NSPrivacyAccessedAPITypeReasons": ["35F9.1"],
        ],
    ] }

    /// The manifest for an app with `apple.privacy` set to `privacy`: its
    /// `NSPrivacyTracking`, `NSPrivacyTrackingDomains`,
    /// `NSPrivacyCollectedDataTypes` and `NSPrivacyAccessedAPITypes`, as in
    /// the privacy manifest's own format.
    public static func manifest(privacy: [String: Any] = [:]) -> [String: Any] {
        var accessed = hostAccessedAPITypes
        for entry in privacy["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? [] {
            let type = entry["NSPrivacyAccessedAPIType"] as? String
            let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
            if let index = accessed.firstIndex(where: { $0["NSPrivacyAccessedAPIType"] as? String == type }) {
                let existing = accessed[index]["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
                accessed[index]["NSPrivacyAccessedAPITypeReasons"] = existing + reasons.filter { !existing.contains($0) }
            } else {
                accessed.append(entry)
            }
        }
        return [
            "NSPrivacyTracking": privacy["NSPrivacyTracking"] as? Bool ?? false,
            "NSPrivacyTrackingDomains": privacy["NSPrivacyTrackingDomains"] as? [String] ?? [],
            "NSPrivacyCollectedDataTypes": privacy["NSPrivacyCollectedDataTypes"] as? [Any] ?? [],
            "NSPrivacyAccessedAPITypes": accessed,
        ]
    }

    public static let fileName = "PrivacyInfo.xcprivacy"
}

import DynamicRuntime
import Foundation

/// The built-in `Bundle` contract (`AppBundle` in Swift) over a Foundation
/// `Bundle`, normally `Bundle.main`.
///
/// The packager copies the universal bundle's `resources/` into the app, so
/// the app's `.lproj` tables are the bundle's own.
public final class DarwinBundle: AppBundle {

    /// The bundle every call reads. Set before the guest starts.
    nonisolated(unsafe) public static var bundle = Foundation.Bundle.main

    public static func identifier() -> String {
        bundle.bundleIdentifier ?? ""
    }

    public static func version() -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    public static func build() -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    public static func preferredLanguages() -> [String] {
        Locale.preferredLanguages
    }

    public static func localizedString(_ key: String, table: String?) -> String? {
        // A sentinel default tells a missing key from a key whose value is
        // the key itself.
        let missing = "\u{0}RTMissing\u{0}"
        let value = bundle.localizedString(forKey: key, value: missing, table: table)
        return value == missing ? nil : value
    }
}

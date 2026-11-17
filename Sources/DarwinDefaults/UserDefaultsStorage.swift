import Foundation
import RuntimeHost

/// The app's settings in a `UserDefaults` suite of their own
/// (`Contracts/Defaults.md`), apart from the host's own settings.
///
/// Reads look only at the suite's own values. A `UserDefaults` lookup also
/// searches the global domain and the command line's arguments, which
/// would show the app values it never set.
///
/// A string is kept as a string and bytes as `Data`, so `defaults read`
/// shows them as they are. A value of another kind, written by something
/// other than the app, reads as missing.
final class UserDefaultsStorage: DefaultsStorage {

    /// The suite: `<bundle identifier>.defaults`.
    let suite: String

    let defaults: UserDefaults

    /// The most bytes one value may have. More is refused.
    let maximumValueSize: Int

    /// `nil` when the suite can't be opened.
    init?(suite: String, maximumValueSize: Int = 64 << 10) {
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        self.suite = suite
        self.defaults = defaults
        self.maximumValueSize = maximumValueSize
    }

    /// The suite for an app's bundle. A suite can't be named for the app
    /// itself: that's its standard defaults, which the host uses.
    static func suite(for bundle: Bundle) -> String {
        (bundle.bundleIdentifier ?? ProcessInfo.processInfo.processName) + ".defaults"
    }

    private var values: [String: Any] {
        defaults.persistentDomain(forName: suite) ?? [:]
    }

    func string(_ key: String) -> String? {
        values[key] as? String
    }

    func data(_ key: String) -> [UInt8]? {
        (values[key] as? Data).map { Array($0) }
    }

    func setString(_ value: String, key: String) -> Bool {
        guard value.utf8.count <= maximumValueSize else { return false }
        defaults.set(value, forKey: key)
        return true
    }

    func setData(_ value: [UInt8], key: String) -> Bool {
        guard value.count <= maximumValueSize else { return false }
        defaults.set(Data(value), forKey: key)
        return true
    }

    func remove(_ key: String) {
        defaults.removeObject(forKey: key)
    }

    func keys() -> [String] {
        Array(values.keys)
    }
}

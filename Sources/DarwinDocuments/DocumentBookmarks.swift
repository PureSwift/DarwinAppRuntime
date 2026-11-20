import Foundation

/// The documents the app asked to remember: each one's bookmark data, kept
/// in the host's own defaults under a string the guest holds
/// (AppRuntime's `Documents.md`, "Keeping access").
///
/// The host's standard defaults, not the guest's `Defaults` suite, which
/// the app can read and clear. The string is a UUID, which means nothing
/// to another app.
final class DocumentBookmarks {

    let defaults: UserDefaults

    let key: String

    init(defaults: UserDefaults = .standard, key: String = "RTDocumentBookmarks") {
        self.defaults = defaults
        self.key = key
    }

    struct Entry: Equatable {

        var data: Data

        /// Whether the document could be written when it was remembered.
        var isWritable: Bool
    }

    private var all: [String: [String: Any]] {
        get { defaults.dictionary(forKey: key) as? [String: [String: Any]] ?? [:] }
        set { defaults.set(newValue, forKey: key) }
    }

    /// Keeps `entry`, and answers with the string that names it.
    func add(_ entry: Entry) -> String {
        let name = UUID().uuidString
        self[name] = entry
        return name
    }

    subscript(name: String) -> Entry? {
        get {
            guard let stored = all[name], let data = stored["data"] as? Data else {
                return nil
            }
            return Entry(data: data, isWritable: stored["writable"] as? Bool ?? false)
        }
        set {
            var all = all
            all[name] = newValue.map { ["data": $0.data, "writable": $0.isWritable] }
            self.all = all
        }
    }

    var names: [String] {
        all.keys.sorted()
    }
}

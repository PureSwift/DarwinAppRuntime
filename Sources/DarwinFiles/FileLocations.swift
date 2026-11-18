import DynamicFiles
import Foundation

/// Where each `FileDirectory` is on this device (`Contracts/Files.md`).
///
/// In a sandbox, which is every iOS app and every packaged macOS app, the
/// home directory is the app's own container, and the directories are the
/// container's:
///
/// | `FileDirectory` | Path |
/// |---|---|
/// | `documents` | `Documents` |
/// | `data` | `Library/Application Support` |
/// | `caches` | `Library/Caches` |
/// | `temporary` | the container's `tmp` |
/// | `bundle` | the app's resources |
///
/// A macOS process without a sandbox, such as a development run, shares the
/// user's home and temporary directory with every other app. There each
/// directory is one of the app's own, named by its bundle identifier, so it
/// doesn't write to the user's Documents or empty other apps' temporary
/// files.
///
/// The model store's stores (`stores`) are beside these directories, not in
/// one, so the app's own files never meet them.
public struct FileLocations: Equatable {

    /// The home directory: the container in a sandbox.
    var home: String

    /// `NSTemporaryDirectory()`.
    var temporary: String

    /// The app's resources, if it has any.
    var resources: String?

    var sandboxed: Bool

    /// Names the app's own directories outside a sandbox.
    var identifier: String

    /// This process's.
    public static func current(bundle: Bundle) -> FileLocations {
        #if os(macOS)
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        #else
        let sandboxed = true
        #endif
        return FileLocations(
            home: NSHomeDirectory(),
            temporary: NSTemporaryDirectory(),
            resources: bundle.resourceURL?.path,
            sandboxed: sandboxed,
            identifier: bundle.bundleIdentifier ?? ProcessInfo.processInfo.processName
        )
    }

    /// An absolute path for each directory, without a trailing `/`.
    var directories: [FileDirectory: String] {
        let home = Self.trimmed(home)
        let temporary = Self.trimmed(temporary)
        var directories: [FileDirectory: String]
        if sandboxed {
            directories = [
                .documents: home + "/Documents",
                .data: home + "/Library/Application Support",
                .caches: home + "/Library/Caches",
                .temporary: temporary,
            ]
        } else {
            let support = home + "/Library/Application Support/" + identifier
            directories = [
                .documents: support + "/Documents",
                .data: support + "/Data",
                .caches: home + "/Library/Caches/" + identifier,
                .temporary: temporary + "/" + identifier,
            ]
        }
        if let resources {
            directories[.bundle] = Self.trimmed(resources)
        }
        return directories
    }

    /// Where the model store keeps its stores: `Library/Stores` in a
    /// sandbox, which is backed up and isn't a `FileDirectory`, and the
    /// app's own `Stores` beside its `Documents` and `Data` outside one.
    public var stores: String {
        let home = Self.trimmed(home)
        if sandboxed {
            return home + "/Library/Stores"
        }
        return home + "/Library/Application Support/" + identifier + "/Stores"
    }

    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

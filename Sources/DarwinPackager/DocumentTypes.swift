import Foundation
import UniformTypeIdentifiers

/// One of the kinds of file the app opens: an entry of the bundle's
/// `RTDocumentTypes` (AppRuntime's `Documents.md`, "The manifest").
public struct DocumentTypeEntry: Equatable, Sendable {

    /// What people call it, in the development language.
    public var name: String

    /// Its `Manifest.strings` key, when the name is localized.
    public var nameKey: String?

    /// MIME types (`image/png`), MIME groups (`image/*`) and extensions
    /// (`.gpx`).
    public var types: [String]

    /// `viewer` or `editor`.
    public var role: String

    public init(name: String, nameKey: String? = nil, types: [String], role: String) {
        self.name = name
        self.nameKey = nameKey
        self.types = types
        self.role = role
    }

    /// The entries of `RTDocumentTypes`; ones without a name or types are
    /// left out.
    static func entries(_ value: Any?) -> [DocumentTypeEntry] {
        (value as? [[String: Any]] ?? []).compactMap { entry in
            guard let name = entry["Name"] as? String, let types = entry["Types"] as? [String], !types.isEmpty else {
                return nil
            }
            return DocumentTypeEntry(
                name: name,
                nameKey: entry["NameKey"] as? String,
                types: types,
                role: entry["Role"] as? String ?? "viewer"
            )
        }
    }
}

/// How the app's document types become Apple's keys, so the system offers
/// the app for those files.
public enum DocumentTypes {

    /// `CFBundleDocumentTypes`; on iOS `LSSupportsOpeningDocumentsInPlace`,
    /// so a file is opened where it is rather than copied into the app; and
    /// `UTImportedTypeDeclarations` for each type the system doesn't know.
    public static func infoPlistKeys(_ entries: [DocumentTypeEntry], bundleIdentifier: String, platform: ApplePlatform) -> [String: Any] {
        guard !entries.isEmpty else {
            return [:]
        }
        var documentTypes = [[String: Any]]()
        var imported = [String: [String: Any]]()
        for entry in entries {
            var identifiers = [String]()
            for wire in entry.types {
                let type = contentType(wire, bundleIdentifier: bundleIdentifier, name: entry.name)
                if !identifiers.contains(type.identifier) {
                    identifiers.append(type.identifier)
                }
                if let declaration = type.declaration {
                    imported[type.identifier] = declaration
                }
            }
            documentTypes.append([
                "CFBundleTypeName": entry.name,
                "CFBundleTypeRole": entry.role == "editor" ? "Editor" : "Viewer",
                // Offered for these files, without claiming them from the
                // app that made them.
                "LSHandlerRank": "Alternate",
                "LSItemContentTypes": identifiers,
            ])
        }
        var keys: [String: Any] = ["CFBundleDocumentTypes": documentTypes]
        if !platform.isMac {
            keys["LSSupportsOpeningDocumentsInPlace"] = true
        }
        if !imported.isEmpty {
            keys["UTImportedTypeDeclarations"] = imported.keys.sorted().map { imported[$0]! }
        }
        return keys
    }

    /// The type identifier for one of the wire's types, and the declaration
    /// to import when the system has no type for it.
    static func contentType(_ wire: String, bundleIdentifier: String, name: String) -> (identifier: String, declaration: [String: Any]?) {
        if wire.hasPrefix(".") {
            let tag = String(wire.dropFirst()).lowercased()
            if let type = UTType(filenameExtension: tag), !type.isDynamic {
                return (type.identifier, nil)
            }
            let identifier = bundleIdentifier + ".type." + sanitized(tag)
            return (identifier, declaration(identifier, name: name, tags: ["public.filename-extension": [tag]]))
        }
        let mimeType = wire.lowercased()
        let parts = mimeType.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, parts[1] == "*" {
            return (groups[String(parts[0])] ?? UTType.data.identifier, nil)
        }
        if let type = UTType(mimeType: mimeType), !type.isDynamic {
            return (type.identifier, nil)
        }
        let identifier = bundleIdentifier + ".type." + sanitized(mimeType)
        return (identifier, declaration(identifier, name: name, tags: ["public.mime-type": [mimeType]]))
    }

    static func declaration(_ identifier: String, name: String, tags: [String: [String]]) -> [String: Any] {
        [
            "UTTypeIdentifier": identifier,
            "UTTypeDescription": name,
            "UTTypeConformsTo": [UTType.data.identifier],
            "UTTypeTagSpecification": tags,
        ]
    }

    /// MIME groups, by their top-level type.
    static let groups: [String: String] = [
        "image": UTType.image.identifier,
        "audio": UTType.audio.identifier,
        "video": UTType.movie.identifier,
        "text": UTType.text.identifier,
        "font": UTType.font.identifier,
        "application": UTType.data.identifier,
    ]

    /// A tag as part of a type identifier: letters, digits, `-` and `.`.
    static func sanitized(_ tag: String) -> String {
        String(tag.unicodeScalars.map { scalar -> Character in
            let isAllowed = (scalar.value < 128 && CharacterSet.alphanumerics.contains(scalar)) || scalar == "-" || scalar == "."
            return isAllowed ? Character(scalar) : "-"
        })
    }
}

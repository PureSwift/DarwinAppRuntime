import UniformTypeIdentifiers

/// The pickers' types for the contract's (AppRuntime's `Documents.md`,
/// "Content types on the wire"): MIME types (`image/png`), MIME groups
/// (`image/*`) and extensions (`.gpx`).
///
/// A type the system doesn't know becomes a dynamic `UTType` for its MIME
/// type or extension, which a picker matches by that tag. One that can't
/// be read at all widens the picker to any file: a host shows more than
/// was asked for, never less.
enum ContentTypes {

    /// The types to offer. None means any file.
    static func types(_ wire: [String]) -> [UTType] {
        var types = [UTType]()
        for value in wire {
            guard let type = type(value) else {
                return [.item]
            }
            if !types.contains(type) {
                types.append(type)
            }
        }
        return types.isEmpty ? [.item] : types
    }

    /// One wire type's `UTType`; `nil` for one that isn't any of the three
    /// forms.
    static func type(_ value: String) -> UTType? {
        if value.hasPrefix(".") {
            let tag = String(value.dropFirst())
            return tag.isEmpty ? nil : UTType(filenameExtension: tag)
        }
        let mimeType = value.lowercased()
        let parts = mimeType.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return nil
        }
        if parts[1] == "*" {
            return groups[String(parts[0])] ?? .item
        }
        return UTType(mimeType: mimeType)
    }

    /// MIME groups, by their top-level type.
    static let groups: [String: UTType] = [
        "image": .image,
        "audio": .audio,
        "video": .movie,
        "text": .text,
        "font": .font,
        "application": .data,
    ]

    /// The MIME type a file's extension says, where the system knows one.
    static func mimeType(ofFileAt path: String) -> String? {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return nil
        }
        return UTType(filenameExtension: String(name[name.index(after: dot)...]))?.preferredMIMEType
    }
}

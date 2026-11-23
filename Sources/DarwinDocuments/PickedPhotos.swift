import DynamicFiles
import Foundation
import RuntimeDocuments
import UniformTypeIdentifiers

/// What the photo picker gives, as documents (AppRuntime's
/// `Documentation/Contracts/Documents.md`, the photo picker).
///
/// The picker lends each photo or video as a file that's gone once its
/// callback returns, so the host copies it to a folder of its own. The copy
/// is read-only to the guest, and removed when the guest lets go of it.
enum PickedPhotos {

    /// Which of a picked item's representations to copy: the first that is
    /// an image or a movie, as the app asked. An item's own representation
    /// comes first, so a HEIC photo stays HEIC.
    static func representation(of identifiers: [String], images: Bool, videos: Bool) -> UTType? {
        let both = !images && !videos
        for identifier in identifiers {
            guard let type = UTType(identifier) else { continue }
            if (images || both), type.conforms(to: .image) { return type }
            if (videos || both), type.conforms(to: .movie) { return type }
        }
        return nil
    }

    /// The name the copy has: the item's own name where it has one, with
    /// its type's extension.
    static func fileName(_ suggested: String?, type: UTType) -> String {
        var name = (suggested ?? "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.hasPrefix(".") {
            name = type.conforms(to: .movie) ? "Video" : "Photo"
        }
        if let ext = type.preferredFilenameExtension,
           URL(fileURLWithPath: name).pathExtension.lowercased() != ext.lowercased() {
            name += "." + ext
        }
        return name
    }

    /// Copies `file`, which the picker lent, to a folder of the host's own
    /// in `parent`, and answers with its document. Letting go of the
    /// document removes the copy.
    static func keep(_ file: URL, suggestedName: String?, type: UTType, in parent: URL = FileManager.default.temporaryDirectory) throws -> HostDocument {
        let folder = parent.appendingPathComponent("Photos-" + UUID().uuidString, isDirectory: true)
        let copy = folder.appendingPathComponent(fileName(suggestedName, type: type))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: copy)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return HostDocument(
            path: copy.path,
            kind: .file,
            isWritable: false,
            name: copy.lastPathComponent,
            contentType: type.preferredMIMEType ?? ContentTypes.mimeType(ofFileAt: copy.path),
            release: { try? FileManager.default.removeItem(at: folder) }
        )
    }
}

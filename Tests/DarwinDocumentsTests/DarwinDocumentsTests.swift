import DynamicDocuments
import DynamicFiles
import Foundation
import RuntimeDocuments
import RuntimeHost
import RuntimeNative
import Testing
import UniformTypeIdentifiers
@testable import DarwinDocuments

/// The pickers' types for the contract's.
@Suite("Content types")
struct ContentTypesTests {

    @Test func wireTypesBecomeTypes() {
        #expect(ContentTypes.types([]) == [.item], "none: any file")
        #expect(ContentTypes.types(["image/png", "IMAGE/PNG", "text/plain"]) == [.png, .plainText])
        #expect(ContentTypes.types(["image/*", "audio/*", "video/*", "text/*"]) == [.image, .audio, .movie, .text])
        #expect(ContentTypes.types([".pdf", ".json"]) == [.pdf, .json])
        #expect(ContentTypes.type("chemical/*") == .item, "a group the system doesn't have")
        #expect(ContentTypes.type(".x-notes")?.preferredFilenameExtension == "x-notes", "a type the system doesn't know, by its extension")
        #expect(ContentTypes.type("application/x-example-notes")?.preferredMIMEType == "application/x-example-notes")
    }

    @Test func whatCantBeReadShowsAnyFile() {
        for wire in ["png", "/png", "image/", ".", "a/b/c"] {
            #expect(ContentTypes.type(wire) == nil, "\(wire)")
        }
        #expect(ContentTypes.types(["image/png", "png"]) == [.item], "more, never fewer")
    }

    @Test func aFilesMIMEType() {
        #expect(ContentTypes.mimeType(ofFileAt: "/a/b/photo.JPG") == "image/jpeg")
        #expect(ContentTypes.mimeType(ofFileAt: "/a/notes.txt") == "text/plain")
        #expect(ContentTypes.mimeType(ofFileAt: "/a/.hidden") == nil)
        #expect(ContentTypes.mimeType(ofFileAt: "/a/README") == nil)
    }
}

/// Bookmarks, and the documents the pickers make, on real files.
@Suite("Pickers")
final class DarwinPickersTests {

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DarwinDocumentsTests-" + UUID().uuidString, isDirectory: true)
        .resolvingSymlinksInPath()

    let suite = "org.pureswift.DarwinDocumentsTests." + UUID().uuidString

    let pickers: DarwinPickers

    init() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let defaults = try #require(UserDefaults(suiteName: suite))
        pickers = DarwinPickers(bookmarks: DocumentBookmarks(defaults: defaults))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    func bookmark(_ document: HostDocument) throws -> String {
        var result: Result<String, DocumentError>?
        pickers.bookmark(document) { result = $0 }
        return try #require(result).get()
    }

    @Test func aDocumentIsWhatTheFileIs() {
        let file = DarwinPickers.document(root.appendingPathComponent("notes.txt"), access: .read)
        #expect(file.path == root.appendingPathComponent("notes.txt").path)
        #expect(file.kind == .file)
        #expect(file.displayName == "notes.txt")
        #expect(file.contentType == "text/plain")
        #expect(!file.isWritable, "asked to read")
        #expect(DarwinPickers.document(root.appendingPathComponent("notes.txt"), access: .readWrite).isWritable)
        #expect(DarwinPickers.document(root.appendingPathComponent("notes.txt"), access: nil).isWritable, "opened with: as the file is")

        let folder = DarwinPickers.document(root.appendingPathComponent("Folder"), access: .readWrite)
        #expect(folder.kind == .directory)
        #expect(folder.contentType == nil)
    }

    @Test func aBookmarkBringsTheDocumentBack() throws {
        let path = root.appendingPathComponent("notes.txt").path
        let name = try bookmark(HostDocument(path: path, isWritable: true))
        #expect(UUID(uuidString: name) != nil, "a string of the host's")
        let document = try pickers.resolve(name).get()
        // The same file, though the bookmark may name it through `/private`.
        #expect(URL(fileURLWithPath: document.path).resolvingSymlinksInPath() == URL(fileURLWithPath: path).resolvingSymlinksInPath())
        #expect(document.isWritable)
        document.release?()

        let folder = try pickers.resolve(try bookmark(HostDocument(path: root.appendingPathComponent("Folder").path, kind: .directory))).get()
        #expect(folder.kind == .directory)
        #expect(!folder.isWritable, "as it was remembered")
        folder.release?()
    }

    @Test func aForgottenOrMissingBookmarkIsNotFound() throws {
        let path = root.appendingPathComponent("notes.txt").path
        let name = try bookmark(HostDocument(path: path))
        pickers.forget(name)
        #expect(pickers.resolve(name).failure == .notFound)
        #expect(pickers.resolve("never made").failure == .notFound)

        let gone = try bookmark(HostDocument(path: path))
        try FileManager.default.removeItem(atPath: path)
        #expect(pickers.resolve(gone).failure == .notFound)
    }

    @Test func bookmarksAreKeptInTheHostsDefaults() throws {
        let name = try bookmark(HostDocument(path: root.appendingPathComponent("notes.txt").path))
        let stored = try #require(UserDefaults(suiteName: suite)?.dictionary(forKey: "RTDocumentBookmarks"))
        #expect(stored.keys.sorted() == [name])
        #expect(pickers.bookmarks.names == [name])
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

/// The module, from a guest's `DocumentPicker` and `FileManager`, over
/// AppRuntime's `HostDocuments` and `HostFiles`.
@Suite("Documents", .serialized)
final class DarwinDocumentsTests {

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DarwinDocumentsTests-" + UUID().uuidString, isDirectory: true)
        .resolvingSymlinksInPath()

    init() throws {
        let container = root.appendingPathComponent("Container")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("from the file manager".utf8).write(to: root.appendingPathComponent("Opened.txt"))

        // This code is the host's own guest: its calls go straight to the
        // runtime.
        let native = NativeRuntime.shared
        native.bindDirectly()
        native.capabilities = nil
        try HostFiles.configure(HostFiles.Configuration(directories: [
            .documents: container.appendingPathComponent("Documents").path,
            .temporary: container.appendingPathComponent("tmp").path,
        ], work: { $0() }, deliver: { $0() }))
        HostFilesModule.register(in: native)
        HostDocuments.reset()
        DarwinDocuments.register(in: native)
        HostDocuments.deliver = { $0() }
        DocumentPicker.onOpen(nil)
    }

    deinit {
        DocumentPicker.onOpen(nil)
        HostDocuments.reset()
        try? FileManager.default.removeItem(at: root)
    }

    @Test func moduleListsItsContracts() {
        #expect(DarwinDocuments.contracts.map(\.name) == [
            "org.pureswift.documents.Documents", "org.pureswift.documents.Grant",
            "org.pureswift.documents.Callback", "org.pureswift.documents.Delegate",
        ])
        #expect(HostDocuments.presenter === DarwinDocuments.pickers)
        #expect(DarwinDocuments.permissionProviders()[.userFiles]?.status() == .granted, "it prompts for nothing")
    }

    @Test func aFileTheAppIsOpenedWithReachesTheGuest() throws {
        DarwinDocuments.open([root.appendingPathComponent("Opened.txt"), URL(string: "https://example.com")!])
        var opened: [Document] = []
        DocumentPicker.onOpen { opened += $0 }
        let document = try #require(opened.first)
        #expect(opened.count == 1, "a link isn't a document")
        #expect(document.name == "Opened.txt")
        #expect(document.isWritable)

        var read: Result<[UInt8], FileError>?
        DynamicFiles.FileManager.default.contents(at: document.path) { read = $0 }
        #expect(try #require(read).get() == Array("from the file manager".utf8))
    }
}

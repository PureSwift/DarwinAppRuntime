import DynamicDocuments
import DynamicFiles
import Foundation
import RuntimeDocuments
import RuntimeHost
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The platform's pickers and bookmarks, for AppRuntime's `HostDocuments`
/// (`HostRuntime.md` §5.7).
///
/// - iOS: `UIDocumentPickerViewController`, opening in place, and its
///   exporting form for saving.
/// - macOS: `NSOpenPanel` and `NSSavePanel`, as a sheet on the app's
///   window.
///
/// A picked URL's security scope starts when it's handed over, and stops
/// when the guest lets go of the document. Main thread only.
final class DarwinPickers: NSObject, DocumentPresenter {

    let bookmarks: DocumentBookmarks

    init(bookmarks: DocumentBookmarks = DocumentBookmarks()) {
        self.bookmarks = bookmarks
    }

    // MARK: Picking

    func pick(types: [String], multiple: Bool, access: DocumentAccess, completion: @escaping (Result<[HostDocument], DocumentError>) -> Void) {
        let contentTypes = ContentTypes.types(types)
        show(.open(contentTypes, multiple: multiple, folders: false)) { result in
            completion(result.map { ($0 ?? []).map { Self.document($0, access: access) } })
        }
    }

    func pickFolder(access: DocumentAccess, completion: @escaping (Result<HostDocument?, DocumentError>) -> Void) {
        show(.open([.folder], multiple: false, folders: true)) { result in
            completion(result.map { $0?.first.map { Self.document($0, access: access) } })
        }
    }

    func export(file source: String, name: String, completion: @escaping (Result<HostDocumentExport, DocumentError>) -> Void) {
        #if canImport(UIKit)
        // iOS saves by moving a file the app has to where the user says. The
        // copy is the host's, so the app's own file stays.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Exporting-" + UUID().uuidString, isDirectory: true)
        let copy = folder.appendingPathComponent(name.isEmpty ? URL(fileURLWithPath: source).lastPathComponent : name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try HostFiles.copy(file: source, to: copy.path)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            completion(.failure(.unknown))
            return
        }
        show(.export(copy)) { result in
            try? FileManager.default.removeItem(at: folder)
            switch result {
            case .success(let urls?):
                guard let saved = urls.first else {
                    completion(.success(.savedCopy))
                    return
                }
                completion(.success(.saved(Self.document(saved, access: .readWrite))))
            case .success(nil):
                completion(.success(.cancelled))
            case .failure(let error):
                completion(.failure(error))
            }
        }
        #else
        show(.save(suggestedName: name)) { result in
            switch result {
            case .success(let urls?):
                guard let destination = urls.first else {
                    completion(.success(.cancelled))
                    return
                }
                let scoped = destination.startAccessingSecurityScopedResource()
                do {
                    try HostFiles.copy(file: source, to: destination.path)
                } catch {
                    if scoped { destination.stopAccessingSecurityScopedResource() }
                    completion(.failure(.unknown))
                    return
                }
                completion(.success(.saved(Self.document(destination, access: .readWrite, scoped: scoped))))
            case .success(nil):
                completion(.success(.cancelled))
            case .failure(let error):
                completion(.failure(error))
            }
        }
        #endif
    }

    // MARK: Remembering

    func bookmark(_ document: HostDocument, completion: @escaping (Result<String, DocumentError>) -> Void) {
        let url = URL(fileURLWithPath: document.path)
        do {
            let data = try url.bookmarkData(options: Self.bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
            completion(.success(bookmarks.add(.init(data: data, isWritable: document.isWritable))))
        } catch {
            completion(.failure(Self.isMissing(error) ? .notFound : .unknown))
        }
    }

    func resolve(_ bookmark: String, completion: @escaping (Result<HostDocument, DocumentError>) -> Void) {
        completion(resolve(bookmark))
    }

    func resolve(_ bookmark: String) -> Result<HostDocument, DocumentError> {
        guard let entry = bookmarks[bookmark] else {
            return .failure(.notFound)
        }
        var isStale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: entry.data, options: Self.resolvingOptions, relativeTo: nil, bookmarkDataIsStale: &isStale)
        } catch {
            return .failure(Self.isMissing(error) ? .notFound : .notPermitted)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        guard FileManager.default.fileExists(atPath: url.path) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return .failure(.notFound)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return .failure(.notPermitted)
        }
        if isStale, let data = try? url.bookmarkData(options: Self.bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
            bookmarks[bookmark] = .init(data: data, isWritable: entry.isWritable)
        }
        return .success(Self.document(url, access: entry.isWritable ? .readWrite : .read, scoped: scoped))
    }

    func forget(_ bookmark: String) {
        bookmarks[bookmark] = nil
    }

    #if os(macOS)
    static let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    static let resolvingOptions: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
    #else
    static let bookmarkOptions: URL.BookmarkCreationOptions = []
    static let resolvingOptions: URL.BookmarkResolutionOptions = [.withoutUI]
    #endif

    static func isMissing(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    }

    // MARK: Documents

    /// The document for a URL the platform gave, starting its security
    /// scope unless that's done, and stopping it when the guest lets go.
    static func document(_ url: URL, access: DocumentAccess?, scoped: Bool? = nil) -> HostDocument {
        let scoped = scoped ?? url.startAccessingSecurityScopedResource()
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let canWrite = FileManager.default.isWritableFile(atPath: url.path)
        return HostDocument(
            path: url.path,
            kind: isDirectory ? .directory : .file,
            // What the app asked for, where the file allows it. A document
            // the app was opened with is as writable as the file is.
            isWritable: access.map { $0 == .readWrite && canWrite } ?? canWrite,
            name: url.lastPathComponent,
            contentType: isDirectory ? nil : ContentTypes.mimeType(ofFileAt: url.path),
            release: scoped ? { url.stopAccessingSecurityScopedResource() } : nil
        )
    }

    // MARK: Showing

    enum Picker {
        case open([UniformTypeIdentifiers.UTType], multiple: Bool, folders: Bool)
        #if canImport(UIKit)
        case export(URL)
        #else
        case save(suggestedName: String)
        #endif
    }

    #if canImport(UIKit)
    private var completion: ((Result<[URL]?, DocumentError>) -> Void)?

    /// Shows `picker` over the app's window; `nil` URLs when the user
    /// cancelled.
    private func show(_ picker: Picker, completion: @escaping (Result<[URL]?, DocumentError>) -> Void) {
        let controller: UIDocumentPickerViewController
        switch picker {
        case .open(let types, let multiple, _):
            controller = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
            controller.allowsMultipleSelection = multiple
        case .export(let file):
            controller = UIDocumentPickerViewController(forExporting: [file], asCopy: false)
        }
        guard let top = Self.topController() else {
            completion(.failure(.unsupported))
            return
        }
        controller.delegate = self
        self.completion = completion
        top.present(controller, animated: true)
    }

    private func finish(_ result: Result<[URL]?, DocumentError>) {
        let completion = completion
        self.completion = nil
        completion?(result)
    }

    /// The view controller on top of the key window, to present from.
    static func topController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        var controller = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return controller
    }
    #else
    /// Shows `picker` as a sheet on the app's window, or on its own when
    /// there's none; `nil` URLs when the user cancelled.
    private func show(_ picker: Picker, completion: @escaping (Result<[URL]?, DocumentError>) -> Void) {
        let panel: NSSavePanel
        switch picker {
        case .open(let types, let multiple, let folders):
            let open = NSOpenPanel()
            open.canChooseFiles = !folders
            open.canChooseDirectories = folders
            open.canCreateDirectories = folders
            open.allowsMultipleSelection = multiple
            open.resolvesAliases = true
            if !folders, types != [.item] {
                open.allowedContentTypes = types
            }
            panel = open
        case .save(let name):
            panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.canCreateDirectories = true
        }
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else {
                completion(.success(nil))
                return
            }
            if let open = panel as? NSOpenPanel {
                completion(.success(open.urls))
            } else {
                completion(.success(panel.url.map { [$0] } ?? []))
            }
        }
        if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: answer)
        } else {
            panel.begin(completionHandler: answer)
        }
    }
    #endif
}

#if canImport(UIKit)
extension DarwinPickers: UIDocumentPickerDelegate {

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(.success(urls))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(.success(nil))
    }
}
#endif

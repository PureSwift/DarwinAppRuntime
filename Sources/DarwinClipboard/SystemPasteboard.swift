import DynamicClipboard
import Foundation
import RuntimeClipboard
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#elseif canImport(AppKit)
import AppKit
#endif

/// `HostClipboard`'s platform: `UIPasteboard` on iOS, `NSPasteboard` on
/// macOS. The general one in an app; a named one in the tests.
///
/// Main thread only. Every answer comes at once: an iOS read that asks
/// the user waits for the answer before it returns.
final class SystemPasteboard: ClipboardPlatform {

    #if canImport(UIKit)

    let pasteboard: UIPasteboard

    init(_ pasteboard: UIPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// From what the pasteboard says it holds, which never alerts. A URL is
    /// text too: `readText` gives its text.
    func available() -> ClipboardKinds {
        var kinds: ClipboardKinds = []
        if pasteboard.hasStrings || pasteboard.hasURLs {
            kinds.insert(.text)
        }
        if pasteboard.hasURLs {
            kinds.insert(.url)
        }
        if pasteboard.hasImages {
            kinds.insert(.image)
        }
        return kinds
    }

    func clear() {
        pasteboard.items = []
    }

    /// One item. `.localOnly` keeps a sensitive one off the user's other
    /// devices.
    func write(_ content: HostClipboardContent, isSensitive: Bool, completion: @escaping (PasteboardError?) -> Void) {
        var item: [String: Any] = [:]
        switch content {
        case .text(let text, let url):
            item[UTType.utf8PlainText.identifier] = text
            if let url, let value = URL(string: url) {
                item[UTType.url.identifier] = value
            }
        case .image(let data, let type):
            item[(type == .png ? UTType.png : UTType.jpeg).identifier] = Data(data)
        }
        pasteboard.setItems([item], options: isSensitive ? [.localOnly: true] : [:])
        completion(nil)
    }

    /// Reading from code asks the user, from iOS 16, unless they allowed
    /// the app in Settings. A refusal reads as nothing: when the pasteboard
    /// said it had one, that's `notAllowed`. One read, so one question.
    func read(_ kind: ClipboardKind, completion: @escaping (Result<HostClipboardContent?, PasteboardError>) -> Void) {
        switch kind {
        case .text:
            if pasteboard.hasStrings {
                let text = pasteboard.string
                completion(text.map { .success(.text($0, url: nil)) } ?? .failure(.notAllowed))
            } else if pasteboard.hasURLs {
                // A URL's text when a URL is all there is.
                let url = pasteboard.url?.absoluteString
                completion(url.map { .success(.text($0, url: $0)) } ?? .failure(.notAllowed))
            } else {
                completion(.success(nil))
            }
        case .url:
            guard pasteboard.hasURLs else {
                completion(.success(nil))
                return
            }
            let url = pasteboard.url?.absoluteString
            completion(url.map { .success(.text($0, url: $0)) } ?? .failure(.notAllowed))
        case .image:
            guard pasteboard.hasImages else {
                completion(.success(nil))
                return
            }
            completion(readImage().map { .success($0) } ?? .failure(.notAllowed))
        }
    }

    /// PNG or JPEG as they are; anything else as PNG. The types never
    /// alert, so only the read itself asks.
    private func readImage() -> HostClipboardContent? {
        let types = pasteboard.types
        if types.contains(UTType.png.identifier) {
            return pasteboard.data(forPasteboardType: UTType.png.identifier).map { .image(Array($0), type: .png) }
        }
        if types.contains(UTType.jpeg.identifier) {
            return pasteboard.data(forPasteboardType: UTType.jpeg.identifier).map { .image(Array($0), type: .jpeg) }
        }
        return pasteboard.image?.pngData().map { .image(Array($0), type: .png) }
    }

    #elseif canImport(AppKit)

    let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Clipboard managers leave out what's marked with it
    /// (nspasteboard.org).
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static let jpeg = NSPasteboard.PasteboardType("public.jpeg")

    func available() -> ClipboardKinds {
        let types = Set(pasteboard.types ?? [])
        var kinds: ClipboardKinds = []
        if types.contains(.string) || types.contains(.URL) {
            kinds.insert(.text)
        }
        if types.contains(.URL) {
            kinds.insert(.url)
        }
        if !types.isDisjoint(with: [.png, .tiff, Self.jpeg]) {
            kinds.insert(.image)
        }
        return kinds
    }

    func clear() {
        pasteboard.clearContents()
    }

    func write(_ content: HostClipboardContent, isSensitive: Bool, completion: @escaping (PasteboardError?) -> Void) {
        let item = NSPasteboardItem()
        switch content {
        case .text(let text, let url):
            item.setString(text, forType: .string)
            if let url {
                item.setString(url, forType: .URL)
            }
        case .image(let data, let type):
            item.setData(Data(data), forType: type == .png ? .png : Self.jpeg)
        }
        if isSensitive {
            item.setData(Data(), forType: Self.concealed)
        }
        pasteboard.clearContents()
        completion(pasteboard.writeObjects([item]) ? nil : .unknown)
    }

    /// Nothing asks on macOS.
    func read(_ kind: ClipboardKind, completion: @escaping (Result<HostClipboardContent?, PasteboardError>) -> Void) {
        switch kind {
        case .text:
            let url = pasteboard.string(forType: .URL)
            guard let text = pasteboard.string(forType: .string) ?? url else {
                completion(.success(nil))
                return
            }
            completion(.success(.text(text, url: url)))
        case .url:
            completion(.success(pasteboard.string(forType: .URL).map { .text($0, url: $0) }))
        case .image:
            completion(.success(readImage()))
        }
    }

    /// PNG or JPEG as they are; TIFF, which is what most apps put there,
    /// as PNG.
    private func readImage() -> HostClipboardContent? {
        if let data = pasteboard.data(forType: .png) {
            return .image(Array(data), type: .png)
        }
        if let data = pasteboard.data(forType: Self.jpeg) {
            return .image(Array(data), type: .jpeg)
        }
        guard let tiff = pasteboard.data(forType: .tiff),
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            return nil
        }
        return .image(Array(png), type: .png)
    }

    #endif
}

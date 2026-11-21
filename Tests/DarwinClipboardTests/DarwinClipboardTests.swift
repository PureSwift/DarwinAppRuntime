#if canImport(AppKit)
import AppKit
import DynamicClipboard
import DynamicFiles
import Foundation
import RuntimeClipboard
import RuntimeHost
import Testing
@testable import DarwinClipboard

/// The macOS pasteboard, a named one of the test's own so the user's
/// clipboard is left alone, through `HostClipboard` as the guest calls it.
/// They share `HostClipboard`'s platform, so one test at a time.
@Suite("Pasteboard", .serialized)
@MainActor
struct PasteboardTests {

    let pasteboard: NSPasteboard

    let platform: SystemPasteboard

    let directory: URL

    init() throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("org.pureswift.DarwinClipboardTests.\(UUID().uuidString)"))
        platform = SystemPasteboard(pasteboard)
        HostClipboard.reset()
        HostClipboard.platform = platform
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DarwinClipboardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try HostFiles.configure(HostFiles.Configuration(directories: [.caches: directory.path]))
    }

    /// What a guest's callback heard.
    final class Callback: ClipboardCallback {
        var completed = false
        var text: String??
        var image: (data: [UInt8], type: String)?
        var file: String?
        var failure: PasteboardError?
        var answered: Bool { completed || text != nil || image != nil || file != nil || failure != nil }
        func didComplete() { completed = true }
        func didReadText(_ text: String?) { self.text = .some(text) }
        func didReadImage(_ data: [UInt8], mimeType: String) { image = (data, mimeType) }
        func didWriteImageFile(_ mimeType: String) { file = mimeType }
        func didFail(_ error: Int32) { failure = PasteboardError(rawValue: error) }
    }

    func answer(_ call: (Callback) -> Void) async throws -> Callback {
        let callback = Callback()
        call(callback)
        let deadline = Date().addingTimeInterval(5)
        while !callback.answered {
            guard Date() < deadline else {
                Issue.record("no answer")
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return callback
    }

    /// A 1×1 image as TIFF, as most Mac apps copy one.
    static func tiff() -> Data {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return image.tiffRepresentation!
    }

    static func png() -> [UInt8] {
        Array(NSBitmapImageRep(data: tiff())!.representation(using: .png, properties: [:])!)
    }

    @Test func copiesAndPastesText() async throws {
        let clipboard = HostClipboard.shared()
        #expect(clipboard.available() == 0)
        // Line endings as they are.
        let written = try await answer { clipboard.writeText("Total: 42\r\n", url: "", options: 0, callback: $0) }
        #expect(written.completed)
        #expect(pasteboard.string(forType: .string) == "Total: 42\r\n")
        #expect(clipboard.available() == ClipboardKinds.text.rawValue)
        #expect(try await answer { clipboard.readText($0) }.text == .some("Total: 42\r\n"))
        // Text that looks like a URL isn't one.
        #expect(try await answer { clipboard.readURL($0) }.text == .some(nil))
        #expect(try await answer { clipboard.readImage($0) }.image?.type == "")
        pasteboard.releaseGlobally()
    }

    @Test func copiesALinkWithItsText() async throws {
        let clipboard = HostClipboard.shared()
        _ = try await answer { clipboard.writeText("Example", url: "https://example.com/a", options: 0, callback: $0) }
        #expect(pasteboard.string(forType: .URL) == "https://example.com/a")
        #expect(clipboard.available() == ClipboardKinds([.text, .url]).rawValue)
        #expect(try await answer { clipboard.readURL($0) }.text == .some("https://example.com/a"))
        #expect(try await answer { clipboard.readText($0) }.text == .some("Example"))
        // Another app's URL with no text: its text is the URL.
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/b", forType: .URL)
        #expect(try await answer { clipboard.readText($0) }.text == .some("https://example.com/b"))
        pasteboard.releaseGlobally()
    }

    @Test func marksASensitiveCopy() async throws {
        let clipboard = HostClipboard.shared()
        _ = try await answer { clipboard.writeText("123456", url: "", options: PasteboardOptions.sensitive.rawValue, callback: $0) }
        #expect(pasteboard.types?.contains(SystemPasteboard.concealed) == true)
        _ = try await answer { clipboard.writeText("open", url: "", options: 0, callback: $0) }
        #expect(pasteboard.types?.contains(SystemPasteboard.concealed) == false)
        // Cleared, there's nothing to paste.
        _ = try await answer { clipboard.clear($0) }
        #expect(clipboard.available() == 0)
        #expect(try await answer { clipboard.readText($0) }.text == .some(nil))
        pasteboard.releaseGlobally()
    }

    @Test func copiesAndPastesImages() async throws {
        let clipboard = HostClipboard.shared()
        let png = Self.png()
        // Called a JPEG, it's still a PNG.
        _ = try await answer { clipboard.writeImage(png, mimeType: "image/jpeg", options: 0, callback: $0) }
        #expect(pasteboard.data(forType: .png).map(Array.init) == png)
        #expect(clipboard.available() == ClipboardKinds.image.rawValue)
        let read = try await answer { clipboard.readImage($0) }
        #expect(read.image?.type == "image/png")
        #expect(read.image?.data == png)
        // Not an image at all.
        #expect(try await answer { clipboard.writeImage([1, 2, 3], mimeType: "image/png", options: 0, callback: $0) }.failure == .invalidData)
        pasteboard.releaseGlobally()
    }

    @Test func pastesAnotherAppsTIFFAsPNG() async throws {
        let clipboard = HostClipboard.shared()
        pasteboard.clearContents()
        pasteboard.setData(Self.tiff(), forType: .tiff)
        #expect(clipboard.available() == ClipboardKinds.image.rawValue)
        let read = try await answer { clipboard.readImage($0) }
        #expect(read.image?.type == "image/png")
        #expect(read.image.map { PasteboardImageType.detect($0.data) } == .png)
        pasteboard.releaseGlobally()
    }

    @Test func copiesAnImageFileAndPastesIntoOne() async throws {
        let clipboard = HostClipboard.shared()
        try Data(Self.png()).write(to: directory.appendingPathComponent("logo.png"))
        let copied = try await answer { clipboard.writeImageFile(FileDirectory.caches.rawValue, path: "logo.png", options: 0, callback: $0) }
        #expect(copied.completed)
        #expect(pasteboard.data(forType: .png) != nil)
        let pasted = try await answer { clipboard.readImageToFile(FileDirectory.caches.rawValue, path: "pasted", callback: $0) }
        #expect(pasted.file == "image/png")
        let written = try Data(contentsOf: directory.appendingPathComponent("pasted"))
        #expect(Array(written) == Self.png())
        pasteboard.releaseGlobally()
    }
}
#endif
